import AppKit

/// ⌘D x / ⌘D ?: M-x. Search commands by name, Tab completes, Enter runs. Doubles as the key
/// reference, since every row shows its binding.
final class CommandPalette {
    private let picker = Picker(placeholder: "M-x", monospaced: true)
    private let commands = WM.commands.filter { !$0.unlisted }

    init() {
        let commands = self.commands
        picker.complete = { CommandPalette.complete($0, in: commands) }
    }

    func show(run: @escaping (Command?) -> Void) {
        let commands = self.commands
        let items = commands.map {
            PickerItem(title: $0.name, titleFont: .monospacedSystemFont(ofSize: 13.5, weight: .medium),
                       subtitle: $0.help, detail: $0.binding,
                       detailFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        }
        picker.show(items, filter: { CommandPalette.matches($0, in: commands) },
                    completion: { run($0.map { commands[$0] }) })
    }

    /// Emacs-style matching, best first: name prefix ("split-w"); partial completion, where each
    /// dash- or space-separated piece prefixes a later word ("s-w-r" → split-window-right); any
    /// word prefix ("buf" → switch-to-buffer); then the description.
    static func matches(_ query: String, in commands: [Command]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(commands.indices) }
        let pieces = query.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
        func partial(_ name: String) -> Bool {
            let words = name.split(separator: "-")
            var w = 0
            for piece in pieces {
                while w < words.count, !words[w].hasPrefix(piece) { w += 1 }
                if w == words.count { return false }
                w += 1
            }
            return true
        }
        var tiers: [[Int]] = [[], [], [], []]
        for (i, command) in commands.enumerated() {
            if command.name.hasPrefix(query) {
                tiers[0].append(i)
            } else if pieces.count > 1, partial(command.name) {
                tiers[1].append(i)
            } else if command.name.split(separator: "-").contains(where: { $0.hasPrefix(query) }) {
                tiers[2].append(i)
            } else if command.help.lowercased().contains(query) {
                tiers[3].append(i)
            }
        }
        return tiers.flatMap { $0 }
    }

    /// Tab: extend the query to the longest common prefix of the names it prefixes, or to the
    /// full name if only one command matches at all.
    static func complete(_ query: String, in commands: [Command]) -> String? {
        let query = query.lowercased()
        let prefixed = commands.map(\.name).filter { $0.hasPrefix(query) }
        if let first = prefixed.first {
            return prefixed.dropFirst().reduce(first) { common, name in
                String(zip(common, name).prefix { $0 == $1 }.map(\.0))
            }
        }
        let all = matches(query, in: commands)
        return all.count == 1 ? commands[all[0]].name : nil
    }
}
