# jwm — Jayakar Window Manager

An Emacs-style tiling window manager for macOS.

- **Buffers** are app windows. Windows that aren't displayed are parked offscreen (a 1px sliver stays at the bottom-right corner).
- **Panes** form an Emacs-style split tree. Each pane remembers the buffers it has shown and you can walk back/forward through them.
- **Tabs** are separate window configurations (split trees). The same buffer can appear in several tabs.
- New windows open in the selected pane, replacing what was there (it stays in that pane's history).
- Focusing a window that isn't displayed (Cmd-Tab, Dock click) shows it in the selected pane.
- Un-minimizing a window (or leaving native full screen) puts it back in the pane it came from.
- Apps' minimum window sizes are learned and respected: panes don't shrink below them, and a split that
  wouldn't fit is refused (like Emacs' "window too small for splitting").
- Tabs, splits and pane histories are saved to `~/Library/Application Support/jwm/state.json` and restored
  when jwm restarts (menu bar → Reset Layout to start over).
- jwm manages the desktop (Space) it was started on and pauses on others.
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
| `⌥Tab` / `⌥⇧Tab`, `⌘D o` | select next / previous pane (⌃Tab is left to browsers/editors) |
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
| *(M-x only)* | `reset-layout`, `quit-jwm` |
| `⌘D x` / `⌘D ?` | M-x: run any command by name (prefix search, Tab completes, `s-w-r` style partial completion) |
| `⌘D ⌘D` | send a real ⌘D to the app |
| `⌘D Esc` / `⌘D g` | cancel |

## Install (Apple Silicon)

Download `jwm-<version>-arm64.app.zip` from [Releases](../../releases), unzip, move `jwm.app` to
`/Applications`, then:

```sh
xattr -dr com.apple.quarantine /Applications/jwm.app   # it's ad-hoc signed, not notarized
open /Applications/jwm.app
```

Grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility), then open it
again. `jwm-<version>-arm64.tar.gz` is the bare binary, if you'd rather run it from a terminal.

## Running from source

```sh
make run       # build and run in the foreground; Ctrl-C quits and restores windows
make restore   # if jwm crashed, bring offscreen windows back
make app       # build jwm.app
```

jwm needs Accessibility permission. Run from a terminal, it uses the terminal's permission.

## Menu bar

The ▥ icon shows the tabs (`1 [2] 3`) and has Commands, Re-layout, Reset Layout and Quit. On a notched
MacBook it may be hidden behind the notch; ⌘-drag it somewhere visible and it stays there. Tab changes
are also announced at the bottom of the screen.

## Debugging

`JWM_DEBUG=1 make run` logs commands and placements. `pkill -USR1 jwm` prints the split tree and pane
histories; `pkill -USR2 jwm` renders jwm's own windows to `/tmp/jwm-snapshot-*.png`.

## Limitations (for now)

- Primary display only, and one Space (it pauses on other Spaces).
- Floating windows (dialogs, non-resizable windows) aren't managed.
- State isn't saved across restarts.
