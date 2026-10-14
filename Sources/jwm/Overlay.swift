import AppKit

private func overlayWindow(level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = level
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    return panel
}

/// Outline drawn in the gap around the selected pane.
final class Border {
    private let panel = overlayWindow(level: .floating)
    private let view = BorderView()

    init() { panel.contentView = view }

    /// `rect` is the pane's window frame in AppKit coordinates.
    func show(around rect: CGRect, empty: Bool) {
        view.empty = empty
        view.needsDisplay = true
        panel.setFrame(rect.insetBy(dx: -4, dy: -4), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private final class BorderView: NSView {
    var empty = false

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 13, yRadius: 13)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        guard empty else { return }
        let text = "empty pane · ⌘D b for buffers" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

/// Small message bubble at the bottom of the screen (prefix indicator, errors).
final class Hud {
    static let shared = Hud()

    private let panel = overlayWindow(level: .statusBar)
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
    }

    func show(_ text: String) {
        generation += 1
        label.stringValue = text
        let size = CGSize(width: label.intrinsicContentSize.width + 32, height: 36)
        let screen = NSScreen.screens.first?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.minY + 48,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func flash(_ text: String) {
        show(text)
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.generation == current { self.hide() }
        }
    }

    func hide() { panel.orderOut(nil) }
}

/// Menu bar item: an icon, plus the tabs ("1 [2] 3") once there's more than one.
final class StatusBar: NSObject, NSMenuDelegate {
    static let shared = StatusBar()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        // Remembers where the user ⌘-drags it (e.g. out from behind the notch).
        item.autosaveName = "jwm"
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "jwm")
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
    }

    func update() {
        let wm = WM.shared
        item.button?.title = wm.tabs.count < 2 ? "" : " " + wm.tabs.indices
            .map { $0 == wm.tabIndex ? "[\($0 + 1)]" : "\($0 + 1)" }
            .joined(separator: " ")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let wm = WM.shared
        menu.removeAllItems()
        for i in wm.tabs.indices {
            let item = menu.addItem(withTitle: "Tab \(i + 1)", action: #selector(selectTab(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == wm.tabIndex ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Commands…  (⌘D ?)", action: #selector(help), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Re-layout  (⌘D r)", action: #selector(relayout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Layout", action: #selector(reset), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit jwm", action: #selector(quit), keyEquivalent: "").target = self
    }

    @objc private func selectTab(_ sender: NSMenuItem) { WM.shared.selectTab(sender.tag) }
    @objc private func help() { WM.shared.showHelp() }
    @objc private func reset() { WM.shared.resetLayout() }

    @objc private func relayout() {
        WM.shared.refresh()
        WM.shared.layout()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Debug aid (SIGUSR2): renders jwm's visible windows to /tmp/jwm-snapshot-N.png, since capturing
/// other apps' windows needs Screen Recording permission but our own don't.
func snapshotOwnWindows() {
    for (i, window) in NSApp.windows.filter(\.isVisible).enumerated() {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: "/tmp/jwm-snapshot-\(i).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot \(url.path) \(window.frame)")
    }
    fflush(stdout)
}
