import CoreGraphics

class Node {
    weak var parent: Split?
    func collect(_ out: inout [Pane]) {}
}

/// A leaf of the split tree. Shows at most one window and remembers what it has shown.
final class Pane: Node {
    private(set) var history: [CGWindowID] = []
    private(set) var index = -1

    var current: CGWindowID? { history.indices.contains(index) ? history[index] : nil }

    override func collect(_ out: inout [Pane]) { out.append(self) }

    /// Shows `id` right after the current entry; forward history is kept, not truncated.
    func show(_ id: CGWindowID) {
        if current == id { return }
        if let pos = history.firstIndex(of: id) {
            history.remove(at: pos)
            if pos < index { index -= 1 }
        }
        index += 1
        history.insert(id, at: index)
    }

    /// Moves to the nearest entry in direction `dir` (-1 back, +1 forward) that satisfies `ok`.
    @discardableResult
    func step(_ dir: Int, where ok: (CGWindowID) -> Bool) -> Bool {
        var i = index + dir
        while history.indices.contains(i) {
            if ok(history[i]) { index = i; return true }
            i += dir
        }
        return false
    }

    /// Forgets `id`. Returns true if it was the current entry (index then points at the previous one).
    func remove(_ id: CGWindowID) -> Bool {
        guard let pos = history.firstIndex(of: id) else { return false }
        history.remove(at: pos)
        if pos < index { index -= 1; return false }
        if pos == index { index -= 1; return true }
        return false
    }

    func clear() { index = -1 }
}

final class Split: Node {
    /// true: children side by side (Emacs C-x 3). false: stacked (C-x 2).
    let vertical: Bool
    var a: Node
    var b: Node
    var ratio: CGFloat = 0.5

    init(vertical: Bool, a: Node, b: Node) {
        self.vertical = vertical
        self.a = a
        self.b = b
    }

    override func collect(_ out: inout [Pane]) {
        a.collect(&out)
        b.collect(&out)
    }
}

/// A window configuration: a split tree plus which pane is selected.
final class Tab {
    var root: Node
    var focused: Pane
    var zoomed: Pane?

    init() {
        let pane = Pane()
        root = pane
        focused = pane
    }

    var panes: [Pane] {
        var out: [Pane] = []
        root.collect(&out)
        return out
    }

    var visiblePanes: [Pane] { zoomed.map { [$0] } ?? panes }

    func replace(_ old: Node, with new: Node) {
        if let parent = old.parent {
            if parent.a === old { parent.a = new } else { parent.b = new }
            new.parent = parent
        } else {
            root = new
            new.parent = nil
        }
    }

    func split(_ pane: Pane, vertical: Bool, with fresh: Pane) {
        let split = Split(vertical: vertical, a: pane, b: fresh)
        replace(pane, with: split)
        pane.parent = split
        fresh.parent = split
    }

    /// Removes `pane` from the tree; returns the pane that should take focus.
    func delete(_ pane: Pane) -> Pane? {
        guard let parent = pane.parent else { return nil }
        let sibling = parent.a === pane ? parent.b : parent.a
        replace(parent, with: sibling)
        var leaves: [Pane] = []
        sibling.collect(&leaves)
        return leaves.first
    }

    /// Calls `visit` with every node and its rect within `bounds`, in tree order.
    private func walk(in bounds: CGRect, _ visit: (Node, CGRect) -> Void) {
        func walk(_ node: Node, _ r: CGRect) {
            visit(node, r)
            guard let split = node as? Split else { return }
            if split.vertical {
                let w = (r.width * split.ratio).rounded()
                walk(split.a, CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
                walk(split.b, CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
            } else {
                let h = (r.height * split.ratio).rounded()
                walk(split.a, CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                walk(split.b, CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
            }
        }
        walk(root, bounds)
    }

    /// Pane rects within `bounds`, in tree order.
    func rects(in bounds: CGRect) -> [(Pane, CGRect)] {
        if let zoomed { return [(zoomed, bounds)] }
        var out: [(Pane, CGRect)] = []
        walk(in: bounds) { node, r in
            if let pane = node as? Pane { out.append((pane, r)) }
        }
        return out
    }

    /// Something dragged edges of `pane`'s window from `expected` to `actual`: move the split boundaries
    /// to follow. `bounds` is what `rects(in:)` was given, `inset` how far windows sit inside their pane.
    func adjust(_ pane: Pane, from expected: CGRect, to actual: CGRect, bounds: CGRect, inset: CGFloat) -> Bool {
        guard zoomed == nil else { return false }
        var splitRects: [ObjectIdentifier: CGRect] = [:]
        walk(in: bounds) { node, r in
            if node is Split { splitRects[ObjectIdentifier(node)] = r }
        }
        // Nearest ancestor split along that axis with the pane on the given side, and its new ratio.
        func boundary(vertical: Bool, paneInA: Bool, at position: CGFloat) -> (Split, CGFloat)? {
            var child: Node = pane
            while let parent = child.parent {
                if parent.vertical == vertical, (parent.a === child) == paneInA,
                   let r = splitRects[ObjectIdentifier(parent)] {
                    let ratio = vertical ? (position - r.minX) / r.width : (position - r.minY) / r.height
                    return (parent, min(0.9, max(0.1, ratio)))
                }
                child = parent
            }
            return nil
        }
        // Edges within a gap's width of where they were count as unchanged, so tools that ignore our
        // gaps (Raycast) still read as a one-edge resize. If both edges on an axis moved, the window was
        // moved rather than resized along that axis, which the tree can't express.
        let tolerance: CGFloat = 12
        let left = abs(actual.minX - expected.minX) > tolerance, right = abs(actual.maxX - expected.maxX) > tolerance
        let top = abs(actual.minY - expected.minY) > tolerance, bottom = abs(actual.maxY - expected.maxY) > tolerance
        if left && right || top && bottom { return false }
        let wanted = [
            right ? (true, true, actual.maxX + inset) : nil,
            left ? (true, false, actual.minX - inset) : nil,
            bottom ? (false, true, actual.maxY + inset) : nil,
            top ? (false, false, actual.minY - inset) : nil,
        ].compactMap { $0 }
        // All or nothing: half-applying e.g. Raycast "top half" on a full-height pane would be surprising.
        let moves = wanted.compactMap { boundary(vertical: $0.0, paneInA: $0.1, at: $0.2) }
        guard !moves.isEmpty, moves.count == wanted.count else { return false }
        for (split, ratio) in moves { split.ratio = ratio }
        return true
    }

    /// Grows (positive) or shrinks the focused pane within its parent split.
    func resizeFocused(by delta: CGFloat) {
        guard let parent = focused.parent else { return }
        let sign: CGFloat = parent.a === focused ? 1 : -1
        parent.ratio = min(0.9, max(0.1, parent.ratio + sign * delta))
    }

    /// Like Emacs balance-windows: panes along each axis get equal space.
    func balance() {
        func weight(_ node: Node, vertical: Bool) -> CGFloat {
            guard let split = node as? Split else { return 1 }
            let a = weight(split.a, vertical: vertical), b = weight(split.b, vertical: vertical)
            return split.vertical == vertical ? a + b : max(a, b)
        }
        func walk(_ node: Node) {
            guard let split = node as? Split else { return }
            let a = weight(split.a, vertical: split.vertical), b = weight(split.b, vertical: split.vertical)
            split.ratio = a / (a + b)
            walk(split.a)
            walk(split.b)
        }
        walk(root)
    }
}
