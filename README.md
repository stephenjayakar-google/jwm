# jwm — Jayakar Window Manager

An Emacs-style tiling window manager for macOS.

- **Buffers** are app windows. Windows that aren't displayed are parked offscreen (a 1px sliver stays at the bottom-right corner).
- **Panes** form an Emacs-style split tree. Each pane remembers the buffers it has shown and you can walk back/forward through them.
- **Tabs** are separate window configurations (split trees). The same buffer can appear in several tabs.
- New windows open in the selected pane, replacing what was there (it stays in that pane's history).
- Focusing a window that isn't displayed (Cmd-Tab, Dock click) shows it in the selected pane.
- If something else changes a tiled window's frame (mouse drag, Raycast/Rectangle, the app itself):
  - one edge moved per axis, and the split tree can express it → the split follows, and so do the other panes;
  - anything else (moved, or e.g. "top half" with no top/bottom split) → the window snaps back.

## Keys

`⌘D` is a prefix, like Emacs `C-x`. Holding ⌘ for the second key works too (`⌘D ⌘3`).

| Keys | Action |
|---|---|
| `⌘D 3` | split selected pane side by side |
| `⌘D 2` | split selected pane top/bottom |
| `⌘D 0` | delete selected pane |
| `⌘D 1` | delete all other panes |
| `Ctrl-Tab` / `Ctrl-Shift-Tab`, `⌘D o` | select next / previous pane |
| `⌘D j` / `⌘D l` | back / forward in the pane's buffer history |
| `⌘D b` | buffer list (type to filter, ↑↓, Enter, Esc) |
| `⌘D f` | toggle full screen for the selected pane |
| `⌘D k` | close the selected buffer's window |
| `⌘D t` | new (empty) tab |
| `⌘D w` | close tab |
| `⌘D ]` / `⌘D [` | next / previous tab |
| `⌘D .` / `⌘D ,` | grow / shrink selected pane |
| `⌘D =` | balance panes |
| `⌘D r` | re-scan windows and re-apply layout |
| `⌘D ?` | show all commands |
| `⌘D ⌘D` | send a real ⌘D to the app |
| `⌘D Esc` / `⌘D g` | cancel |

## Running

```sh
make run       # build and run in the foreground; Ctrl-C quits and restores windows
make restore   # if jwm crashed, bring offscreen windows back
make app       # build jwm.app
```

jwm needs Accessibility permission. Run from a terminal, it uses the terminal's permission.

## Limitations (for now)

- Primary display only; turn off extra macOS Spaces (jwm tabs replace them).
- Floating windows (dialogs, non-resizable windows) aren't managed.
- State isn't saved across restarts.
