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

// English-only Parakeet TDT v2 through FluidAudio and in-process CoreML. Weights download
// once and stay cached. Readiness is published only after model warmup.
final class ParakeetEngine {
    static let shared = ParakeetEngine()
    static let modelVersion: AsrModelVersion = .v2
    private let stateQueue = DispatchQueue(label: "app.lowkey.parakeet")
    private var manager: AsrManager?
    private var errorMessage: String?
    var lastError: String? { stateQueue.sync { errorMessage } }
    private var loading = false
    private var callbacks: [(Bool) -> Void] = []

    var ready: Bool {
        stateQueue.sync { manager != nil }
    }

    func start(completion: @escaping (Bool) -> Void) {
        let shouldStart = stateQueue.sync { () -> Bool in
            if manager != nil {
                DispatchQueue.main.async { completion(true) }
                return false
            }
            callbacks.append(completion)
            guard !loading else { return false }
            loading = true
            errorMessage = nil
            return true
        }
        guard shouldStart else { return }
        #if arch(x86_64)
        // Intel Macs have no Neural Engine; a 0.6b CoreML model on CPU
        // would be slower than whisper. Decline so whisper stays primary.
        stateQueue.sync { errorMessage = "Parakeet needs Apple Silicon" }
        AppLog.line("parakeet skipped: no Neural Engine on Intel")
        finishLoading(false)
        return
        #endif
        Task.detached(priority: .userInitiated) {
            do {
                let started = Date()
                let models = try await AsrModels.downloadAndLoad(version: Self.modelVersion)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // One tiny inference finishes ANE warmup before real audio.
                var state = TdtDecoderState.make()
                _ = try? await manager.transcribe(
                    [Float](repeating: 0, count: 3200), decoderState: &state)
                self.stateQueue.sync { self.manager = manager }
                AppLog.line(String(
                    format: "parakeet ready model=%@ init=%.1fs", String(describing: Self.modelVersion), Date().timeIntervalSince(started)))
                self.finishLoading(true)
            } catch {
                self.stateQueue.sync { self.errorMessage = error.localizedDescription }
                AppLog.line("parakeet init failed: \(error.localizedDescription)")
                self.finishLoading(false)
            }
        }
    }

    private func finishLoading(_ success: Bool) {
        let pending = stateQueue.sync { () -> [(Bool) -> Void] in
            loading = false
            let pending = callbacks
            callbacks = []
            return pending
        }
        DispatchQueue.main.async { pending.forEach { $0(success) } }
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
        let task = Task.detached(priority: .userInitiated) {
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
            task.cancel()
            stateQueue.sync { self.manager = nil; self.errorMessage = "Parakeet timed out; using Whisper" }
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
                let models = try await AsrModels.downloadAndLoad(version: ParakeetEngine.modelVersion)
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
