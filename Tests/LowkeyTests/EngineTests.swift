import XCTest
@testable import Lowkey

final class EngineTests: XCTestCase {
    func testRetiredEngineCanRestartButShutdownCannot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lowkey-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("LOWKEY_SUPPORT_DIRECTORY", root.path, 1)
        defer { unsetenv("LOWKEY_SUPPORT_DIRECTORY") }
        let server = root.appendingPathComponent("server")
        let source = """
        #!/usr/bin/env python3
        import http.server, sys
        port = int(sys.argv[sys.argv.index('--port') + 1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
            def log_message(self, *args): pass
        http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
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
        XCTAssertTrue(engine.ensureReady(config: config, timeout: 8))
        XCTAssertTrue(engine.isReady)
        engine.retire()
        XCTAssertTrue(engine.ensureReady(config: config, timeout: 8), "Retirement must preserve fallback recovery")
        XCTAssertTrue(engine.isRunning)
        engine.stop()
        XCTAssertFalse(engine.ensureReady(config: config, timeout: 1), "Shutdown must reject late recovery")
    }
}
