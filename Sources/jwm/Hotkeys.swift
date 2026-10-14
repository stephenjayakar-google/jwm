import AppKit
import Carbon.HIToolbox

/// Global key handling via a session event tap: ⌘D starts a prefix sequence, Ctrl-(Shift-)Tab cycles panes.
final class Hotkeys {
    static let shared = Hotkeys()

    /// Tags events we post ourselves so the tap lets them through.
    private static let syntheticMarker: Int64 = 0x6A776D // "jwm"

    private var tap: CFMachPort?
    private var prefixActive = false
    /// Key-ups whose key-downs we swallowed.
    private var swallowedUps = Set<Int>()

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in Hotkeys.shared.handle(type, event) },
            userInfo: nil
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Hotkeys.syntheticMarker { return pass }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedUps.remove(key) != nil ? nil : pass
        }
        guard type == .keyDown else { return pass }

        let flags = event.flags
        let cmd = flags.contains(.maskCommand), ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)

        // Work happens async so the tap returns fast (slow taps get disabled by the system).
        if prefixActive {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            prefixActive = false
            swallowedUps.insert(key)
            DispatchQueue.main.async {
                Hud.shared.hide()
                WM.shared.command(key, shift: shift)
            }
            return nil
        }
        if key == kVK_ANSI_D && cmd && !ctrl && !opt && !shift {
            prefixActive = true
            swallowedUps.insert(key)
            DispatchQueue.main.async { Hud.shared.show("⌘D –") }
            return nil
        }
        if key == kVK_Tab && ctrl && !cmd && !opt {
            swallowedUps.insert(key)
            DispatchQueue.main.async { WM.shared.focusPane(shift ? -1 : 1) }
            return nil
        }
        return pass
    }

    /// ⌘D ⌘D sends a real ⌘D to the focused app.
    func sendLiteralPrefix() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: down)
            else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Hotkeys.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
