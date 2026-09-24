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
            let notices = messages.map { FlowBarMode.notice($0, symbol: "doc.on.clipboard") }
            for mode in [FlowBarMode.idle, .listening, .working, .success] + messages.map(FlowBarMode.failed) + notices {
                content.apply(mode)
                let size = content.preferredSize
                XCTAssertEqual(size.height, 36, "\(mode)")
                content.frame = NSRect(origin: .zero, size: size)
                content.layoutSubtreeIfNeeded()
                guard !content.label.isHidden else { continue }
                let textWidth = ceil((content.label.stringValue as NSString).size(withAttributes: [.font: content.label.font!]).width)
                XCTAssertEqual(content.label.frame.minX, 38, accuracy: 0.5, "\(mode)")
                XCTAssertEqual(size.width - content.label.frame.maxX, 14, accuracy: 0.5, "\(mode)")
                XCTAssertGreaterThanOrEqual(content.label.frame.width, textWidth + 3, "\(mode)")
                XCTAssertLessThanOrEqual(content.label.frame.width, textWidth + 5, "\(mode)")
                XCTAssertEqual(content.label.frame.midY, 18, accuracy: 0.5, "\(mode)")
            }
        }
    }

    func testFinishingMessageResizesAndLaterStatesDoNotKeepItsWidth() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            content.apply(.working)
            let transcribingWidth = content.preferredSize.width
            XCTAssertEqual(transcribingWidth, 36)
            content.showWorkingMessage("Finishing dictation…")
            XCTAssertGreaterThan(content.preferredSize.width, transcribingWidth)
            XCTAssertEqual(content.preferredSize.height, 36)
            XCTAssertEqual(content.accessibilityLabel(), "Finishing dictation…")
            content.apply(.working)
            XCTAssertEqual(content.preferredSize.width, transcribingWidth)
            content.apply(.success)
            XCTAssertEqual(content.preferredSize, NSSize(width: 36, height: 36))
            XCTAssertTrue(content.label.isHidden)
            content.apply(.failed("Nothing heard"))
            XCTAssertLessThan(content.preferredSize.width, 160)
            content.apply(.listening)
            XCTAssertEqual(content.preferredSize, NSSize(width: 132, height: 36))
            content.apply(.idle)
            XCTAssertEqual(content.preferredSize, NSSize(width: 36, height: 36))
        }
    }

    func testLongMultilineAndEmptyErrorsStayCompactAndAccessible() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            let longMessage = "Whisper model not found at\n/Users/example/" + String(repeating: "Long model folder/", count: 30)
            content.apply(.failed(longMessage))
            let button = content.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden }
            XCTAssertEqual(button?.accessibilityLabel(), "Whisper model not found", "The clickable message must be named")
            XCTAssertEqual(content.preferredSize.height, 36)
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
                XCTAssertEqual(content.preferredSize.height, 36)
            }
            content.apply(.failed("マイクを確認してください 🎙️"))
            XCTAssertEqual(content.preferredSize.height, 36)
            XCTAssertLessThan(content.preferredSize.width, 480)
        }
    }

    func testHandsFreeAndCountdownWidenTheListeningBarOnlyWhileListening() async {
        await MainActor.run {
            let content = FlowBarContent(frame: .zero)
            content.apply(.listening)
            XCTAssertEqual(content.preferredSize, NSSize(width: 132, height: 36))
            content.setListeningAccessory(handsFree: true, remaining: nil)
            XCTAssertEqual(content.preferredSize, NSSize(width: 156, height: 36))
            XCTAssertEqual(content.accessibilityLabel(), "Listening hands-free")
            content.setListeningAccessory(handsFree: false, remaining: 9)
            XCTAssertEqual(content.accessibilityLabel(), "Listening, 9 seconds left")
            XCTAssertEqual(content.preferredSize, NSSize(width: 156, height: 36))
            content.frame = NSRect(origin: .zero, size: content.preferredSize)
            content.layoutSubtreeIfNeeded()
            let waveform = content.subviews.first { String(describing: type(of: $0)) == "WaveformView" }!
            XCTAssertEqual(waveform.frame.maxX, 156 - 14 - 16 - 8, accuracy: 0.5, "The countdown must not overlap the wave")
            content.setListeningAccessory(handsFree: false, remaining: nil)
            XCTAssertEqual(content.preferredSize.width, 132)
            content.setListeningAccessory(handsFree: true, remaining: nil)
            content.apply(.working)
            XCTAssertEqual(content.preferredSize.width, 36)
        }
    }

    func testScreenConstrainedPanelStaysCenteredWithFixedHeight() {
        for screen in [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -300, y: 100, width: 300, height: 600)] {
            for width: CGFloat in [36, 132, 480] {
                let frame = FlowBarController.panelFrame(for: NSSize(width: width, height: 36), in: screen)
                XCTAssertEqual(frame.height, 48) // 36-point glass plus its optical margin.
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

    func testCompletionLayoutKeepsRingGeometryAtEverySpinAngle() async {
        await MainActor.run {
            let glyph = ProgressGlyphView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            glyph.layoutSubtreeIfNeeded()
            let ring = glyph.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }[0]
            for degrees in stride(from: 0, to: 360, by: 15) {
                glyph.beginSpinning(animated: false)
                ring.setValue(Double(degrees) * .pi / 180, forKeyPath: "transform.rotation.z")
                glyph.completeIntoCheck(animated: true)
                for size: CGFloat in [20, 16, 20] {
                    glyph.setFrameSize(NSSize(width: size, height: size))
                    glyph.needsLayout = true
                    glyph.layoutSubtreeIfNeeded()
                    XCTAssertEqual(ring.bounds.width, size, accuracy: 0.001, "angle=\(degrees)")
                    XCTAssertEqual(ring.bounds.height, size, accuracy: 0.001, "angle=\(degrees)")
                }
                let angle = ring.value(forKeyPath: "transform.rotation.z") as! Double
                XCTAssertEqual(sin(angle), sin(Double(degrees) * .pi / 180), accuracy: 0.001)
                XCTAssertEqual(cos(angle), cos(Double(degrees) * .pi / 180), accuracy: 0.001)
            }
        }
    }

    func testFastCompletionPreservesTheInFlightGlyphFade() async {
        await MainActor.run {
            let content = FlowBarContent(frame: NSRect(x: 0, y: 0, width: 132, height: 36))
            content.apply(.listening)
            content.apply(.working, animated: true)
            let glyph = content.subviews.compactMap { $0 as? ProgressGlyphView }.first!
            let fade = glyph.layer!.animation(forKey: "appear")!
            content.apply(.success, animated: true)
            XCTAssertFalse(glyph.isHidden)
            XCTAssertEqual(glyph.layer!.animation(forKey: "appear")?.beginTime, fade.beginTime)
            content.apply(.listening, animated: true)
            XCTAssertTrue(glyph.isHidden)
            XCTAssertNil(glyph.layer!.animation(forKey: "appear"))
            for shape in glyph.layer!.sublayers!.compactMap({ $0 as? CAShapeLayer }) {
                XCTAssertEqual(shape.strokeEnd, 0)
                XCTAssertTrue(shape.animationKeys()?.isEmpty ?? true)
            }
        }
    }
}
