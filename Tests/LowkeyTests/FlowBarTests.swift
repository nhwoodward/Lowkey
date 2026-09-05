import AppKit
import XCTest
@testable import Lowkey

final class FlowBarTests: XCTestCase {
    func testEveryStateKeepsTheRecordingHeightAndFitsItsContent() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            let messages = [
                "Nothing heard", "Discarded as noise", "Still working",
                "Couldn't save the recording", "Whisper engine is not responding",
                "Enable Microphone in Settings > Privacy, then try again.",
                "Paste couldn't finish. Your text is saved in History.",
                "Paste couldn't finish. Your text is on the clipboard.",
                "Speech recognition could not start", "Could not start the microphone.",
                "The audio file contains no recording.",
                "This audio format could not be read. Try a WAV, M4A, or MP3 file.",
                "Whisper returned no text.",
                "Whisper returned an invalid response. Please try again.",
                "Whisper could not transcribe the recording (HTTP 503).",
                "Recording is too long.",
                "Choose a multilingual Whisper model in Dictation settings for this language.",
            ]
            for mode in [FlowBarMode.idle, .listening, .working, .success] + messages.map(FlowBarMode.failed) {
                content.apply(mode)
                let size = content.preferredSize
                XCTAssertEqual(size.height, 48, "\(mode)")
                content.frame = NSRect(origin: .zero, size: size)
                content.layoutSubtreeIfNeeded()
                guard !content.label.isHidden else { continue }
                let textWidth = ceil((content.label.stringValue as NSString).size(withAttributes: [.font: content.label.font!]).width)
                XCTAssertEqual(content.label.frame.minX, 42, accuracy: 0.5, "\(mode)")
                XCTAssertEqual(size.width - content.label.frame.maxX, 18, accuracy: 0.5, "\(mode)")
                XCTAssertGreaterThanOrEqual(content.label.frame.width, textWidth + 3, "\(mode)")
                XCTAssertLessThanOrEqual(content.label.frame.width, textWidth + 5, "\(mode)")
                XCTAssertEqual(content.label.frame.midY, 24, accuracy: 0.5, "\(mode)")
            }
        }
    }

    func testFinishingMessageResizesAndLaterStatesDoNotKeepItsWidth() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            content.apply(.working)
            let transcribingWidth = content.preferredSize.width
            XCTAssertEqual(transcribingWidth, 48)
            content.showWorkingMessage("Finishing dictation…")
            XCTAssertGreaterThan(content.preferredSize.width, transcribingWidth)
            XCTAssertEqual(content.preferredSize.height, 48)
            XCTAssertEqual(content.accessibilityLabel(), "Finishing dictation…")
            content.apply(.working)
            XCTAssertEqual(content.preferredSize.width, transcribingWidth)
            content.apply(.success)
            XCTAssertEqual(content.preferredSize, NSSize(width: 48, height: 48))
            XCTAssertTrue(content.label.isHidden)
            content.apply(.failed("Nothing heard"))
            XCTAssertLessThan(content.preferredSize.width, 160)
            content.apply(.listening)
            XCTAssertEqual(content.preferredSize, NSSize(width: 152, height: 48))
            content.apply(.idle)
            XCTAssertEqual(content.preferredSize, NSSize(width: 48, height: 48))
        }
    }

    func testLongMultilineAndEmptyErrorsStayCompactAndAccessible() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            let longMessage = "Whisper model not found at\n/Users/example/" + String(repeating: "Long model folder/", count: 30)
            content.apply(.failed(longMessage))
            XCTAssertEqual(content.preferredSize.height, 48)
            XCTAssertLessThan(content.preferredSize.width, 240)
            XCTAssertEqual(content.label.stringValue, "Whisper model not found")
            XCTAssertFalse(content.label.stringValue.contains("\n"))
            XCTAssertEqual(content.label.maximumNumberOfLines, 1)
            XCTAssertEqual(content.label.lineBreakMode, .byClipping)
            XCTAssertEqual(content.label.toolTip, longMessage.replacingOccurrences(of: "\n", with: " "))
            XCTAssertEqual(content.accessibilityLabel(), content.label.stringValue)
            XCTAssertEqual(content.accessibilityHelp(), content.label.toolTip)
            for message in ["", " \n\t "] {
                content.apply(.failed(message))
                XCTAssertEqual(content.label.stringValue, "Something went wrong")
                XCTAssertEqual(content.preferredSize.height, 48)
            }
            content.apply(.failed("マイクを確認してください 🎙️"))
            XCTAssertEqual(content.preferredSize.height, 48)
            XCTAssertLessThan(content.preferredSize.width, 480)
        }
    }

    func testScreenConstrainedPanelStaysCenteredWithFixedHeight() {
        for screen in [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -300, y: 100, width: 300, height: 600)] {
            for width: CGFloat in [48, 152, 480] {
                let frame = FlowBarController.panelFrame(for: NSSize(width: width, height: 48), in: screen)
                XCTAssertEqual(frame.height, 60) // 48-point glass plus its optical margin.
                XCTAssertEqual(frame.midX, screen.midX)
                XCTAssertEqual(frame.minY, screen.minY + 18)
                XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 12)
                XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 12)
            }
        }
    }

    func testRingCompletesIntoCheckAndResetsWithoutStaleAnimations() async {
        await MainActor.run {
            let glyph = ProgressGlyphView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            glyph.layoutSubtreeIfNeeded()
            let shapes = glyph.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            let ring = shapes[0], check = shapes[1]
            glyph.beginSpinning(animated: true)
            XCTAssertEqual(glyph.accessibilityLabel(), "Transcribing")
            XCTAssertNotNil(ring.animation(forKey: "spin"))
            glyph.completeIntoCheck(animated: true)
            XCTAssertEqual(glyph.accessibilityLabel(), "Dictation complete")
            XCTAssertNil(ring.animation(forKey: "spin"))
            XCTAssertEqual(ring.strokeEnd, 1)
            XCTAssertEqual(check.strokeEnd, 1)
            XCTAssertNotNil(check.animation(forKey: "draw"))
            glyph.reset()
            XCTAssertEqual(ring.strokeEnd, 0)
            XCTAssertEqual(check.strokeEnd, 0)
            XCTAssertTrue(ring.animationKeys()?.isEmpty ?? true)
            XCTAssertTrue(check.animationKeys()?.isEmpty ?? true)
            glyph.beginSpinning(animated: false)
            glyph.completeIntoCheck(animated: false)
            XCTAssertTrue(ring.animationKeys()?.isEmpty ?? true)
            XCTAssertTrue(check.animationKeys()?.isEmpty ?? true)
        }
    }
}
