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

/// Menu bar item showing the tabs, e.g. "1 [2] 3".
final class StatusBar: NSObject {
    static let shared = StatusBar()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        let menu = NSMenu()
        menu.addItem(withTitle: "Re-layout", action: #selector(relayout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit jwm", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = menu
    }

    func update() {
        let wm = WM.shared
        item.button?.title = wm.tabs.indices
            .map { $0 == wm.tabIndex ? "[\($0 + 1)]" : "\($0 + 1)" }
            .joined(separator: " ")
    }

    @objc private func relayout() {
        WM.shared.refresh()
        WM.shared.layout()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
