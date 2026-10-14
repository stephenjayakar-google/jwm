import AppKit

/// Closes on any key press.
private final class HelpPanel: NSPanel {
    var onKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?() }
    override func cancelOperation(_ sender: Any?) { onKey?() }
}

/// ⌘D ?: every command, generated from `WM.commands`.
final class Help: NSObject, NSWindowDelegate {
    private let panel = HelpPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
    private var completion: (() -> Void)?

    override init() {
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onKey = { [weak self] in self?.finish() }

        let rows = WM.commands.map { ("⌘D \($0.label)", $0.help) } + WM.globalBindings.map { ($0.label, $0.help) }
        let grid = NSGridView(views: rows.map { keys, help in
            let key = NSTextField(labelWithString: keys)
            key.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            let text = NSTextField(labelWithString: help)
            text.font = .systemFont(ofSize: 13)
            return [key, text]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 20
        grid.column(at: 0).xPlacement = .trailing

        let title = NSTextField(labelWithString: "jwm commands")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        let hint = NSTextField(labelWithString: "Press any key to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 28, bottom: 18, right: 28)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    func show(completion: @escaping () -> Void) {
        self.completion = completion
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        panel.orderOut(nil)
        completion()
    }

    func windowDidResignKey(_ notification: Notification) { finish() }
}
