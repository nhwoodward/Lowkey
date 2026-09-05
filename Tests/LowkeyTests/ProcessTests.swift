import XCTest
@testable import Lowkey

final class ProcessTests: XCTestCase {
    func testDrainsLargeOutputWithoutDeadlock() {
        let result = TimedProcess.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stdout.write('x' * 200000)"], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 200000)
    }
    func testBoundsRuntime() {
        let start = Date()
        let result = TimedProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
        XCTAssertEqual(result.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
