import AudioToolbox
import AVFoundation
import Foundation

final class Recorder {
    // A finished recording, still in memory: 16 kHz mono 16-bit PCM.
    struct Take {
        let pcm: Data
        let containsSpeech: Bool
        let heardEnergy: Bool
        var seconds: Double { Double(pcm.count) / 32_000 }
    }

    var onWave: (([CGFloat]) -> Void)?
    // 20 ms of mono 16-bit audio at 16 kHz. Keep capture and meter updates
    // frequent enough that a new syllable appears without waiting 64 ms.
    static let bufferFrames = 320

    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var pcm = Data()
    private let pcmLock = NSLock()
    private var wave = Array(repeating: CGFloat(0), count: 18)
    private var heardEnergy = false
    private var isCapturing = false
    fileprivate var running: Bool {
        get { pcmLock.withLock { isCapturing } }
        set { pcmLock.withLock { isCapturing = newValue } }
    }

    func start(deviceUID: String? = nil) throws {
        discard()
        wave = Array(repeating: 0, count: 18)
        try startQueue(deviceUID: deviceUID)
    }

    func releaseMic() {
        stopCapture()
    }

    // Drops a cancelled take. Nothing was written, so there is nothing to clean up.
    func discard() {
        stopCapture()
        _ = takeSamples()
    }

    // Hands over what was captured. Call after releaseMic, off the main thread:
    // the speech check walks every sample.
    func finish() -> Take {
        let (samples, energy) = takeSamples()
        return Take(pcm: samples, containsSpeech: detectSpeech(in: samples), heardEnergy: energy)
    }

    private func takeSamples() -> (Data, Bool) {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        let taken = (pcm, heardEnergy)
        pcm = Data()
        heardEnergy = false
        return taken
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
            let deviceStatus = withUnsafePointer(to: &uid) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<CFString>.size) { _ in
                    AudioQueueSetProperty(
                        newQueue,
                        kAudioQueueProperty_CurrentDevice,
                        pointer,
                        UInt32(MemoryLayout<CFString>.size)
                    )
                }
            }
            guard deviceStatus == noErr else { stopCapture(); throw RecorderError.failedToStart }
        }

        let bufferBytes = UInt32(Self.bufferFrames * MemoryLayout<Int16>.size)
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(newQueue, bufferBytes, &buffer) == noErr, let buffer else {
                stopCapture()
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
        pcmLock.lock()
        pcm.append(data.assumingMemoryBound(to: UInt8.self), count: byteCount)
        pcmLock.unlock()

        let sampleCount = byteCount / 2
        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
        // Two 10 ms bars per buffer preserve about 180 ms of waveform history.
        let slices = 2
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
            pcmLock.withLock { heardEnergy = true }
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

    // The samples as a WAV file: what Whisper is sent and what History keeps.
    static func wav(from pcm: Data) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        data.append(Data("RIFF".utf8))
        data.append(UInt32(36 + pcm.count).littleEndianData)
        data.append(Data("WAVEfmt ".utf8))
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)          // PCM
        data.append(UInt16(1).littleEndianData)          // mono
        data.append(UInt32(16_000).littleEndianData)     // sample rate
        data.append(UInt32(32_000).littleEndianData)     // byte rate
        data.append(UInt16(2).littleEndianData)          // block align
        data.append(UInt16(16).littleEndianData)         // bits
        data.append(Data("data".utf8))
        data.append(UInt32(pcm.count).littleEndianData)
        data.append(pcm)
        return data
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
    var errorDescription: String? {
        switch self {
        case .failedToStart: return "Could not start the microphone."
        }
    }
}
