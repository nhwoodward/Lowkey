import AppKit
import XCTest
@testable import Lowkey

final class HotkeyTests: XCTestCase {
    func testReleasingRightCommandStopsWhileLeftRemainsHeld() {
        let monitor = HotkeyMonitor()
        var starts = 0, ends = 0
        monitor.onHoldStart = { starts += 1 }
        monitor.onHoldEnd = { ends += 1 }
        monitor.handle(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10))
        monitor.handle(keyCode: 55, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x18))
        monitor.handle(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        monitor.handle(keyCode: 55, flags: [])
        XCTAssertEqual(ends, 1)
    }
    func testWrongModifierDoesNotStartRecording() {
        let monitor = HotkeyMonitor()
        var starts = 0
        monitor.onHoldStart = { starts += 1 }
        monitor.handle(keyCode: 55, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08))
        XCTAssertEqual(starts, 0)
    }
}
