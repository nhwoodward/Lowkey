import AudioToolbox
import AVFoundation
import Foundation

final class Recorder {
    var onWave: (([CGFloat]) -> Void)?

    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var pcm = Data()
    private let pcmLock = NSLock()
    private var wave = Array(repeating: CGFloat(0), count: 18)
    private(set) var containsSpeech = false
    private(set) var heardEnergy = false
    private(set) var fileURL: URL?
    fileprivate var running = false

    func start(deviceUID: String? = nil) throws {
        stopCapture()
        pcmLock.lock()
        pcm = Data()
        pcmLock.unlock()
        containsSpeech = false
        heardEnergy = false
        wave = Array(repeating: 0, count: 18)
        let url = Config.tmpDirectory.appendingPathComponent("clip.wav")
        try? FileManager.default.removeItem(at: url)
        fileURL = url
        try startQueue(deviceUID: deviceUID)
    }

    func releaseMic() {
        stopCapture()
    }

    @discardableResult
    func stop() -> URL? {
        stopCapture()
        finalizeOutput()
        return fileURL
    }

    func finalizeOutput() {
        pcmLock.lock()
        let samples = pcm
        pcmLock.unlock()
        if let fileURL, !samples.isEmpty {
            try? writeWav(samples, to: fileURL)
        }
        containsSpeech = detectSpeech(in: samples)
    }

    private func startQueue(deviceUID: String?) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var newQueue: AudioQueueRef?
        let status = AudioQueueNewInput(
            &format,
            recorderCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &newQueue
        )
        guard status == noErr, let newQueue else {
            throw RecorderError.failedToStart
        }
        queue = newQueue
        if let deviceUID, !deviceUID.isEmpty {
            var uid: CFString = deviceUID as CFString
            withUnsafePointer(to: &uid) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<CFString>.size) { _ in
                    _ = AudioQueueSetProperty(
                        newQueue,
                        kAudioQueueProperty_CurrentDevice,
                        pointer,
                        UInt32(MemoryLayout<CFString>.size)
                    )
                }
            }
        }

        let bufferBytes: UInt32 = 2048
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(newQueue, bufferBytes, &buffer) == noErr, let buffer else {
                throw RecorderError.failedToStart
            }
            AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil)
            buffers.append(buffer)
        }

        running = true
        guard AudioQueueStart(newQueue, nil) == noErr else {
            stopCapture()
            throw RecorderError.failedToStart
        }
    }

    fileprivate func handleBuffer(_ buffer: AudioQueueBufferRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        let data = buffer.pointee.mAudioData
        guard byteCount > 0 else { return }
        let chunk = Data(bytes: data, count: byteCount)
        pcmLock.lock()
        pcm.append(chunk)
        pcmLock.unlock()

        let sampleCount = byteCount / 2
        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
        let slices = 6
        let sliceSize = max(1, sampleCount / slices)
        var fresh: [CGFloat] = []
        for slice in 0..<slices {
            let start = slice * sliceSize
            let end = slice == slices - 1 ? sampleCount : min(sampleCount, start + sliceSize)
            var peak: Int = 0
            if start < end {
                for i in start..<end {
                    peak = max(peak, abs(Int(samples[i])))
                }
            }
            fresh.append(visualLevel(CGFloat(peak) / 4000.0))
        }
        wave.removeFirst(min(fresh.count, wave.count))
        wave.append(contentsOf: fresh.prefix(18))
        if wave.count > 18 { wave = Array(wave.suffix(18)) }
        while wave.count < 18 { wave.insert(0, at: 0) }
        if fresh.contains(where: { $0 >= 0.12 }) {
            heardEnergy = true
        }
        let snapshot = wave
        DispatchQueue.main.async { [weak self] in
            self?.onWave?(snapshot)
        }
    }

    private func stopCapture() {
        running = false
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        buffers.removeAll()
    }

    private func visualLevel(_ raw: CGFloat) -> CGFloat {
        CGFloat(tanh(Double(max(0, raw)))) * 0.88
    }

    private func detectSpeech(in pcm: Data) -> Bool {
        let sampleCount = pcm.count / 2
        // Ignore accidental taps and sub-200ms clips.
        guard sampleCount >= 3200 else { return false }

        let frameSize = 320
        var rmsValues: [Double] = []
        var peak = 0
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            var index = 0
            while index < values.count {
                let end = min(index + frameSize, values.count)
                var sumSquares: Double = 0
                var framePeak = 0
                for i in index..<end {
                    let sample = abs(Int(values[i]))
                    framePeak = max(framePeak, sample)
                    sumSquares += Double(sample) * Double(sample)
                }
                peak = max(peak, framePeak)
                let count = Double(end - index)
                if count > 0 {
                    rmsValues.append(sqrt(sumSquares / count))
                }
                index = end
            }
        }

        guard !rmsValues.isEmpty, peak >= 900 else { return false }

        let sorted = rmsValues.sorted()
        let quietCount = max(1, sorted.count / 5)
        let noiseFloor = sorted.prefix(quietCount).reduce(0, +) / Double(quietCount)
        let threshold = max(650.0, noiseFloor * 4.5)
        let speechFrames = rmsValues.filter { $0 >= threshold }.count
        // 8 frames * 20ms = 160ms of speech-like energy.
        return speechFrames >= 8
    }

    private func writeWav(_ samples: Data, to url: URL) throws {
        var data = Data()
        func put32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func put16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)
        put16(1)
        put16(1)
        put32(16_000)
        put32(32_000)
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url, options: .atomic)
    }
}

private func recorderCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    startTime: UnsafePointer<AudioTimeStamp>,
    numPackets: UInt32,
    packetDescs: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData else { return }
    let recorder = Unmanaged<Recorder>.fromOpaque(userData).takeUnretainedValue()
    recorder.handleBuffer(buffer)
    if recorder.running {
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

enum RecorderError: LocalizedError {
    case failedToStart
    var errorDescription: String? { "Could not start the microphone." }
}
