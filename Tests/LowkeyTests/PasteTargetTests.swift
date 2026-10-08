import AppKit
import XCTest
@testable import Lowkey

final class PasteTargetTests: XCTestCase {
    func testApplicationWithoutPIDCanReceiveAndActivateForPaste() {
        let identity = UUID()
        let application = StubRunningApplication(identity: identity, pid: -1)
        let frontmost = StubRunningApplication(identity: identity, pid: -1)
        let target = PasteTarget(application: application)

        XCTAssertEqual(target.pid, -1)
        XCTAssertTrue(target.isValidDestination)
        XCTAssertTrue(target.matches(frontmost))
        XCTAssertTrue(target.activate())
        XCTAssertEqual(application.activationCount, 1)
    }

    func testAnotherApplicationWithTheSamePIDAndBundleDoesNotMatch() {
        for pid: pid_t in [-1, 1234] {
            let original = StubRunningApplication(pid: pid)
            let replacement = StubRunningApplication(pid: pid)
            let target = PasteTarget(application: original)

            XCTAssertEqual(original.bundleIdentifier, replacement.bundleIdentifier)
            XCTAssertFalse(target.matches(replacement))
            XCTAssertFalse(target.matches(nil))
        }
    }

    func testTerminatedTargetCannotReceiveOrActivateForPaste() {
        let application = StubRunningApplication(pid: 1234)
        let target = PasteTarget(application: application)
        XCTAssertTrue(target.isValidDestination)

        application.simulatesTermination = true

        XCTAssertFalse(target.isValidDestination)
        XCTAssertFalse(target.matches(application))
        XCTAssertFalse(target.activate())
        XCTAssertEqual(application.activationCount, 0)
    }

    func testMissingAndCurrentApplicationCannotReceivePaste() {
        let missing = PasteTarget(application: nil)
        XCTAssertFalse(missing.isValidDestination)
        XCTAssertFalse(missing.matches(nil))
        XCTAssertFalse(missing.activate())

        let current = PasteTarget(application: .current)
        XCTAssertTrue(current.isCurrentApplication)
        XCTAssertFalse(current.isValidDestination)
        XCTAssertFalse(current.activate())
    }
}

private final class StubRunningApplication: NSRunningApplication, @unchecked Sendable {
    private let identity: UUID
    private let reportedPID: pid_t
    var simulatesTermination = false
    private(set) var activationCount = 0

    init(identity: UUID = UUID(), pid: pid_t) {
        self.identity = identity
        self.reportedPID = pid
        super.init()
    }

    override var processIdentifier: pid_t { reportedPID }
    override var bundleIdentifier: String? { "test.same.bundle" }
    override var isTerminated: Bool { simulatesTermination }
    override var hash: Int { identity.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? StubRunningApplication else { return false }
        return identity == other.identity
    }

    override func activate(options: NSApplication.ActivationOptions = []) -> Bool {
        activationCount += 1
        return true
    }
}
