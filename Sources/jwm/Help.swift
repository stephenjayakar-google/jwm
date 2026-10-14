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

        // One grid per column so keys line up across sections; headers are merged rows.
        func column(_ sections: [Command.Section]) -> NSGridView {
            let grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.rowSpacing = 5
            grid.columnSpacing = 14
            for section in sections {
                let header = NSTextField(labelWithString: section.rawValue.uppercased())
                header.font = .systemFont(ofSize: 10.5, weight: .bold)
                header.textColor = .secondaryLabelColor
                let headerRow = grid.addRow(with: [header, NSGridCell.emptyContentView])
                grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                                verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1))
                headerRow.cell(at: 0).xPlacement = .leading
                if grid.numberOfRows > 1 { headerRow.topPadding = 14 }
                headerRow.bottomPadding = 2

                let rows = WM.commands.filter { $0.section == section }.map { ("⌘D \($0.label)", $0.help) }
                    + WM.globalBindings.filter { $0.section == section }.map { ($0.label, $0.help) }
                for (keys, help) in rows {
                    let key = NSTextField(labelWithString: keys)
                    key.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                    let text = NSTextField(labelWithString: help)
                    text.font = .systemFont(ofSize: 13)
                    grid.addRow(with: [key, text]).cell(at: 0).xPlacement = .trailing
                }
            }
            grid.setContentHuggingPriority(.required, for: .vertical)
            return grid
        }
        let columns = NSStackView(views: [column([.panes]), column([.buffers, .tabs, .other])])
        columns.alignment = .top
        columns.spacing = 40

        let title = NSTextField(labelWithString: "jwm")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        let hint = NSTextField(labelWithString: "Press any key to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, columns, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
        ])
        panel.contentView = container
        panel.setContentSize(container.fittingSize)
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
