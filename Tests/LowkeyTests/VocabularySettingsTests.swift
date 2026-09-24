import XCTest
@testable import Lowkey

final class VocabularySettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // The shapes earlier releases wrote, decoded independently of the app's own types.
    private struct LegacyVocabulary: Codable {
        struct Term: Codable { var id: UUID; var phrase: String }
        struct Fix: Codable { var id: UUID; var wrong: String; var right: String; var count: Int }
        var terms: [Term]
        var fixes: [Fix]
    }

    private struct LegacySnippet: Codable {
        var id: UUID
        var trigger: String
        var expansion: String
    }

    func testOldVocabularyFileLoadsAndSavesInTheSameFormat() throws {
        let fix = UUID()
        let old = """
        {"terms":[{"id":"\(UUID())","phrase":"OpenAI"},{"id":"\(UUID())","phrase":"Kubernetes"}],
         "fixes":[{"id":"\(fix)","wrong":"open ai","right":"OpenAI","count":3}]}
        """
        try Data(old.utf8).write(to: directory.appendingPathComponent("vocabulary.json"))

        let store = VocabularyStore(directory: directory)
        XCTAssertEqual(store.entries.map(\.heard), ["open ai", "Kubernetes"], "A fix hides the term it writes")
        XCTAssertEqual(store.entries.first?.writeAs, "OpenAI")
        XCTAssertEqual(store.entries.last?.writeAs, "")
        XCTAssertEqual(store.apply(to: "I use open ai daily"), "I use OpenAI daily")

        store.add(heard: "github", writeAs: "GitHub")
        store.add(heard: "WezTerm", writeAs: "")
        XCTAssertEqual(store.apply(to: "push to github"), "push to GitHub", "Case-only replacements are allowed from Settings")

        let saved = try JSONDecoder().decode(LegacyVocabulary.self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
        XCTAssertEqual(saved.fixes.map(\.wrong), ["open ai", "github"])
        XCTAssertEqual(saved.fixes.first?.count, 3, "Existing counts survive a save")
        XCTAssertEqual(Set(saved.terms.map(\.phrase)), ["OpenAI", "Kubernetes", "GitHub", "WezTerm"])

        let reloaded = VocabularyStore(directory: directory)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testRemovingAReplacementRemovesTheSpellingItWrites() throws {
        let store = VocabularyStore(directory: directory)
        store.add(heard: "open ai", writeAs: "OpenAI")
        store.add(heard: "Kubernetes", writeAs: "")
        let replacement = try XCTUnwrap(store.entries.first { $0.heard == "open ai" })

        store.removeEntry(id: replacement.id)

        XCTAssertEqual(store.entries.map(\.heard), ["Kubernetes"], "No orphaned OpenAI row appears")
        XCTAssertEqual(store.apply(to: "open ai"), "open ai")
        XCTAssertFalse(store.promptHint.contains("OpenAI"))
    }

    func testReAddingAPhraseReplacesItsRow() {
        let store = VocabularyStore(directory: directory)
        store.add(heard: "lo key", writeAs: "Low Key")
        store.add(heard: "Lo Key", writeAs: "Lowkey")

        XCTAssertEqual(store.entries.map(\.writeAs), ["Lowkey"])
        XCTAssertEqual(store.terms.map(\.phrase), ["Lowkey"])
    }

    func testOldSnippetsFileLoadsAndSavesInTheSameFormat() throws {
        let old = """
        [{"id":"\(UUID())","trigger":"sign off","expansion":"Thanks,\\nNoah"}]
        """
        try Data(old.utf8).write(to: directory.appendingPathComponent("snippets.json"))

        let store = SnippetStore(directory: directory)
        XCTAssertEqual(store.items.map(\.expansion), ["Thanks,\nNoah"])

        store.add(trigger: "my email", expansion: "noah@example.com")
        let saved = try JSONDecoder().decode([LegacySnippet].self, from: Data(contentsOf: directory.appendingPathComponent("snippets.json")))
        XCTAssertEqual(saved.map(\.trigger), ["sign off", "my email"])

        store.remove(id: saved[0].id)
        XCTAssertEqual(SnippetStore(directory: directory).items.map(\.trigger), ["my email"])
    }
}
