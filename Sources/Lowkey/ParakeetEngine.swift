import Foundation
import FluidAudio

enum ParakeetError: LocalizedError {
    case notReady
    case timeout

    var errorDescription: String? {
        switch self {
        case .notReady: return "Parakeet engine is not loaded"
        case .timeout: return "Parakeet transcription timed out"
        }
    }
}

// Parakeet TDT 0.6b (int8) on the Apple Neural Engine via FluidAudio.
// In-process CoreML: no server, no HTTP, and no GPU involvement, so it is
// unaffected by the GPU contention and thermal throttling that degrade
// whisper on this machine. Weights download once from Hugging Face and
// stay cached; the ANE-compiled model stays resident after load.
final class ParakeetEngine {
    static let shared = ParakeetEngine()
    private let stateQueue = DispatchQueue(label: "app.lowkey.parakeet")
    private var manager: AsrManager?
    private(set) var lastError: String?

    var ready: Bool {
        stateQueue.sync { manager != nil }
    }

    func start(completion: @escaping (Bool) -> Void) {
        if ready {
            DispatchQueue.main.async { completion(true) }
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let started = Date()
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // One tiny inference finishes ANE warmup before real audio.
                var state = TdtDecoderState.make()
                _ = try? await manager.transcribe(
                    [Float](repeating: 0, count: 3200), decoderState: &state)
                self.stateQueue.sync { self.manager = manager }
                AppLog.line(String(
                    format: "parakeet ready init=%.1fs", Date().timeIntervalSince(started)))
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.stateQueue.sync { self.lastError = error.localizedDescription }
                AppLog.line("parakeet init failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // Blocking bridge for the synchronous transcription path. Call from a
    // background thread only. A fresh decoder state per request keeps
    // dictations independent, like whisper's max_context=0.
    func transcribe(fileURL: URL) throws -> String {
        guard let manager = stateQueue.sync(execute: { self.manager }) else {
            throw ParakeetError.notReady
        }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                var state = TdtDecoderState.make()
                let result = try await manager.transcribe(fileURL, decoderState: &state)
                box.set(.success(result.text))
            } catch {
                box.set(.failure(error))
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 60) == .success else {
            throw ParakeetError.timeout
        }
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<String, Error> = .failure(ParakeetError.timeout)

        func set(_ result: Result<String, Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func get() throws -> String {
            lock.lock()
            defer { lock.unlock() }
            return try value.get()
        }
    }
}

// LOWKEY_TEST_PARAKEET=<wav>[,<wav>...] runs the engine end to end without
// the UI: init, transcribe each clip with timings, print, exit. Used to
// verify speed and accuracy on real dictation audio before enabling.
enum ParakeetTestHarness {
    static func run(paths: [String]) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let t0 = Date()
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                var warm = TdtDecoderState.make()
                _ = try? await manager.transcribe(
                    [Float](repeating: 0, count: 3200), decoderState: &warm)
                print(String(format: "init %.1fs", Date().timeIntervalSince(t0)))
                for path in paths {
                    var state = TdtDecoderState.make()
                    let t = Date()
                    let result = try await manager.transcribe(
                        URL(fileURLWithPath: path), decoderState: &state)
                    print(String(
                        format: "clip %@ %.2fs | %@",
                        (path as NSString).lastPathComponent,
                        Date().timeIntervalSince(t),
                        result.text))
                }
            } catch {
                print("FAIL: \(error)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
