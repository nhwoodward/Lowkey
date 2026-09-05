import AVFoundation
import XCTest
@testable import Lowkey

final class AudioImportTests: XCTestCase {
    func testConvertsStereo44100AudioAndPreservesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        for channel in 0..<2 {
            for i in 0..<44100 { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.03) * 0.1 }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let before = try Data(contentsOf: source)
        let imported = try ImportedAudio.prepare(source, directory: root)
        let audio = try AVAudioFile(forReading: imported.url)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(imported.duration, 1, accuracy: 0.01)
        XCTAssertEqual(Double(audio.length), 16000, accuracy: 2)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
}
