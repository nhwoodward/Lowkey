import Foundation
import FluidAudio

enum ParakeetError: LocalizedError {
    case notReady
    case busy
    case timeout

    var errorDescription: String? {
        switch self {
        case .notReady: return "Parakeet is still loading. Try again in a moment."
        case .busy: return "Parakeet is still finishing the previous recording."
        case .timeout: return "Parakeet took too long. Try again."
        }
    }
}

// Own every load and inference so unloading can wait for Core ML to finish
// before another engine allocates its model. Cached files remain on disk.
// Mutable state lives on stateQueue; onStatusChange is main-thread only.
final class ParakeetEngine: @unchecked Sendable {
    // The loader calls its argument when a first-run model download begins.
    typealias Loader = (_ downloading: @escaping @Sendable () -> Void) async throws -> AsrManager

    static let shared = ParakeetEngine()
    static let modelVersion: AsrModelVersion = .v2
    // Main-thread notification that readiness or download state changed.
    var onStatusChange: (() -> Void)?
    private let stateQueue = DispatchQueue(label: "app.lowkey.parakeet")
    private let loadManager: Loader
    private var manager: AsrManager?
    private var operation: Task<Void, Never>?
    private var inference: Task<Void, Never>?
    private var generation = 0
    private var errorMessage: String?
    private var loading = false
    private var fetching = false
    private var callbacks: [(Bool) -> Void] = []

    init(loadManager: @escaping Loader = ParakeetEngine.makeManager) {
        self.loadManager = loadManager
    }

    var lastError: String? { stateQueue.sync { errorMessage } }
    var ready: Bool { stateQueue.sync { manager != nil } }
    var downloading: Bool { stateQueue.sync { fetching } }

    func start(completion: @escaping (Bool) -> Void) {
        stateQueue.sync {
            if manager != nil {
                DispatchQueue.main.async { completion(true) }
                return
            }
            callbacks.append(completion)
            guard !loading else { return }
            loading = true
            errorMessage = nil
            generation += 1
            let ticket = generation
            let previous = operation
            operation = Task.detached(priority: .userInitiated) {
                await previous?.value
                guard !Task.isCancelled else { return }
                let started = Date()
                do {
                    let candidate = try await self.loadManager {
                        self.markDownloading(ticket: ticket)
                    }
                    let accepted = self.stateQueue.sync { () -> Bool in
                        guard self.generation == ticket, !Task.isCancelled else { return false }
                        self.manager = candidate
                        return true
                    }
                    if accepted {
                        AppLog.line(String(format: "parakeet ready model=%@ init=%.1fs",
                                           String(describing: Self.modelVersion), Date().timeIntervalSince(started)))
                        self.finishLoading(true, ticket: ticket)
                    } else {
                        await candidate.cleanup()
                    }
                } catch {
                    self.stateQueue.sync {
                        guard self.generation == ticket else { return }
                        self.errorMessage = error.localizedDescription
                    }
                    AppLog.line("parakeet init failed: \(error.localizedDescription)")
                    self.finishLoading(false, ticket: ticket)
                }
            }
        }
    }

    // Readiness is revoked immediately. The completion is a release barrier:
    // even a loader or inference that ignores cancellation has finished by then.
    func unload(completion: @escaping () -> Void = {}) {
        stateQueue.sync {
            generation += 1
            loading = false
            fetching = false
            let pending = callbacks
            callbacks = []
            let previous = operation
            let activeInference = inference
            let retiredManager = manager
            manager = nil
            previous?.cancel()
            activeInference?.cancel()
            operation = Task.detached(priority: .userInitiated) {
                await previous?.value
                await activeInference?.value
                await retiredManager?.cleanup()
                AppLog.line("parakeet unloaded")
                DispatchQueue.main.async { completion() }
            }
            DispatchQueue.main.async { pending.forEach { $0(false) } }
        }
    }

    private func markDownloading(ticket: Int) {
        let changed = stateQueue.sync { () -> Bool in
            guard generation == ticket, loading, !fetching else { return false }
            fetching = true
            return true
        }
        if changed { DispatchQueue.main.async { self.onStatusChange?() } }
    }

    private func finishLoading(_ success: Bool, ticket: Int) {
        let pending = stateQueue.sync { () -> [(Bool) -> Void] in
            guard generation == ticket else { return [] }
            loading = false
            fetching = false
            let pending = callbacks
            callbacks = []
            return pending
        }
        DispatchQueue.main.async { pending.forEach { $0(success) } }
    }

    private static func makeManager(downloading: @escaping @Sendable () -> Void) async throws -> AsrManager {
        #if arch(x86_64)
        throw SelectedEngineError.parakeetNeedsAppleSilicon
        #else
        // Loading cached files also reports download progress, so ask the disk.
        if !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: modelVersion), version: modelVersion) {
            downloading()
        }
        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        try Task.checkCancellation()
        let manager = AsrManager(config: .default)
        do {
            try await manager.loadModels(models)
            try Task.checkCancellation()
            var state = TdtDecoderState.make()
            _ = try await manager.transcribe(
                [Float](repeating: 0, count: 4800), decoderState: &state)
            try Task.checkCancellation()
            return manager
        } catch {
            await manager.cleanup()
            throw error
        }
        #endif
    }

    // Blocking bridge used only on the app's serial transcription queue.
    func transcribe(fileURL: URL) throws -> String {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let task = try stateQueue.sync { () throws -> Task<Void, Never> in
            guard let manager else { throw ParakeetError.notReady }
            guard inference == nil else { throw ParakeetError.busy }
            let task = Task.detached(priority: .userInitiated) {
                do {
                    var state = TdtDecoderState.make()
                    let result = try await manager.transcribe(fileURL, decoderState: &state)
                    box.set(.success(result.text))
                } catch {
                    box.set(.failure(error))
                }
                self.stateQueue.sync { self.inference = nil }
                sem.signal()
            }
            inference = task
            return task
        }
        guard sem.wait(timeout: .now() + 60) == .success else {
            task.cancel()
            unload()
            stateQueue.sync { errorMessage = ParakeetError.timeout.localizedDescription }
            throw ParakeetError.timeout
        }
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<String, Error> = .failure(ParakeetError.timeout)
        func set(_ result: Result<String, Error>) { lock.withLock { value = result } }
        func get() throws -> String { try lock.withLock { try value.get() } }
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
