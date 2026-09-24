import XCTest
@testable import Lowkey

final class TranscriberTests: XCTestCase {
    func testUnavailableParakeetDoesNotFallThroughToWhisper() throws {
        #if arch(arm64)
        var config = Config.makeDefault()
        config.engine = .parakeet
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(count: 16044).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try Transcriber.transcribe(fileURL: file, config: config)) { error in
            guard case ParakeetError.notReady = error else {
                return XCTFail("Expected the selected engine's error, got \(error)")
            }
        }
        #endif
    }

    func testShortParakeetRecordingDoesNotStartRecognition() throws {
        #if arch(arm64)
        var config = Config.makeDefault()
        config.engine = .parakeet
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(count: 8044).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Transcriber.transcribe(fileURL: file, config: config), .silence)
        #endif
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1/inference")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    func testHTTPErrorNeverBecomesTranscript() {
        for status in [400, 404, 500, 503] {
            XCTAssertThrowsError(try Transcriber.decodeResponse(data: Data("Internal Server Error".utf8), response: response(status)))
            XCTAssertThrowsError(try Transcriber.decodeResponse(data: Data(#"{"text":"error masquerading as speech"}"#.utf8), response: response(status)))
        }
    }
    func testRejectsMalformedAndUnexpectedSuccessBodies() {
        for text in ["", "<html>error</html>", "{}", #"{"error":{"message":"failed"}}"#, #"{"text":123}"#] {
            XCTAssertThrowsError(try Transcriber.decodeResponse(data: Data(text.utf8), response: response(200)))
        }
    }
    func testAcceptsJSONTranscriptAndSilence() throws {
        XCTAssertEqual(try Transcriber.decodeResponse(data: Data(#"{"text":"Hello world."}"#.utf8), response: response(200)), "Hello world.")
        XCTAssertEqual(try Transcriber.decodeResponse(data: Data(#"{"text":""}"#.utf8), response: response(200)), "")
    }
}
