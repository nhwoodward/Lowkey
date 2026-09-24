import FluidAudio
import XCTest
@testable import Lowkey

final class ParakeetLifecycleTests: XCTestCase {
    func testUnloadClearsReadinessAndAllowsExplicitReload() async {
        let engine = ParakeetEngine(loadManager: { _ in AsrManager() })
        let loaded = expectation(description: "loaded")
        engine.start { ok in XCTAssertTrue(ok); loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertTrue(engine.ready)

        let unloaded = expectation(description: "unloaded")
        engine.unload { unloaded.fulfill() }
        XCTAssertFalse(engine.ready)
        await fulfillment(of: [unloaded], timeout: 3)

        let reloaded = expectation(description: "reloaded")
        engine.start { ok in XCTAssertTrue(ok); reloaded.fulfill() }
        await fulfillment(of: [reloaded], timeout: 3)
        XCTAssertTrue(engine.ready)
        let finished = expectation(description: "finished")
        engine.unload { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
    }

    func testUnloadWaitsForCancelledLoadAndRejectsItsLateResult() async {
        let gate = LoadGate()
        let entered = expectation(description: "loader entered")
        let engine = ParakeetEngine(loadManager: { _ in
            entered.fulfill()
            // Model loading may finish after cancellation; simulate that exactly.
            await gate.wait()
            return AsrManager()
        })
        let cancelled = expectation(description: "cancelled startup")
        engine.start { ok in XCTAssertFalse(ok); cancelled.fulfill() }
        await fulfillment(of: [entered], timeout: 3)
        let unloaded = expectation(description: "unloaded after loader returns")
        engine.unload { unloaded.fulfill() }
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(engine.ready)
        await gate.release()
        await fulfillment(of: [unloaded], timeout: 3)
        XCTAssertFalse(engine.ready, "A deselected model must never publish late readiness")
    }

    func testReselectionWaitsForPreviousLoadToFinish() async {
        let gate = LoadGate()
        let count = LoadCount()
        let firstEntered = expectation(description: "first loader entered")
        let engine = ParakeetEngine(loadManager: { _ in
            let attempt = await count.increment()
            if attempt == 1 {
                firstEntered.fulfill()
                await gate.wait()
            }
            return AsrManager()
        })
        let cancelled = expectation(description: "first selection cancelled")
        engine.start { ok in XCTAssertFalse(ok); cancelled.fulfill() }
        await fulfillment(of: [firstEntered], timeout: 3)
        let unloaded = expectation(description: "unloaded")
        engine.unload { unloaded.fulfill() }
        let selectedAgain = expectation(description: "selected again")
        engine.start { ok in XCTAssertTrue(ok); selectedAgain.fulfill() }
        let attemptsBeforeRelease = await count.value
        XCTAssertEqual(attemptsBeforeRelease, 1, "Do not load another model while the old load drains")
        await gate.release()
        await fulfillment(of: [cancelled, unloaded, selectedAgain], timeout: 3)
        let attemptsAfterRelease = await count.value
        XCTAssertEqual(attemptsAfterRelease, 2)
        XCTAssertTrue(engine.ready)
        let finished = expectation(description: "finished")
        engine.unload { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
    }
}

private actor LoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LoadCount {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}
