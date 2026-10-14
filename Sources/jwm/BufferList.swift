import AppKit

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// ⌘D b: fuzzy-filterable list of all windows. Enter shows the selection in the selected pane.
final class BufferList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 420),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [(Window, visible: Bool)] = []
    private var shown: [(Window, visible: Bool)] = []
    private var completion: ((Window?) -> Void)?

    override init() {
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.delegate = self

        field.placeholderString = "Switch to buffer…"
        field.font = .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.isBezeled = false
        field.drawsBackground = false
        field.delegate = self

        let column = NSTableColumn(identifier: .init("buffer"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSView()
        for view in [field, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        panel.contentView = content
    }

    func show(_ buffers: [(Window, visible: Bool)], completion: @escaping (Window?) -> Void) {
        all = buffers
        self.completion = completion
        field.stringValue = ""
        filter()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func filter() {
        let terms = field.stringValue.lowercased().split(separator: " ")
        shown = all.filter { window, _ in
            let label = window.label.lowercased()
            return terms.allSatisfy { label.contains($0) }
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func finish(_ window: Window?) {
        guard let completion else { return }
        self.completion = nil
        panel.orderOut(nil)
        completion(window)
    }

    @objc private func pickSelected() {
        let row = table.selectedRow
        finish(shown.indices.contains(row) ? shown[row].0 : nil)
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): pickSelected()
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { finish(nil) }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (window, visible) = shown[row]
        let label = NSTextField(labelWithString: (visible ? "● " : "   ") + window.label)
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
