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
    private(set) var mru: [CGWindowID] = []
    /// Largest minimum window size seen per app; new windows of the app start with it.
    private(set) var minimums: [String: CGSize] = [:]
    private var started = false
    /// jwm manages the Space it started on and leaves other Spaces alone (AX only reports windows
    /// on the current Space, so managing several would scramble the layout).
    private var homeSpace: UInt64 = 0
    var onHomeSpace: Bool { activeSpace() == homeSpace }
    private var refreshScheduled = false
    private var saveScheduled = false
    /// Panes that windows were showing in when they went away (minimized, native full screen), so
    /// they return there instead of to the selected pane.
    private var vacated: [CGWindowID: Pane] = [:]
    /// Guards against apps whose size never settles making layout() recurse forever.
    private var layoutDepth = 0
    /// Windows that reported a move/resize, checked once things settle.
    private var movedWindows = Set<CGWindowID>()
    private var frameCheckScheduled = false
    /// Focus events caused by our own focusing are ignored until this time.
    private var ignoreFocusUntil = Date.distantPast

    lazy var border = Border()
    lazy var bufferList = BufferList()
    lazy var help = Help()

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
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            self.spaceChanged()
        }
        homeSpace = activeSpace()
        minimums = loadMinimums()

        refresh()
        // Seed recency from the on-screen stacking order (front to back).
        let stack = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        mru = stack.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.filter { windows[$0] != nil }
        if let saved = loadState() {
            tabs = saved.tabs
            tabIndex = saved.tabIndex
            mru = saved.mru.filter { windows[$0] != nil } + mru.filter { !saved.mru.contains($0) }
            // Drop windows closed since the last run; panes fall back through their histories.
            for tab in tabs {
                for pane in tab.panes {
                    for id in pane.history where windows[id] == nil {
                        if pane.remove(id) { fallback(pane, in: tab) }
                    }
                    fallback(pane, in: tab)
                }
            }
            log("restored \(tabs.count) tab(s) from the last run")
        } else {
            tabs = [freshTab()]
        }
        started = true
        layout()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
    }

    private func spaceChanged() {
        if onHomeSpace {
            refresh()
            layout()
        } else {
            border.hide()
            Hud.shared.flash("jwm is paused on this desktop")
        }
        StatusBar.shared.update()
    }

    /// One pane showing the focused window.
    private func freshTab() -> Tab {
        let tab = Tab()
        if let id = frontmostWindow()?.id ?? mru.first {
            tab.focused.show(id)
            touch(id)
        }
        return tab
    }

    /// Forgets all tabs and splits: one tab, one pane, showing the focused window.
    func resetLayout() {
        tabs = [freshTab()]
        tabIndex = 0
        layout()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.saveScheduled = false
            self.saveState()
        }
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
        if started && !onHomeSpace { return }
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
                    window.minSize = minimums[watcher.name] ?? .zero
                    windows[id] = window
                    watcher.watch(element)
                    added.append(id)
                }
            }
        }
        let removed = windows.keys.filter { !seen.contains($0) }
        for id in removed { forget(id) }

        guard started, !(added.isEmpty && removed.isEmpty) else { return }
        for id in added {
            // A window coming back (un-minimized, left full screen) returns to its pane.
            if let pane = vacated.removeValue(forKey: id), tab.panes.contains(where: { $0 === pane }) {
                if tab.zoomed != nil, tab.zoomed !== pane { tab.zoomed = nil }
                tab.focused = pane
            }
            // New windows open in the selected pane, like Emacs displaying a new buffer.
            display(id)
        }
        layout()
    }

    private func forget(_ id: CGWindowID) {
        if started, let pane = tab.panes.first(where: { $0.current == id }) {
            if vacated.count > 100 { vacated.removeAll() }
            vacated[id] = pane
        }
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
        guard started, onHomeSpace, Date() > ignoreFocusUntil, let id = element.windowID else { return }
        guard windows[id] != nil else { scheduleRefresh(); return }
        // A visible window just closed or minimized and macOS is focusing some other window in
        // response. That's not the user's choice: ignore it and let refresh() fall back through
        // the pane's history (like Emacs kill-buffer), then refocus the selected pane.
        let vanishing = tab.visiblePanes.contains { pane in
            guard let current = pane.current, current != id, let window = windows[current] else { return false }
            return window.element.string(kAXRoleAttribute) == nil || window.element.bool(kAXMinimizedAttribute) == true
        }
        if vanishing {
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
        guard started, onHomeSpace, let id = element.windowID, let window = windows[id],
              Date() > window.ownChangeUntil else { return }
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
        guard let actual = window.element.frame else { return false }
        let close = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }

        if let expected = window.expected {
            if close(actual, expected) { return false }
            // A changed edge (mouse drag, Raycast "left 2/3", …) resizes the pane.
            if let pane = tab.visiblePanes.first(where: { $0.current == window.id }) {
                let half = gap / 2
                if tab.adjust(pane, from: expected, to: actual, bounds: layoutBounds, inset: half,
                              minimum: paneMinimum) {
                    log("\(window.label) resized externally → adjusted splits")
                    return true
                }
            }
            // Moved, or a shape the split tree can't express: put it back.
            correct(window) { $0.setFrame(expected) }
        } else if window.parked {
            // Something pulled a parked buffer back on screen.
            let visible = actual.intersection(screenBounds())
            guard visible.width > 20, visible.height > 20 else { return false }
            correct(window) { $0.park(in: flipped(NSScreen.screens.first?.frame ?? .zero)) }
        }
        return false
    }

    /// Applies a correction at most once a second per window, rechecking later instead of dropping
    /// it, and gives up after a few back-to-back attempts so we don't fight an app forever.
    private func correct(_ window: Window, _ fix: (Window) -> Void) {
        let since = Date().timeIntervalSince(window.lastCorrection)
        if since > 5 { window.corrections = 0 }
        guard window.corrections < 3 else { return log("giving up on \(window.label)") }
        guard since >= 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 - since) {
                self.movedWindows.insert(window.id)
                self.scheduleFrameCheck()
            }
            return
        }
        window.corrections += 1
        window.lastCorrection = Date()
        log("correcting \(window.label)")
        fix(window)
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
    private func otherBuffer(where fits: @escaping (CGWindowID) -> Bool = { _ in true }) -> CGWindowID? {
        let ok = { (id: CGWindowID) in self.available(id, in: self.tab, for: nil) && fits(id) }
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

    /// Area panes are laid out in: the screen minus half a gap (each window insets the other half).
    private var layoutBounds: CGRect { screenBounds().insetBy(dx: gap / 2, dy: gap / 2) }

    /// Smallest pane that fits its window's learned minimum size.
    private func paneMinimum(_ pane: Pane) -> CGSize {
        guard let id = pane.current, let size = windows[id]?.minSize, size != .zero else { return .zero }
        return CGSize(width: size.width + gap, height: size.height + gap)
    }

    /// Window frames for the current tab's panes.
    private func paneRects() -> [(Pane, CGRect)] {
        let half = gap / 2
        return tab.rects(in: layoutBounds, minimum: paneMinimum).map { ($0, $1.insetBy(dx: half, dy: half)) }
    }

    /// Moves every window to where the current tab says it belongs and focuses the selected pane.
    func layout() {
        guard started, onHomeSpace else { return }
        var frames: [CGWindowID: CGRect] = [:]
        for (pane, rect) in paneRects() {
            if let id = pane.current { frames[id] = rect }
        }
        let screen = flipped(NSScreen.screens.first?.frame ?? .zero)
        var learned = false
        for window in windows.values {
            if let rect = frames[window.id] {
                learned = place(window, in: rect) || learned
            } else if !window.parked {
                window.park(in: screen)
            }
        }
        // A window refused its size: lay out again with its minimum taken into account.
        if learned && layoutDepth < 3 {
            layoutDepth += 1
            defer { layoutDepth -= 1 }
            return layout()
        }
        focusSelected()
        scheduleSave()
    }

    /// Puts `window` in `rect`, never smaller than its minimum size and never hanging off screen
    /// (if the panes can't all fit, windows overlap their neighbours instead). Returns true if
    /// the window turned out to have a larger minimum size than we knew.
    private func place(_ window: Window, in rect: CGRect) -> Bool {
        let bounds = screenBounds().insetBy(dx: gap, dy: gap)
        var frame = rect
        frame.size.width = min(max(frame.width, window.minSize.width), bounds.width)
        frame.size.height = min(max(frame.height, window.minSize.height), bounds.height)
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        window.setFrame(frame)

        guard let actual = window.element.frame else { return false }
        log("place \(window.label) \(frame) → \(actual)")
        var minimum = window.minSize
        if actual.width > frame.width + 1 { minimum.width = actual.width }
        if actual.height > frame.height + 1 { minimum.height = actual.height }
        guard minimum != window.minSize else { return false }
        window.minSize = minimum
        let known = minimums[window.appName] ?? .zero
        minimums[window.appName] = CGSize(width: max(known.width, minimum.width),
                                          height: max(known.height, minimum.height))
        log("\(window.label) minimum size \(minimum)")
        return true
    }

    func focusSelected() {
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
        let frame = pane.current.flatMap { windows[$0]?.expected } ?? rect
        border.show(around: flipped(frame), empty: pane.current == nil)
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
        guard onHomeSpace || key == kVK_ANSI_D else { return Hud.shared.flash("jwm is paused on this desktop") }
        guard let command = WM.commands.first(where: { $0.keys.contains(key) }) else {
            return Hud.shared.flash("⌘D … is undefined · ⌘D ? for help")
        }
        command.run(self)
    }

    func showHelp() {
        help.show { self.focusSelected() }
    }

    func split(vertical: Bool) {
        tab.zoomed = nil
        // Like Emacs, refuse to split a pane whose window wouldn't fit in half of it.
        var half = CGFloat.infinity
        if let rect = paneRects().first(where: { $0.0 === tab.focused })?.1 {
            half = ((vertical ? rect.width : rect.height) - gap) / 2
        }
        let length = { (id: CGWindowID) -> CGFloat in
            guard let size = self.windows[id]?.minSize else { return 0 }
            return vertical ? size.width : size.height
        }
        if let id = tab.focused.current, length(id) > half {
            return Hud.shared.flash("Not enough room to split this pane")
        }
        let fresh = Pane()
        if let id = otherBuffer(where: { length($0) <= half }) { fresh.show(id) }
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
        guard onHomeSpace else { return }
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
        announceTab()
    }

    func closeTab() {
        guard tabs.count > 1 else { return Hud.shared.flash("Can't close the only tab") }
        tabs.remove(at: tabIndex)
        tabIndex = min(tabIndex, tabs.count - 1)
        layout()
        announceTab()
    }

    func switchTab(_ dir: Int) {
        guard tabs.count > 1 else { return Hud.shared.flash("Only one tab") }
        tabIndex = (tabIndex + dir + tabs.count) % tabs.count
        layout()
        announceTab()
    }

    private func announceTab() {
        Hud.shared.flash("Tab \(tabIndex + 1) of \(tabs.count)")
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabIndex = index
        layout()
        announceTab()
    }
}
