import XCTest
@testable import Lowkey

final class LanguageRoutingTests: XCTestCase {
    func testAutomaticLanguageUsesMultilingualFallbackWithoutChangingEnglishPreference() throws {
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
        XCTAssertTrue(config.prefersParakeet)
        XCTAssertEqual(config.whisperConfig.modelPath, english.path)

        for language in ["auto", "es", "fr"] {
            config.language = language
            XCTAssertFalse(config.prefersParakeet, "An English-only recognizer cannot satisfy \(language)")
            let fallback = config.whisperConfig
            XCTAssertEqual(fallback.engine, .whisper)
            XCTAssertEqual(fallback.language, language)
            XCTAssertEqual(fallback.modelPath, multilingual.path)
            XCTAssertEqual(config.modelPath, english.path)
            XCTAssertEqual(config.engine, .parakeet)
        }
    }
}
