import XCTest
@testable import Lowkey

final class LanguageRoutingTests: XCTestCase {
    func testLanguageNeverOverridesSelectedEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let english = root.appendingPathComponent("ggml-small.en-q5_1.bin")
        let multilingual = root.appendingPathComponent("ggml-small.bin")
        try Data().write(to: english)
        try Data().write(to: multilingual)
        var config = Config.makeDefault()
        config.engine = .parakeet
        config.language = "en"
        config.modelPath = english.path
        XCTAssertEqual(config.engine, .parakeet)
        XCTAssertEqual(config.whisperConfig.modelPath, english.path)

        for language in ["auto", "es", "fr"] {
            config.language = language
            XCTAssertNotNil(config.selectedEngineError, "An English-only recognizer cannot satisfy \(language)")
            let resolved = config.whisperConfig
            XCTAssertEqual(resolved.engine, .parakeet, "Resolving a model path must not change the selected engine")
            XCTAssertEqual(resolved.language, language)
            XCTAssertEqual(resolved.modelPath, multilingual.path)
            XCTAssertEqual(config.modelPath, english.path)
            XCTAssertEqual(config.engine, .parakeet)
            config.engine = .whisper
            XCTAssertNil(config.selectedEngineError)
            XCTAssertEqual(config.whisperConfig.modelPath, multilingual.path)
            config.engine = .parakeet
        }
    }
}
