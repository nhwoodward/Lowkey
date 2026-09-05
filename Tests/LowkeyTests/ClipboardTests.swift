import AppKit
import XCTest
@testable import Lowkey

final class ClipboardTests: XCTestCase {
    func testRestoresAllRepresentationsAndEmptyClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let png = Data([137, 80, 78, 71])
        item.setData(png, forType: .png)
        item.setString("file:///tmp/example.txt", forType: .fileURL)
        board.writeObjects([item])
        let snapshot = PasteService.writeClipboard("Dictation", board: board)
        XCTAssertEqual(board.string(forType: .string), "Dictation")
        PasteService.restoreClipboard(snapshot, board: board)
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.string(forType: .fileURL), "file:///tmp/example.txt")
        board.clearContents()
        let empty = PasteService.writeClipboard("Dictation", board: board)
        PasteService.restoreClipboard(empty, board: board)
        XCTAssertNil(board.string(forType: .string))
    }
    func testDoesNotOverwriteNewClipboardEvenWhenTextMatches() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let snapshot = PasteService.writeClipboard("Dictation", board: board)
        board.clearContents()
        board.setString("Dictation", forType: .string)
        PasteService.restoreClipboard(snapshot, board: board)
        XCTAssertEqual(board.string(forType: .string), "Dictation")
    }
}
