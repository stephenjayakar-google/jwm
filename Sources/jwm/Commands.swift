import Carbon.HIToolbox

/// A key that can follow the ⌘D prefix. The table below drives both dispatch and ⌘D ? help.
struct Command {
    enum Section: String, CaseIterable {
        case panes = "Panes", buffers = "Buffers", tabs = "Tabs", other = "Other"
    }

    /// Key codes after the prefix (modifiers are ignored, so ⌘D ⌘3 works like ⌘D 3).
    let keys: [Int]
    let label: String
    let help: String
    let section: Section
    let run: (WM) -> Void
}

extension WM {
    static let commands: [Command] = [
        Command(keys: [kVK_ANSI_3], label: "3", help: "Split pane side by side", section: .panes) { $0.split(vertical: true) },
        Command(keys: [kVK_ANSI_2], label: "2", help: "Split pane top / bottom", section: .panes) { $0.split(vertical: false) },
        Command(keys: [kVK_ANSI_0], label: "0", help: "Delete this pane", section: .panes) { $0.deletePane() },
        Command(keys: [kVK_ANSI_1], label: "1", help: "Delete all other panes", section: .panes) { $0.deleteOtherPanes() },
        Command(keys: [kVK_ANSI_O], label: "o", help: "Select next pane", section: .panes) { $0.focusPane(1) },
        Command(keys: [kVK_ANSI_J], label: "j", help: "Back in this pane's history", section: .buffers) { $0.walkHistory(-1) },
        Command(keys: [kVK_ANSI_L], label: "l", help: "Forward in this pane's history", section: .buffers) { $0.walkHistory(1) },
        Command(keys: [kVK_ANSI_B], label: "b", help: "Buffer list", section: .buffers) { $0.showBufferList() },
        Command(keys: [kVK_ANSI_F], label: "f", help: "Toggle full screen for this pane", section: .panes) { $0.toggleZoom() },
        Command(keys: [kVK_ANSI_K], label: "k", help: "Close this pane's window", section: .buffers) { $0.killBuffer() },
        Command(keys: [kVK_ANSI_T], label: "t", help: "New empty tab", section: .tabs) { $0.newTab() },
        Command(keys: [kVK_ANSI_W], label: "w", help: "Close tab", section: .tabs) { $0.closeTab() },
        Command(keys: [kVK_ANSI_RightBracket], label: "]", help: "Next tab", section: .tabs) { $0.switchTab(1) },
        Command(keys: [kVK_ANSI_LeftBracket], label: "[", help: "Previous tab", section: .tabs) { $0.switchTab(-1) },
        Command(keys: [kVK_ANSI_Period], label: ".", help: "Grow this pane", section: .panes) { $0.tab.resizeFocused(by: 0.05); $0.layout() },
        Command(keys: [kVK_ANSI_Comma], label: ",", help: "Shrink this pane", section: .panes) { $0.tab.resizeFocused(by: -0.05); $0.layout() },
        Command(keys: [kVK_ANSI_Equal], label: "=", help: "Balance panes", section: .panes) { $0.tab.balance(); $0.layout() },
        Command(keys: [kVK_ANSI_R], label: "r", help: "Re-scan windows and re-apply layout", section: .other) { $0.refresh(); $0.layout() },
        Command(keys: [kVK_ANSI_D], label: "⌘D", help: "Send a real ⌘D to the app", section: .other) { _ in Hotkeys.shared.sendLiteralPrefix() },
        Command(keys: [kVK_ANSI_Slash], label: "?", help: "Show this help", section: .other) { $0.showHelp() },
        Command(keys: [kVK_Escape, kVK_ANSI_G], label: "Esc", help: "Cancel (also g)", section: .other) { _ in },
    ]

    /// Bindings outside the prefix, listed in help.
    static let globalBindings: [(label: String, help: String, section: Command.Section)] = [
        ("⌃Tab", "Select next pane", .panes),
        ("⌃⇧Tab", "Select previous pane", .panes),
    ]
}
