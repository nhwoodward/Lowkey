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
        handle(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let isTargetKey = keyCode == hotkey.keyCode
        // Device-dependent flags distinguish the two Command/Option keys.
        // The aggregate Command flag stays set when only the other side is held.
        let mask: UInt
        switch hotkey {
        case .rightCommand: mask = 0x10
        case .leftCommand: mask = 0x08
        case .rightOption: mask = 0x40
        case .function: mask = NSEvent.ModifierFlags.function.rawValue
        }
        let flagDown = flags.rawValue & mask != 0
        if isTargetKey && flagDown && !holding {
            holding = true
            onHoldStart?()
        } else if holding && (!flagDown || (isTargetKey && !flagDown)) {
            holding = false
            onHoldEnd?()
        }
    }
}
