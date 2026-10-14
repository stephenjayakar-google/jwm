import AppKit

/// Tabs, split trees and pane histories, saved so restarting jwm brings the layout back.
/// Window IDs stay valid as long as the windows exist, i.e. across jwm restarts but not reboots.
struct SavedState: Codable {
    indirect enum Node: Codable {
        case pane(history: [CGWindowID], index: Int)
        case split(vertical: Bool, ratio: CGFloat, a: Node, b: Node)
    }

    struct Tab: Codable {
        var root: Node
        var focused: Int
        var zoomed: Bool
    }

    var tabs: [Tab]
    var tabIndex: Int
    var mru: [CGWindowID]
    /// Learned minimum window sizes per app name.
    var minimums: [String: CGSize]?
}

extension WM {
    static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/jwm/state.json")

    func saveState() {
        let state = SavedState(
            tabs: tabs.map { tab in
                SavedState.Tab(root: node(tab.root),
                               focused: tab.panes.firstIndex { $0 === tab.focused } ?? 0,
                               zoomed: tab.zoomed != nil)
            },
            tabIndex: tabIndex,
            mru: mru,
            minimums: minimums
        )
        do {
            try FileManager.default.createDirectory(at: WM.stateURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: WM.stateURL, options: .atomic)
        } catch {
            log("couldn't save state: \(error)")
        }
    }

    private func node(_ node: Node) -> SavedState.Node {
        if let pane = node as? Pane { return .pane(history: pane.history, index: pane.index) }
        let split = node as! Split
        return .split(vertical: split.vertical, ratio: split.ratio, a: self.node(split.a), b: self.node(split.b))
    }

    private func readState() -> SavedState? {
        guard let data = try? Data(contentsOf: WM.stateURL) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    /// Minimum window sizes learned in earlier runs.
    func loadMinimums() -> [String: CGSize] { readState()?.minimums ?? [:] }

    /// Tabs from the last run, with closed windows dropped. nil if nothing from it is still open.
    func loadState() -> (tabs: [Tab], tabIndex: Int, mru: [CGWindowID])? {
        guard let state = readState(), !state.tabs.isEmpty else { return nil }

        func build(_ saved: SavedState.Node) -> Node {
            switch saved {
            case let .pane(history, index):
                return Pane(history: history, index: index)
            case let .split(vertical, ratio, a, b):
                let split = Split(vertical: vertical, a: build(a), b: build(b))
                split.ratio = ratio
                split.a.parent = split
                split.b.parent = split
                return split
            }
        }
        let tabs = state.tabs.map { saved -> Tab in
            let tab = Tab()
            tab.root = build(saved.root)
            let panes = tab.panes
            tab.focused = panes.indices.contains(saved.focused) ? panes[saved.focused] : panes[0]
            tab.zoomed = saved.zoomed ? tab.focused : nil
            return tab
        }
        guard tabs.contains(where: { $0.panes.contains { $0.history.contains { windows[$0] != nil } } })
        else { return nil }
        return (tabs, min(max(state.tabIndex, 0), tabs.count - 1), state.mru)
    }
}
