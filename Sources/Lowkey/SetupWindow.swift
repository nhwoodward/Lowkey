import AppKit
import AVFoundation
import Combine
import SwiftUI

// First-run checklist: the two permissions dictation needs and the speech
// model, with live status so nothing has to be relaunched.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onDone: (() -> Void)?
    private let model: SetupModel

    init(hotkeyTitle: String, status: EngineStatus) {
        model = SetupModel(hotkeyTitle: hotkeyTitle, status: status)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Set Up Lowkey"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.onDone = { [weak self] in self?.close() }
        let host = NSHostingController(rootView: SetupView(model: model))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func refresh(status: EngineStatus) {
        if model.status != status { model.status = status }
        model.refreshPermissions()
    }

    func setHotkeyTitle(_ title: String) {
        model.hotkeyTitle = title
    }

    // Closing is a choice too; the menu bar keeps offering setup until it is done.
    func windowWillClose(_ notification: Notification) {
        onDone?()
    }
}

private final class SetupModel: ObservableObject {
    @Published var hotkeyTitle: String
    @Published var status: EngineStatus
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var trusted = PasteService.isTrusted()
    var onDone: (() -> Void)?

    init(hotkeyTitle: String, status: EngineStatus) {
        self.hotkeyTitle = hotkeyTitle
        self.status = status
    }

    var complete: Bool { microphone == .authorized && trusted && status == .ready }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let isTrusted = PasteService.isTrusted()
        if isTrusted != trusted { trusted = isTrusted }
    }

    func allowMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshPermissions() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func allowAccessibility() {
        PasteService.promptAccessibilityIfNeeded()
        PasteService.openAccessibilitySettings()
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                SetupRow(symbol: "mic", title: "Microphone",
                         detail: "Hears you while you dictate. Audio stays on this Mac.") {
                    if model.microphone == .authorized {
                        Allowed()
                    } else {
                        Button("Allow…", action: model.allowMicrophone)
                    }
                }
                SetupRow(symbol: "accessibility", title: "Accessibility",
                         detail: model.trusted
                             ? "Detects your shortcut and types into the app you are using."
                             : "Detects your shortcut and types into the app you are using. Turn on Lowkey in the list that opens.") {
                    if model.trusted {
                        Allowed()
                    } else {
                        Button("Allow…", action: model.allowAccessibility)
                    }
                }
                SetupRow(symbol: "waveform", title: "Speech model", detail: modelDetail) {
                    modelStatus
                }
            } header: {
                VStack(spacing: 0) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Set Up Lowkey")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 8)
                    Text("Hold \(model.hotkeyTitle), speak, and let go. Your words appear wherever you are typing.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.complete
                         ? "All set. Hold \(model.hotkeyTitle) in any app to try it."
                         : "You can finish later from the menu bar.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Done") { model.onDone?() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 10)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(poll) { _ in model.refreshPermissions() }
    }

    private var modelDetail: String {
        switch model.status {
        case .ready: return "Runs entirely on this Mac."
        case .preparing: return "Loading into memory."
        case .downloading: return "About 500 MB, downloaded once. Then it works offline."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch model.status {
        case .ready:
            Allowed(title: "Ready")
        case .preparing, .downloading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(model.status.summary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Speech model failed")
        }
    }
}

private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct Allowed: View {
    var title = "Allowed"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
