# maai

[![CI](https://github.com/avoiney/maai/actions/workflows/ci.yml/badge.svg)](https://github.com/avoiney/maai/actions/workflows/ci.yml)

A Wayland terminal emulator written in Zig.

PTY + VT parser + GPU-rendered text, driven by a single `poll(2)` loop. No threads,
no framework. Config is a flat `key value` file; themes are compatible with the corpus
that already exists for other terminals.

## Dependencies

```
libwayland-client  libwayland-egl  libxkbcommon
libEGL  libGLESv2  fcft  pixman-1  utf8proc
```

On Debian/Ubuntu:

```sh
apt install libwayland-bin wayland-protocols libwayland-dev \
            libegl1-mesa-dev libgles2-mesa-dev           \
            libfcft-dev libpixman-1-dev                  \
            libxkbcommon-dev libutf8proc-dev
```

Requires Zig 0.16.0. The repo ships a `mise.toml` that pins it:

```sh
mise install
```

## Build

```sh
zig build -Doptimize=ReleaseFast   # → zig-out/bin/maai
```

Or use the install script, which builds and copies the binary to `~/.local/bin`:

```sh
./install.sh
./install.sh --prefix /usr/local   # install elsewhere
./install.sh --help                # all options
```

## Usage

```sh
maai                    # run $SHELL
maai -e cmd args        # run a specific command
maai -c path/to.conf    # use a specific config file
maai --cwd /some/dir    # start in that directory
maai --app-id NAME      # set the Wayland app_id (default: maai)
maai --no-tabs          # one tab, no bar, tab keys left to the child
MAAI_DEBUG=1 maai       # trace input, selection, and mouse handling
```

## Configuration

Default path: `$XDG_CONFIG_HOME/maai/maai.conf` (falls back to `~/.config/maai/maai.conf`).

Syntax: one `key value` or `key: value` per line; `#` comments; `include file` for
composition. Unknown keys and bad values are reported on stderr and skipped — a typo
never prevents the terminal from opening.

The config file, the active theme file, and the flavour file are all watched via
inotify. Saving any of them applies immediately. Two exceptions: `scrollback_lines`
takes effect at the next start, and a font that fails to load leaves the previous one
in place.

An annotated example with every setting and its default lives in
[`maai.conf.example`](maai.conf.example).

### Font

```
font_family  FiraCode Nerd Font Ret
font_size    12
```

The family must be monospace. A name fontconfig cannot find is substituted silently, so
maai measures the advances and refuses a proportional font rather than letting it
produce overlapping text.

### Layout

```
padding_x        4       # left padding in pixels
padding_y        0       # top padding in pixels
scrollback_lines 10000
```

### Behaviour

```
copy_on_select  yes      # also feed CLIPBOARD on mouse selection (not just PRIMARY)
alternate_scroll yes     # wheel → cursor keys on the alt screen (xterm mode 1007)
url_launcher    xdg-open # one program, no arguments
```

### Tab bar

```
tab_bar_style       powerline   # or: plain, hidden
tab_powerline_style slanted     # or: angled, round
```

`powerline` draws a shaped separator between tabs using glyphs from the Nerd Font
private-use range. Use `plain` if the font does not have them.

`hidden` draws no bar at all and hands its row back to the grid. Tabs still work and
stay addressable over the control socket — they are only invisible.

For a window used as a scratchpad, prefer `--no-tabs` on the command line:

```sh
maai --no-tabs --app-id scratchpad
```

It hides the bar *and* hands `Ctrl+Shift+T`, `Ctrl+Tab`, `Ctrl+Shift+Tab`,
`Ctrl+Shift+Page Up/Down` and `Alt+1…0` back to whatever is running in the window, so
no tab can open unseen. Being a flag rather than a config key is the point: one config
file serves both the scratchpad and the windows that do want tabs. It wins over the
config file, and keeps winning across a live reload.

### Key bindings

```
key <combination> <action>
```

Modifiers are `ctrl`, `shift`, `alt`, joined with `+`. The key name is an xkb keysym
name — `c`, `percent`, `Page_Up`, `F5`, `Tab` — the same vocabulary used in
`/usr/share/X11/xkb/symbols`. Write the combination as it reads; shifted spellings are
normalised for you (`shift+c` matches, no need to write `C`; `shift+tab` matches, no
need to know xkb calls it `ISO_Left_Tab`). For punctuation, Shift is how the character
is typed and is not part of the combination.

The action `none` unbinds a combination and hands it back to applications. The key name
`numrow` matches any key of the number row by position, layout-independently.

Default bindings:

| Combination | Action |
|---|---|
| `Ctrl+Shift+C` | Copy selection to clipboard |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Ctrl+Shift+U` | Enter hint mode |
| `Alt+%` | New window in current directory |
| `Shift+Page Up/Down` | Scroll half a page |
| `Shift+Home / End` | Scroll to top / bottom |
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Tab` | Next tab |
| `Ctrl+Shift+Tab` | Previous tab |
| `Ctrl+Shift+Page Up/Down` | Move the current tab left / right along the strip |
| `Alt+1…0` | Jump to tab by number-row position |

Moving a tab carries the focus with it, and stops at the ends rather than wrapping: a
tab already last stays last. `Ctrl+Shift+Page Up/Down` is the one default that takes a
sequence applications can otherwise see (`CSI 5;6~` and `CSI 6;6~`); little binds it,
but if something you run does, hand it back with:

```
key ctrl+shift+Page_Up none
key ctrl+shift+Page_Down none
key alt+Page_Up tab_move_left       # and put the action somewhere else
key alt+Page_Down tab_move_right
```

### Themes

```
theme nightfox              # name looked up in theme_dir (.conf / .yaml / .yml)
theme ~/themes/solarized    # or a path
theme_dir ~/.config/maai/themes
```

Leave `theme` unset to follow `theme_flavour_file` instead — a file containing a bare
theme name that an external switcher rewrites. maai watches it, so a dayfox/nightfox
flip re-themes every open window instantly.

Theme files use the established `key #rrggbb` format:

```
background            #192330
foreground            #cdcecf
cursor                #cdcecf
cursor_text_color     #192330
selection_background  #2b3b51
selection_foreground  #cdcecf
hint_background       #dbc074   # hint-mode labels
hint_foreground       #192330
tab_bar_background      #192330
inactive_tab_background #2b3b51
inactive_tab_foreground #738091
active_tab_background   #719cd6
active_tab_foreground   #131a24
color0 … color255     #rrggbb
```

Colour values accept `#rgb`, `#rrggbb`, `#rrrgggbbb`, `#rrrrggggbbbb`, and `rgb:r/g/b`.
Keys that maai has no chrome for yet are silently ignored, so unmodified theme files
from other terminals load without complaints.

## Hint mode

`Ctrl+Shift+U` labels every visible URL with a two-letter code. Type the code to open
the link; hold Shift while typing to copy it instead. Any other key exits the mode.

OSC 8 hyperlinks (where the link text is not itself a URL) are handled correctly: the
label text is opened, not whatever characters happen to be on screen.

## Window identity

A compositor matches its window rules on the Wayland `app_id`, which is `maai`
unless you say otherwise. `--app-id NAME` gives one window an identity of its
own, so a dropdown or a dashboard can carry rules that no other terminal
inherits:

```sh
maai --app-id scratchterm
```

The toplevel title follows the active tab — whatever the program running in it
sets through OSC 0 or OSC 2 — and falls back to `maai` when nothing has set one.
That is the name a window switcher, a bar, or `swaymsg -t get_tree` shows.

## Control socket

Each window listens on `$XDG_RUNTIME_DIR/maai/<pid>.sock`, so something outside
can bring a particular tab to the front, or ask for one. Tabs are addressed by
the index of their pseudo-terminal: `/dev/pts/N` is the one name a session and an
outside observer can both pronounce — it shows up in `ps` and in `/proc`, and a
process can read its own.

One command per line, one line of reply:

| Request | Reply |
|---|---|
| `ping` | `ok` |
| `list` | `ok 7,*12,3` — each tab's pts in order, the active one starred, `?` when unknown |
| `focus-pts N` | `ok`, or `err no-such-pts` |
| `new-tab-pts N` | `ok`, or `err no-such-pts`, `err no-tabs`, `err tab-failed` |

Anything else answers `err bad-command`.

```sh
printf 'focus-pts 7\n' | nc -U "$XDG_RUNTIME_DIR/maai/$(pgrep -x maai | head -1).sock"
```

`new-tab-pts` opens a shell in the window holding the tab on `/dev/pts/N` and
brings it to the front, starting in that tab's own directory — what it announced
through OSC 7, or failing that what its pty says. It lands at the end of the
strip, where a new tab always lands. A window launched with `--no-tabs` answers
`err no-tabs`: the flag is a promise the socket keeps too.

The shell, specifically, and never the window's own `-e` command: a caller asking
for a terminal in a directory does not mean "run that program again".

Two things this deliberately is not. The access control is the filesystem's:
`$XDG_RUNTIME_DIR` is already private to one user, and a token of our own would
be one more thing to get wrong without being one more thing to get past. And no
command writes to a child: `new-tab-pts` takes a tab index and nothing else — no
program, no arguments, no path — so the socket moves the focus and asks for a
shell, and never injects input into either.

Without `XDG_RUNTIME_DIR` no socket is created and everything else works as
before, the same way the config watcher degrades.

## Tests

```sh
zig build test-pure   # terminal logic only — fast, no Wayland/EGL/fcft required
zig build test        # full suite
zig build bench -Doptimize=ReleaseFast
```

## License

MIT — see [LICENSE](LICENSE).
