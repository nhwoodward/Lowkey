import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    var onOpenSettings: (() -> Void)?
    var onUpload: ((URL) -> Void)?
    var onPasteItem: ((HistoryItem) -> Void)?
    // Name of the app a history paste will land in, when one is known.
    var pasteTargetName: (() -> String?)?

    private let model: HistoryModel
    private var importItem: NSToolbarItem?
    private var searchItem: NSSearchToolbarItem?
    private var historyObserver: UUID?
    private var busy = false

    private static let importID = NSToolbarItem.Identifier("import")
    private static let searchID = NSToolbarItem.Identifier("search")

    init(hotkeyTitle: String) {
        var source: () -> [HistoryItem] = { HistoryStore.shared.items }
        #if DEBUG
        switch Self.demo {
        case "empty":
            source = { [] }
        case "select":
            // The hovered row also shows the no-recording and language states.
            source = {
                HistoryStore.shared.items.enumerated().map { index, item in
                    var item = item
                    if index == 1 { item.audioFileName = nil; item.language = "es" }
                    return item
                }
            }
        default:
            break
        }
        #endif
        model = HistoryModel(hotkeyTitle: hotkeyTitle, source: source)
        let window = HistoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("LowkeyHistory")
        let toolbar = NSToolbar(identifier: "LowkeyHistoryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: HistoryView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.onFind = { [weak self] in self?.searchItem?.beginSearchInteraction() }
        model.onPaste = { [weak self] item in self?.onPasteItem?(item) }
        model.pasteTargetName = { [weak self] in self?.pasteTargetName?() }
        historyObserver = HistoryStore.shared.observe { [weak self] in self?.model.reload() }
        #if DEBUG
        stageDemo()
        #endif
    }

    deinit {
        if let historyObserver {
            HistoryStore.shared.stopObserving(historyObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHotkeyTitle(_ title: String) {
        model.hotkeyTitle = title
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        importItem?.isEnabled = !busy
    }

    // Day titles are relative, so refresh them whenever the window comes back.
    override func showWindow(_ sender: Any?) {
        model.reload()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.importID, Self.searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch id {
        case Self.importID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Import Audio"
            item.toolTip = "Import Audio…"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import Audio")
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = !busy
            item.target = self
            item.action = #selector(importAudio)
            importItem = item
            return item
        case Self.searchID:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.delegate = self
            searchItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func importAudio() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Lowkey transcribes up to two minutes of audio on this Mac. The original file is not changed."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onUpload?(url)
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model.query = sender.stringValue
    }

    // Return and Down move into the results; Escape clears and returns to the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            model.focusList(selectingFirst: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            control.stringValue = ""
            model.query = ""
            searchItem?.endSearchInteraction()
            model.focusList(selectingFirst: false)
            return true
        default:
            return false
        }
    }

    #if DEBUG
    // Dev-only: LOWKEY_HISTORY_DEMO=empty|select|detail|replace|replace-row|search:<text>
    // stages window states for snapshot review without mouse or keyboard input.
    private static var demo: String? { ProcessInfo.processInfo.environment["LOWKEY_HISTORY_DEMO"] }

    private func stageDemo() {
        guard let demo = Self.demo, !demo.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if demo.hasPrefix("search:") {
                let text = String(demo.dropFirst("search:".count))
                self.searchItem?.searchField.stringValue = text
                self.model.query = text
                return
            }
            self.model.stageDemo(demo)
            if demo == "replace", let item = self.model.detail {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.model.beginReplacement(for: item, heard: "low key", inDetail: true)
                }
            }
        }
    }
    #endif
}

// Lowkey usually runs as a menu bar accessory, so this window is often
// clicked while another app is active. Taking key before dispatch lets that
// first click act on the row instead of only activating the app.
private final class HistoryWindow: NSWindow {
    var onFind: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow, attachedSheet == nil {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f", let onFind {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
