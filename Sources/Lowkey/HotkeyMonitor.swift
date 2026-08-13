import AppKit

final class HotkeyMonitor {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    private var global: Any?
    private var local: Any?
    var hotkey: DictationHotkey = .rightCommand

    private var holding = false

    func start() {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        holding = false
    }

    private func handle(_ event: NSEvent) {
        let isTargetKey = event.keyCode == hotkey.keyCode
        let flagDown = event.modifierFlags.contains(hotkey.requiredFlag)
        if isTargetKey && flagDown && !holding {
            holding = true
            onHoldStart?()
        } else if holding && (!flagDown || (isTargetKey && !flagDown)) {
            holding = false
            onHoldEnd?()
        }
    }
}
