import Darwin
import Foundation

final class Engine {
    private var process: Process?
    private let queue = DispatchQueue(label: "app.whisperly.engine")
    private var stopRequested = false
    private(set) var isReady = false
    private(set) var lastError: String?

    var isRunning: Bool { process?.isRunning == true }

    func start(config: Config, completion: @escaping (Bool) -> Void) {
        queue.async {
            self.stopRequested = false
            if self.isReady, self.isRunning {
                DispatchQueue.main.async { completion(true) }
                return
            }
            // Never adopt an orphan on our port. A leftover whisper-server
            // keeps previous transcripts as decoder context and gets slower
            // with every dictation. Kill it and own the next process.
            self.teardownLocked()
            Self.terminatePortOccupant(port: config.bindPort)
            do {
                try self.spawn(config: config)
            } catch {
                self.lastError = error.localizedDescription
                DispatchQueue.main.async { completion(false) }
                return
            }
            let ok = self.waitUntilReady(config: config, timeout: 90)
            self.isReady = ok
            if !ok {
                self.lastError = self.lastError ?? "Whisper engine did not become ready."
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func stop() {
        stopRequested = true
        queue.sync {
            self.teardownLocked()
        }
    }

    // Blocking recovery used by the transcription retry path. Call from a
    // background thread only.
    func ensureReady(config: Config, timeout: TimeInterval) -> Bool {
        queue.sync {
            if self.stopRequested { return false }
            if self.probe(config: config), self.isRunning {
                self.isReady = true
                return true
            }
            self.teardownLocked()
            Self.terminatePortOccupant(port: config.bindPort)
            if self.stopRequested { return false }
            do {
                try self.spawn(config: config)
            } catch {
                self.lastError = error.localizedDescription
                self.isReady = false
                return false
            }
            let ok = self.waitUntilReady(config: config, timeout: timeout)
            self.isReady = ok
            if !ok {
                self.lastError = self.lastError ?? "Whisper engine did not become ready."
            }
            return ok
        }
    }

    private func teardownLocked() {
        if let process {
            process.terminate()
            Self.waitForExit(process, timeout: 1.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                Self.waitForExit(process, timeout: 0.4)
            }
        }
        process = nil
        isReady = false
    }

    private func spawn(config: Config) throws {
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
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.isReady = false
            }
        }
        try process.run()
        try? log.close()
        self.process = process
        AppLog.line("engine spawned pid=\(process.processIdentifier) threads=\(config.effectiveThreads) max_context=0")
    }

    private func waitUntilReady(config: Config, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stopRequested { return false }
            if process?.isRunning == false {
                lastError = "Whisper engine exited while starting. See engine.log."
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
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.8)
        return ok
    }

    private static func terminatePortOccupant(port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return
        }
        waitForExit(task, timeout: 1.0)
        if task.isRunning { task.terminate() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) } ?? []
        let selfPID = getpid()
        let victims = pids.filter { pid in
            pid != selfPID && Self.isWhisperServer(pid)
        }
        for pid in victims {
            AppLog.line("engine replacing occupant pid=\(pid) port=\(port)")
            kill(pid, SIGTERM)
        }
        if !victims.isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
            for pid in victims {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func isWhisperServer(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("whisper-server")
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

}

enum EngineError: LocalizedError {
    case missingBinary(String)
    case missingModel(String)

    var errorDescription: String? {
        switch self {
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
        let text = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = text.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
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
