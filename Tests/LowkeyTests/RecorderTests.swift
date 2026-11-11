import AVFoundation
import XCTest
@testable import Lowkey

final class RecorderTests: XCTestCase {
    private func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // Live dictation skips the disk, so the samples it hands Parakeet must be
    // the ones a reader of the saved WAV would get.
    func testInMemorySamplesMatchTheSavedRecording() throws {
        let samples: [Int16] = (0..<4800).map { Int16(truncatingIfNeeded: $0 &* 7919) } + [.min, .max, 0, -1, 1]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Recorder.wav(from: pcm(samples)).write(to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Int(file.length), samples.count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let decoded = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))

        XCTAssertEqual(ParakeetEngine.floats(fromPCM16: pcm(samples)), decoded)
    }

    func testEmptyAndOddLengthSamplesConvertSafely() {
        XCTAssertEqual(ParakeetEngine.floats(fromPCM16: Data()), [])
        XCTAssertEqual(ParakeetEngine.floats(fromPCM16: Data([0x00])), [])
        // A trailing half sample is dropped, never read past.
        XCTAssertEqual(ParakeetEngine.floats(fromPCM16: Data([0x00, 0x40, 0xFF])), [0.5])
    }

    func testLiveSamplesFollowTheSameLengthRulesAsFiles() throws {
        #if arch(arm64)
        var config = Config.makeDefault()
        config.engine = .parakeet
        // Under 300 ms is a tap, not an engine failure.
        XCTAssertEqual(try Transcriber.transcribe(.pcm(Data(count: 8000)), config: config), .silence)
        XCTAssertThrowsError(try Transcriber.transcribe(.pcm(Data(count: 16_000)), config: config)) { error in
            guard case ParakeetError.notReady = error else {
                return XCTFail("Expected the selected engine's error, got \(error)")
            }
        }
        #endif
    }
}
