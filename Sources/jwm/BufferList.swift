import AppKit

/// ⌘D b: filterable list of all windows. Enter shows the selection in the selected pane.
final class BufferList {
    private let picker = Picker(placeholder: "Switch to buffer…")

    func show(_ buffers: [(Window, visible: Bool)], completion: @escaping (Window?) -> Void) {
        let items = buffers.map { window, visible in
            PickerItem(icon: window.icon, title: window.shortTitle,
                       detail: window.appName + (visible ? " · on screen" : ""), dimmed: visible)
        }
        let haystacks = buffers.map { "\($0.0.appName) \($0.0.title)".lowercased() }
        picker.show(items, filter: { query in
            let terms = query.lowercased().split(separator: " ")
            return haystacks.indices.filter { i in terms.allSatisfy { haystacks[i].contains($0) } }
        }, completion: { index in
            completion(index.map { buffers[$0].0 })
        })
    }
}
