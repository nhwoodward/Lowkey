import XCTest
@testable import Lowkey

final class TranscriberTests: XCTestCase {
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
