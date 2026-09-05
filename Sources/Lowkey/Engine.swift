import Darwin
import Foundation

final class Engine {
    private var process: Process?
    private let queue = DispatchQueue(label: "app.lowkey.engine")
    private let stateLock = NSLock()
    private var generation = 0
    private var stopped = false
    private var ready = false
    private var errorMessage: String?
    private var probeError: String?

    var isReady: Bool { stateLock.withLock { ready } }
    var lastError: String? { stateLock.withLock { errorMessage } }
    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    func start(config: Config, completion: @escaping (Bool) -> Void) {
        let ticket = stateLock.withLock { () -> Int in
            generation += 1
            stopped = false
            ready = false
            errorMessage = nil
            return generation
        }
        queue.async {
            guard self.isCurrent(ticket) else { return }
            self.teardownLocked()
            let ok = self.launch(config: config, timeout: 90, ticket: ticket)
            DispatchQueue.main.async {
                guard self.isCurrent(ticket) else { return }
                completion(ok)
            }
        }
    }

    // Release the fallback's model while Parakeet is healthy. Unlike shutdown,
    // retirement must allow the next failed inference to restart Whisper.
    func retire() {
        let ticket = stateLock.withLock { generation }
        queue.async {
            guard self.isCurrent(ticket) else { return }
            self.teardownLocked()
        }
    }

    func stop() {
        stateLock.withLock {
            generation += 1
            stopped = true
            ready = false
        }
        queue.sync { self.teardownLocked() }
    }

    // Call only from the serialized background transcription queue.
    func ensureReady(config: Config, timeout: TimeInterval) -> Bool {
        let ticket = stateLock.withLock { generation }
        return queue.sync {
            guard isCurrent(ticket) else { return false }
            if process?.isRunning == true, probe(config: config) {
                updateState(ready: true, error: nil, ticket: ticket)
                return true
            }
            teardownLocked()
            return launch(config: config, timeout: timeout, ticket: ticket)
        }
    }

    private func isCurrent(_ ticket: Int) -> Bool {
        stateLock.withLock { !stopped && generation == ticket }
    }

    private func updateState(ready: Bool, error: String?, ticket: Int) {
        stateLock.withLock {
            guard !stopped, generation == ticket else { return }
            self.ready = ready
            errorMessage = error
        }
    }

    private func launch(config: Config, timeout: TimeInterval, ticket: Int) -> Bool {
        guard isCurrent(ticket) else { return false }
        do {
            try spawn(config: config)
            let ok = waitUntilReady(config: config, timeout: timeout, ticket: ticket)
            let detail = probeError.map { " \($0)" } ?? " Check its model and server path."
            updateState(ready: ok, error: ok ? nil : "Whisper did not become ready.\(detail)", ticket: ticket)
            if !ok { teardownLocked() }
            return ok && isCurrent(ticket)
        } catch {
            updateState(ready: false, error: error.localizedDescription, ticket: ticket)
            return false
        }
    }

    private func teardownLocked() {
        if let process, process.isRunning {
            process.terminate()
            Self.waitForExit(process, timeout: 1.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                Self.waitForExit(process, timeout: 0.4)
            }
        }
        process = nil
        stateLock.withLock { ready = false }
    }

    private func spawn(config: Config) throws {
        if config.language != "en", (config.modelPath as NSString).lastPathComponent.contains(".en") {
            throw EngineError.englishOnlyModel
        }
        guard FileManager.default.isExecutableFile(atPath: config.whisperServerPath) else {
            throw EngineError.missingBinary(config.whisperServerPath)
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw EngineError.missingModel(config.modelPath)
        }

        let logURL = Config.logsDirectory.appendingPathComponent("engine.log")
        AppLog.rotateIfNeeded(logURL)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperServerPath)
        process.arguments = [
            "-m", config.modelPath,
            "--host", config.bindHost,
            "--port", String(config.bindPort),
            "-l", config.language,
            "-t", String(config.effectiveThreads),
            // Do not carry previous transcripts into the next decode.
            "-mc", "0",
            "-sns",
            "-nt",
            "-nth", "0.6",
        ]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] ended in
            self?.queue.async {
                guard let self, self.process === ended else { return }
                self.stateLock.withLock { self.ready = false }
            }
        }
        try process.run()
        try? log.close()
        self.process = process
        AppLog.line("engine spawned pid=\(process.processIdentifier) threads=\(config.effectiveThreads) max_context=0")
    }

    private func waitUntilReady(config: Config, timeout: TimeInterval, ticket: Int) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isCurrent(ticket) { return false }
            if process?.isRunning == false {
                return false
            }
            if probe(config: config) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    private func probe(config: Config) -> Bool {
        var request = URLRequest(url: config.baseURL)
        request.timeoutInterval = 0.6
        let sem = DispatchSemaphore(value: 0)
        let result = ProbeResult()
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result.setReady()
            } else {
                result.setError(error?.localizedDescription ?? "Health endpoint returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 0.8) == .timedOut { task.cancel() }
        probeError = result.error
        return result.ready
    }

    private final class ProbeResult {
        let lock = NSLock()
        private var value = false
        private var message: String?
        var ready: Bool { lock.withLock { value } }
        var error: String? { lock.withLock { message } }
        func setReady() { lock.withLock { value = true } }
        func setError(_ error: String) { lock.withLock { message = error } }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

}

enum EngineError: LocalizedError {
    case englishOnlyModel
    case missingBinary(String)
    case missingModel(String)

    var errorDescription: String? {
        switch self {
        case .englishOnlyModel:
            return "Choose a multilingual Whisper model in Dictation settings for this language."
        case .missingBinary(let path):
            return "whisper-server not found at \(path)"
        case .missingModel(let path):
            return "Whisper model not found at \(path)"
        }
    }
}

enum AppLog {
    private static let url = Config.logsDirectory.appendingPathComponent("app.log")
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    static func line(_ message: String) {
        write(to: url, message)
    }

    static func write(to file: URL, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = text.data(using: .utf8) else { return }
        rotateIfNeeded(file)
        if FileManager.default.fileExists(atPath: file.path),
           let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    static func rotateIfNeeded(_ file: URL, maxBytes: UInt64 = 2 * 1024 * 1024) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return }
        let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".old")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: file, to: backup)
    }
}
