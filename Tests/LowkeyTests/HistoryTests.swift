import XCTest
@testable import Lowkey

final class HistoryTests: XCTestCase {
    func testImportAndDeletePreserveOriginalAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("voice-note.m4a")
        let bytes = Data("original audio".utf8)
        try bytes.write(to: source)
        let store = HistoryStore(directory: root.appendingPathComponent("support"))
        store.add(text: "A voice note", duration: 3, language: "en", audioURL: source)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.audioFileName.map { ($0 as NSString).pathExtension }, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Import must preserve the user's original")
        store.delete(id: item.id)
        XCTAssertEqual(try? Data(contentsOf: source), bytes, "Deleting history must not delete the source")
    }
}
