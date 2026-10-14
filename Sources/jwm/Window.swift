import AppKit

/// A buffer: one top-level app window.
final class Window {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let app: AXUIElement
    let appName: String
    /// True while parked offscreen by us.
    var parked = false
    /// Where the current layout puts this window; nil while parked.
    var expected: CGRect?
    /// Last time we pushed the window back, and how many times in a row; used to stop fighting
    /// apps that insist on their own frame.
    var lastCorrection = Date.distantPast
    var corrections = 0
    /// Move/resize events before this time are echoes of our own setFrame/park.
    var ownChangeUntil = Date.distantPast
    /// Frame before jwm touched it, restored on quit.
    var home: CGRect?

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, app: AXUIElement, appName: String) {
        self.id = id
        self.element = element
        self.pid = pid
        self.app = app
        self.appName = appName
    }

    var title: String { element.string(kAXTitleAttribute) ?? "" }
    var label: String { title.isEmpty || title == appName ? appName : "\(appName) — \(title)" }

    static func isManageable(_ element: AXUIElement) -> Bool {
        element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && element.bool(kAXMinimizedAttribute) != true
            && element.bool("AXFullScreen") != true
            && element.isSettable(kAXSizeAttribute)
    }

    func setFrame(_ rect: CGRect) {
        // Chrome/Electron animate frame changes while enhanced UI is on, which breaks resizing.
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        // Position, size, position: the size can be clamped by the old position near screen edges.
        element.setPosition(rect.origin)
        element.setSize(rect.size)
        element.setPosition(rect.origin)
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
        expected = rect
        parked = false
        ownChangeUntil = Date().addingTimeInterval(0.4)
    }

    /// Moves the window so only its top-left pixel sits in the bottom-right corner of `screen`.
    func park(in screen: CGRect) {
        element.setPosition(CGPoint(x: screen.maxX - 1, y: screen.maxY - 1))
        parked = true
        expected = nil
        ownChangeUntil = Date().addingTimeInterval(0.4)
    }

    func focus() {
        element.set(kAXMainAttribute, kCFBooleanTrue)
        element.perform(kAXRaiseAction)
        app.set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    func close() {
        element.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }
}

/// Watches one app for window creation / focus changes.
final class AppWatcher {
    let pid: pid_t
    let element: AXUIElement
    let name: String
    private let observer: AXObserver

    init?(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        element = AXUIElementCreateApplication(pid)
        name = app.localizedName ?? "?"
        AXUIElementSetMessagingTimeout(element, 0.5)

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return nil }
        self.observer = observer
        // Fails while the app is still launching; we retry on the next refresh.
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, nil) == .success
        else { return nil }
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func watch(_ window: AXUIElement) {
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowMiniaturizedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, nil)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

private func axCallback(_: AXObserver, _ element: AXUIElement, _ notification: CFString, _: UnsafeMutableRawPointer?) {
    WM.shared.axEvent(notification as String, element)
}
