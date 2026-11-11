import Accelerate
import Foundation
import FluidAudio

enum ParakeetError: LocalizedError {
    case notReady
    case timeout

    var errorDescription: String? {
        switch self {
        case .notReady: return "Parakeet is still loading. Try again in a moment."
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
    // The newest inference. Each one waits for the one before it, so a
    // warm-up and a real clip never overlap.
    private var inference: Task<Void, Never>?
    private var inferenceTicket = 0
    private var lastInference = ContinuousClock.now
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
                        // Loading ends with a warm-up inference.
                        self.lastInference = .now
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
            try await warm(manager)
            try Task.checkCancellation()
            return manager
        } catch {
            await manager.cleanup()
            throw error
        }
        #endif
    }

    // An idle model is slow to wake. Across 3,200 logged dictations a clip
    // took about 0.16 s when the model had run in the last 20 s and about
    // 0.52 s after a minute idle, whatever the clip's length. Called when a
    // recording is shown and while it runs, so that cost is paid as the user
    // speaks instead of after they stop.
    static let warmInterval: Duration = .seconds(10)

    func warmUpIfIdle() {
        stateQueue.sync {
            guard inference == nil, lastInference.duration(to: .now) >= Self.warmInterval else { return }
            _ = try? enqueue { manager in
                let started = ContinuousClock.now
                guard !Task.isCancelled, (try? await Self.warm(manager)) != nil else { return }
                AppLog.line("parakeet warmup=\(started.duration(to: .now).milliseconds)ms")
            }
        }
    }

    // Blocking bridges used only on the app's serial transcription queue.
    func transcribe(fileURL: URL) throws -> String {
        try transcribe { manager, state in try await manager.transcribe(fileURL, decoderState: &state).text }
    }

    // Samples straight from the recorder: 16 kHz mono 16-bit PCM.
    func transcribe(pcm: Data) throws -> String {
        let samples = Self.floats(fromPCM16: pcm)
        return try transcribe { manager, state in try await manager.transcribe(samples, decoderState: &state).text }
    }

    private func transcribe(
        _ recognize: @escaping @Sendable (AsrManager, inout TdtDecoderState) async throws -> String
    ) throws -> String {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let task = try stateQueue.sync {
            try enqueue { manager in
                do {
                    try Task.checkCancellation()
                    var state = TdtDecoderState.make()
                    box.set(.success(try await recognize(manager, &state)))
                } catch {
                    box.set(.failure(error))
                }
                sem.signal()
            }
        }
        guard sem.wait(timeout: .now() + 60) == .success else {
            task.cancel()
            unload()
            stateQueue.sync { errorMessage = ParakeetError.timeout.localizedDescription }
            throw ParakeetError.timeout
        }
        return try box.get()
    }

    // Queues work behind any inference already running. Call on stateQueue.
    private func enqueue(_ work: @escaping @Sendable (AsrManager) async -> Void) throws -> Task<Void, Never> {
        guard let manager else { throw ParakeetError.notReady }
        let previous = inference
        inferenceTicket += 1
        let ticket = inferenceTicket
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            await work(manager)
            self.stateQueue.sync {
                self.lastInference = .now
                if self.inferenceTicket == ticket { self.inference = nil }
            }
        }
        inference = task
        return task
    }

    // The shortest clip the model accepts, all silence: every stage runs and
    // nothing is recognized.
    static func warm(_ manager: AsrManager) async throws {
        var state = TdtDecoderState.make()
        _ = try await manager.transcribe([Float](repeating: 0, count: 4800), decoderState: &state)
    }

    static func floats(fromPCM16 pcm: Data) -> [Float] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { floats, initialized in
            pcm.withUnsafeBytes { raw in
                vDSP_vflt16(raw.bindMemory(to: Int16.self).baseAddress!, 1, floats.baseAddress!, 1, vDSP_Length(count))
            }
            var scale: Float = 1 / 32_768
            vDSP_vsmul(floats.baseAddress!, 1, &scale, floats.baseAddress!, 1, vDSP_Length(count))
            initialized = count
        }
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
// LOWKEY_TEST_PARAKEET_IDLE=<seconds> waits before each clip, and
// LOWKEY_TEST_PARAKEET_WARM=1|alternate runs the silent warm-up inference
// first (for every clip, or every second one), to measure what an idle
// Neural Engine costs and whether warming recovers it.
enum ParakeetTestHarness {
    static func run(paths: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let idle = env["LOWKEY_TEST_PARAKEET_IDLE"].flatMap(Double.init) ?? 0
        let warmMode = env["LOWKEY_TEST_PARAKEET_WARM"] ?? ""
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let t0 = Date()
                let models = try await AsrModels.downloadAndLoad(version: ParakeetEngine.modelVersion)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                try await ParakeetEngine.warm(manager)
                print(String(format: "init %.1fs", Date().timeIntervalSince(t0)))
                for (index, path) in paths.enumerated() {
                    if idle > 0 { try await Task.sleep(for: .seconds(idle)) }
                    var note = ""
                    if warmMode == "1" || (warmMode == "alternate" && index % 2 == 1) {
                        let w = Date()
                        try await ParakeetEngine.warm(manager)
                        note = String(format: " warmup=%.2fs", Date().timeIntervalSince(w))
                    }
                    var state = TdtDecoderState.make()
                    let t = Date()
                    let result = try await manager.transcribe(
                        URL(fileURLWithPath: path), decoderState: &state)
                    print(String(
                        format: "clip %@ %.2fs idle=%.0fs%@ | %@",
                        (path as NSString).lastPathComponent,
                        Date().timeIntervalSince(t),
                        idle,
                        note,
                        result.text))
                    fflush(stdout)
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

private extension Duration {
    var milliseconds: Int {
        Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
    }
}
