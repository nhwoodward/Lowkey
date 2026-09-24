import XCTest
@testable import Lowkey

final class EngineTests: XCTestCase {
    func testStoppedEngineRequiresExplicitRestart() async throws {
        // Match the app's background transcription queue and leave the main
        // run loop available for Foundation process and network setup.
        try await Task.detached { try await Self.exerciseEngineLifecycle() }.value
    }

    private static func exerciseEngineLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lowkey-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("LOWKEY_SUPPORT_DIRECTORY", root.path, 1)
        defer { unsetenv("LOWKEY_SUPPORT_DIRECTORY") }
        let server = root.appendingPathComponent("server")
        let source = """
        #!/usr/bin/python3
        import http.server, socketserver, sys
        port = int(sys.argv[sys.argv.index('--port') + 1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
            def log_message(self, *args): print(args, flush=True)
        class Server(socketserver.TCPServer):
            allow_reuse_address = True
        server = Server(('127.0.0.1', port), Handler)
        print('mock engine listening', server.server_address, flush=True)
        server.serve_forever()
        """
        try source.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let model = root.appendingPathComponent("model")
        try Data().write(to: model)
        var config = Config.makeDefault()
        config.whisperServerPath = server.path
        config.modelPath = model.path
        config.port = Int.random(in: 30000...55000)
        let engine = Engine()
        defer { engine.stop() }
        func diagnostics() -> String {
            let log = (try? String(contentsOf: Config.logsDirectory.appendingPathComponent("engine.log"), encoding: .utf8)) ?? "No engine output"
            return "\(engine.lastError ?? "No engine error"): \(log)"
        }
        XCTAssertTrue(engine.ensureReady(config: config, timeout: 8), diagnostics())
        XCTAssertTrue(engine.isReady)
        await withCheckedContinuation { continuation in
            engine.stop { continuation.resume() }
        }
        XCTAssertFalse(engine.isRunning, "Stop completion must wait until the model process exits")
        XCTAssertFalse(engine.isReady)
        XCTAssertFalse(engine.ensureReady(config: config, timeout: 1), "A deselected engine must reject late recovery")
        let restarted = await withCheckedContinuation { continuation in
            engine.start(config: config) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(restarted, diagnostics())
        XCTAssertTrue(engine.isRunning)
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }
}
