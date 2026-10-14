import AppKit
import Carbon.HIToolbox

final class WM {
    static let shared = WM()

    let gap: CGFloat = 8

    private(set) var windows: [CGWindowID: Window] = [:]
    private var apps: [pid_t: AppWatcher] = [:]
    private(set) var tabs: [Tab] = []
    private(set) var tabIndex = 0
    var tab: Tab { tabs[tabIndex] }
    /// Most recently focused first.
    private var mru: [CGWindowID] = []
    private var started = false
    private var refreshScheduled = false
    /// Windows that reported a move/resize, checked once things settle.
    private var movedWindows = Set<CGWindowID>()
    private var frameCheckScheduled = false
    /// Focus events caused by our own focusing are ignored until this time.
    private var ignoreFocusUntil = Date.distantPast

    lazy var border = Border()
    lazy var bufferList = BufferList()

    // MARK: Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            self.scheduleRefresh(after: 0.3)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            self.scheduleRefresh()
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let watcher = self.apps[app.processIdentifier],
                  let window = watcher.element.element(kAXFocusedWindowAttribute) else { return }
            self.userFocused(window)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in self.layout() }

        refresh()
        let first = Tab()
        if let window = frontmostWindow() {
            first.focused.show(window.id)
            touch(window.id)
        }
        tabs = [first]
        started = true
        layout()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.refresh() }
    }

    /// Puts parked windows back where they were before jwm started (or centered).
    /// Also used by `jwm --restore` after a crash.
    func restoreAll() {
        let screen = screenBounds()
        for window in windows.values {
            guard var frame = window.element.frame, window.parked || !isMostlyOnScreen(frame) else { continue }
            if let home = window.home {
                frame = home
            } else {
                frame.size.width = min(frame.width, screen.width)
                frame.size.height = min(frame.height, screen.height)
                frame.origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            }
            window.setFrame(frame)
        }
    }

    private func isMostlyOnScreen(_ frame: CGRect) -> Bool {
        let visible = frame.intersection(screenBounds())
        return visible.width * visible.height >= frame.width * frame.height * 0.3
    }

    // MARK: Window tracking

    func scheduleRefresh(after delay: Double = 0.1) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Reconciles our window table with what the apps report.
    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        let pids = Set(running.map(\.processIdentifier))
        for pid in apps.keys where !pids.contains(pid) { apps[pid] = nil }
        for app in running where apps[app.processIdentifier] == nil {
            apps[app.processIdentifier] = AppWatcher(app)
        }

        var seen = Set<CGWindowID>()
        var added: [CGWindowID] = []
        for watcher in apps.values {
            guard let elements = watcher.element.elements(kAXWindowsAttribute) else {
                // App didn't answer; assume its windows are unchanged.
                seen.formUnion(windows.values.filter { $0.pid == watcher.pid }.map(\.id))
                continue
            }
            for element in elements {
                guard let id = element.windowID, Window.isManageable(element) else { continue }
                seen.insert(id)
                if windows[id] == nil {
                    let window = Window(id: id, element: element, pid: watcher.pid,
                                        app: watcher.element, appName: watcher.name)
                    if let frame = element.frame, isMostlyOnScreen(frame) { window.home = frame }
                    windows[id] = window
                    watcher.watch(element)
                    added.append(id)
                }
            }
        }
        let removed = windows.keys.filter { !seen.contains($0) }
        for id in removed { forget(id) }

        guard started, !(added.isEmpty && removed.isEmpty) else { return }
        // New windows open in the selected pane, like Emacs displaying a new buffer.
        for id in added { display(id) }
        layout()
    }

    private func forget(_ id: CGWindowID) {
        windows[id] = nil
        mru.removeAll { $0 == id }
        for tab in tabs {
            for pane in tab.panes where pane.remove(id) {
                fallback(pane, in: tab)
            }
        }
    }

    private func frontmostWindow() -> Window? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = apps[pid]?.element.element(kAXFocusedWindowAttribute)?.windowID else { return nil }
        return windows[id]
    }

    func axEvent(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            // Windows often get their subrole a moment after creation.
            scheduleRefresh(after: 0.15)
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            scheduleRefresh(after: 0.05)
        case kAXFocusedWindowChangedNotification:
            userFocused(element)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            frameChanged(element)
        default:
            break
        }
    }

    /// The user focused a window (click, Cmd-Tab, app activation).
    private func userFocused(_ element: AXUIElement) {
        guard started, Date() > ignoreFocusUntil, let id = element.windowID else { return }
        guard windows[id] != nil else { scheduleRefresh(); return }
        // The selected pane's window just closed and the app is focusing another of its windows:
        // stay in this pane and let refresh() fall back through its history, like Emacs kill-buffer.
        if let current = tab.focused.current, current != id,
           windows[current]?.element.string(kAXRoleAttribute) == nil {
            scheduleRefresh()
            return
        }
        touch(id)
        if let pane = tab.visiblePanes.first(where: { $0.current == id }) {
            if pane !== tab.focused {
                tab.focused = pane
                updateChrome()
            }
            return
        }
        // Focused a window that isn't on screen: switch to it in the selected pane.
        display(id)
        layout()
    }

    // MARK: External moves and resizes

    private func frameChanged(_ element: AXUIElement) {
        guard started, let id = element.windowID, let window = windows[id],
              Date() > window.ownChangeUntil else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 { window.draggedByMouse = true }
        movedWindows.insert(id)
        scheduleFrameCheck()
    }

    private func scheduleFrameCheck() {
        guard !frameCheckScheduled else { return }
        frameCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.frameCheckScheduled = false
            // Wait until the user lets go of a drag.
            if NSEvent.pressedMouseButtons & 1 != 0 { return self.scheduleFrameCheck() }
            let ids = self.movedWindows
            self.movedWindows.removeAll()
            var relayout = false
            for id in ids {
                if let window = self.windows[id], self.checkFrame(window) { relayout = true }
            }
            if relayout { self.layout() }
        }
    }

    /// Reacts to a window ending up somewhere other than where we put it. Returns true if the
    /// layout itself changed and needs reapplying.
    private func checkFrame(_ window: Window) -> Bool {
        let dragged = window.draggedByMouse
        window.draggedByMouse = false
        guard let actual = window.element.frame else { return false }
        let close = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }

        if let expected = window.expected {
            if close(actual, expected) { return false }
            // Dragging a tiled window's edge resizes its pane.
            let resized = abs(actual.width - expected.width) > 2 || abs(actual.height - expected.height) > 2
            if dragged, resized, let pane = tab.visiblePanes.first(where: { $0.current == window.id }) {
                let half = gap / 2
                if tab.adjust(pane, from: expected, to: actual,
                              bounds: screenBounds().insetBy(dx: half, dy: half), inset: half) {
                    return true
                }
            }
            // Anything else (title bar drag, app resizing itself): snap back, unless the app keeps fighting.
            guard Date().timeIntervalSince(window.lastCorrection) > 1 else { return false }
            window.lastCorrection = Date()
            window.setFrame(expected)
        } else if window.parked {
            // Something pulled a parked buffer back on screen.
            let visible = actual.intersection(screenBounds())
            guard visible.width > 20, visible.height > 20,
                  Date().timeIntervalSince(window.lastCorrection) > 1 else { return false }
            window.lastCorrection = Date()
            window.park(in: flipped(NSScreen.screens.first?.frame ?? .zero))
        }
        return false
    }

    private func touch(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
    }

    // MARK: Buffers and panes

    /// Whether `id` can be shown in `pane` without also being visible in another pane of `tab`.
    private func available(_ id: CGWindowID, in tab: Tab, for pane: Pane?) -> Bool {
        windows[id] != nil && !tab.panes.contains { $0 !== pane && $0.current == id }
    }

    /// Points `pane` at a showable entry after its current one went away.
    private func fallback(_ pane: Pane, in tab: Tab) {
        let ok = { (id: CGWindowID) in self.available(id, in: tab, for: pane) }
        if let current = pane.current, ok(current) { return }
        if pane.step(-1, where: ok) || pane.step(1, where: ok) { return }
        pane.clear()
    }

    /// Shows `id` in the selected pane, taking it away from any other pane in this tab.
    func display(_ id: CGWindowID) {
        let pane = tab.focused
        pane.show(id)
        touch(id)
        for other in tab.panes where other !== pane && other.current == id {
            fallback(other, in: tab)
        }
    }

    /// Emacs other-buffer: the most recent window not visible in this tab.
    private func otherBuffer() -> CGWindowID? {
        let ok = { (id: CGWindowID) in self.available(id, in: self.tab, for: nil) }
        return mru.first(where: ok) ?? windows.keys.sorted().first(where: ok)
    }

    /// Buffers for the buffer list: not-visible ones in MRU order first, then visible ones.
    func bufferOrder() -> [(Window, visible: Bool)] {
        let visible = Set(tab.panes.compactMap(\.current))
        let ordered = mru + windows.keys.filter { !mru.contains($0) }.sorted()
        let hidden = ordered.filter { !visible.contains($0) }
        let shown = ordered.filter { visible.contains($0) }
        return (hidden.map { ($0, false) } + shown.map { ($0, true) }).compactMap { id, vis in
            windows[id].map { ($0, vis) }
        }
    }

    // MARK: Layout

    /// Visible frame of the primary screen in AX coordinates.
    func screenBounds() -> CGRect {
        flipped(NSScreen.screens.first?.visibleFrame ?? .zero)
    }

    private func paneRects() -> [(Pane, CGRect)] {
        let half = gap / 2
        return tab.rects(in: screenBounds().insetBy(dx: half, dy: half)).map { ($0, $1.insetBy(dx: half, dy: half)) }
    }

    /// Moves every window to where the current tab says it belongs and focuses the selected pane.
    func layout() {
        guard started else { return }
        var frames: [CGWindowID: CGRect] = [:]
        for (pane, rect) in paneRects() {
            if let id = pane.current { frames[id] = rect }
        }
        let screen = flipped(NSScreen.screens.first?.frame ?? .zero)
        for window in windows.values {
            if let frame = frames[window.id] {
                window.setFrame(frame)
                log("place \(window.label) \(frame) → \(window.element.frame.map { "\($0)" } ?? "?")")
            } else if !window.parked {
                window.park(in: screen)
            }
        }
        focusSelected()
    }

    private func focusSelected() {
        ignoreFocusUntil = Date().addingTimeInterval(0.3)
        if let id = tab.focused.current, let window = windows[id] {
            window.focus()
        } else {
            // Empty pane: take keyboard focus so typing doesn't go to a parked window.
            NSApp.activate(ignoringOtherApps: true)
        }
        updateChrome()
    }

    /// Focus border and menu bar title.
    private func updateChrome() {
        StatusBar.shared.update()
        let rects = paneRects()
        guard let (pane, rect) = rects.first(where: { $0.0 === tab.focused }),
              rects.count > 1 || pane.current == nil else {
            border.hide()
            return
        }
        border.show(around: flipped(rect), empty: pane.current == nil)
    }

    /// Tree, pane histories and focus; printed on SIGUSR1.
    func dump() -> String {
        func name(_ id: CGWindowID?) -> String { id.flatMap { windows[$0]?.label } ?? "∅" }
        func describe(_ node: Node, _ depth: Int) -> String {
            let pad = String(repeating: "  ", count: depth)
            if let pane = node as? Pane {
                let history = pane.history.map { $0 == pane.current ? "[\(name($0))]" : name($0) }
                return pad + (pane === tab.focused ? "* " : "- ") + history.joined(separator: " ⇄ ") + "\n"
            }
            let split = node as! Split
            return pad + (split.vertical ? "| " : "— ") + String(format: "%.2f", split.ratio) + "\n"
                + describe(split.a, depth + 1) + describe(split.b, depth + 1)
        }
        return "tab \(tabIndex + 1)/\(tabs.count)\(tab.zoomed != nil ? " (zoomed)" : "")\n" + describe(tab.root, 0)
    }

    // MARK: Commands

    func command(_ key: Int, shift: Bool) {
        log("command key=\(key)")
        switch key {
        case kVK_ANSI_2: split(vertical: false)
        case kVK_ANSI_3: split(vertical: true)
        case kVK_ANSI_0: deletePane()
        case kVK_ANSI_1: deleteOtherPanes()
        case kVK_ANSI_O: focusPane(1)
        case kVK_ANSI_J: walkHistory(-1)
        case kVK_ANSI_L: walkHistory(1)
        case kVK_ANSI_B: showBufferList()
        case kVK_ANSI_F: toggleZoom()
        case kVK_ANSI_K: killBuffer()
        case kVK_ANSI_T: newTab()
        case kVK_ANSI_W: closeTab()
        case kVK_ANSI_RightBracket: switchTab(1)
        case kVK_ANSI_LeftBracket: switchTab(-1)
        case kVK_ANSI_Equal: tab.balance(); layout()
        case kVK_ANSI_Period: tab.resizeFocused(by: 0.05); layout()
        case kVK_ANSI_Comma: tab.resizeFocused(by: -0.05); layout()
        case kVK_ANSI_D: Hotkeys.shared.sendLiteralPrefix()
        case kVK_ANSI_R: refresh(); layout()
        case kVK_Escape, kVK_ANSI_G: break
        default: Hud.shared.flash("⌘D … is undefined")
        }
    }

    func split(vertical: Bool) {
        tab.zoomed = nil
        let fresh = Pane()
        if let id = otherBuffer() { fresh.show(id) }
        tab.split(tab.focused, vertical: vertical, with: fresh)
        layout()
    }

    func deletePane() {
        tab.zoomed = nil
        guard let next = tab.delete(tab.focused) else { return Hud.shared.flash("Can't delete the only pane") }
        tab.focused = next
        layout()
    }

    func deleteOtherPanes() {
        tab.zoomed = nil
        tab.root = tab.focused
        tab.focused.parent = nil
        layout()
    }

    func focusPane(_ dir: Int) {
        if tab.zoomed != nil {
            tab.zoomed = nil
            layout()
        }
        let panes = tab.panes
        guard panes.count > 1, let i = panes.firstIndex(where: { $0 === tab.focused }) else { return }
        tab.focused = panes[(i + dir + panes.count) % panes.count]
        focusSelected()
    }

    func walkHistory(_ dir: Int) {
        let pane = tab.focused
        guard pane.step(dir, where: { available($0, in: tab, for: pane) }) else {
            return Hud.shared.flash(dir < 0 ? "Beginning of history" : "End of history")
        }
        if let id = pane.current { touch(id) }
        layout()
    }

    func showBufferList() {
        bufferList.show(bufferOrder()) { window in
            if let window { self.display(window.id) }
            self.layout()
        }
    }

    func toggleZoom() {
        tab.zoomed = tab.zoomed == nil ? tab.focused : nil
        layout()
    }

    func killBuffer() {
        guard let id = tab.focused.current, let window = windows[id] else { return }
        window.close()
        scheduleRefresh(after: 0.3)
    }

    func newTab() {
        tabs.insert(Tab(), at: tabIndex + 1)
        tabIndex += 1
        layout()
    }

    func closeTab() {
        guard tabs.count > 1 else { return Hud.shared.flash("Can't close the only tab") }
        tabs.remove(at: tabIndex)
        tabIndex = min(tabIndex, tabs.count - 1)
        layout()
    }

    func switchTab(_ dir: Int) {
        guard tabs.count > 1 else { return Hud.shared.flash("Only one tab") }
        tabIndex = (tabIndex + dir + tabs.count) % tabs.count
        layout()
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabIndex = index
        layout()
    }
}
