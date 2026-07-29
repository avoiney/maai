# myterm — implementation plan

A fast, keyboard-driven, Wayland-native terminal emulator for this machine.

## 0. Target machine (measured, 2026-07-29)

| Property | Value | Consequence for design |
|---|---|---|
| Session | Wayland, `sway`/wlroots | Native Wayland only. No X11/XWayland backend. |
| GPU | AMD Strix Radeon 890M (integrated) | Mesa radeonsi, GLES3 + EGL available. Shared memory bandwidth with CPU — glyph atlas uploads are cheap. |
| CPU / RAM | Ryzen AI 9 HX PRO 370, 24 threads / 53 GiB | Threads are free. Parse work can live off the UI thread without contention. |
| Displays | 1920x1200 (laptop) + 2560x1440 @ 75 Hz (MSI) | **Mixed DPI, mixed refresh.** Must handle per-output scale and re-rasterize glyphs on output change. This is a first-class requirement, not polish. |
| Distro | Ubuntu 26.04 LTS | All deps packaged (see §9). |
| Font | `FiraCode Nerd Font Ret` 12pt | Ligatures (HarfBuzz run shaping) + Nerd Font icons (fallback + double-width). |
| Shell | `/usr/bin/zsh` | — |
| Existing | `kitty`, `wezterm`, `foot` installed | Reference implementations and A/B benchmark baselines. |
| URL handler | `google-chrome.desktop` via `xdg-open` | Click-to-open target. |

### Note on the current setup

`~/.config/wezterm/wezterm.lua` line 27 sets `config.enable_wayland = false`. WezTerm is
therefore running through **XWayland** today — which costs a compositor round trip, breaks
fractional scaling across your two different-DPI monitors, and routes clipboard through
XWayland's selection bridge. A large part of the "not fast enough" feeling is likely that,
not WezTerm itself.

Worth confirming before writing 20k lines: run `foot` for a day, or flip that flag to
`true` and see what breaks. If a specific WezTerm-on-Wayland bug is what drove that flag,
we need to know what it is — it's a bug this project must not reproduce.

That said, the plan below is written to be built as asked.

## 1. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | **Zig 0.16.0** (via `mise`) | Seamless C ABI interop with the whole Wayland/font stack, no GC, explicit allocators. Ghostty proves the approach. |
| Renderer | **GLES3 glyph atlas**, instanced quads | Scales to 1440p@75Hz, constant frame cost regardless of damage area, and makes inline images tractable. |
| Windowing | Native `wayland-client` + protocol codegen via `wayland-scanner` | No `zig-wayland` dependency to track across Zig releases. |
| Multiplexing | **Tabs + splits** in-process | As requested. Binary layout tree per tab, i3-style directional focus. |
| Font stack | `libfcft` in phase 1 → direct FreeType + HarfBuzz in phase 7 | fcft gives shaping, fallback chains, and caching immediately; dropping to raw FT/HB later buys subpixel positioning control. |
| Config | Kitty-style `key value` text + `include` | You already know the format. No scripting runtime keeps startup at a few ms. |
| Scope extras | Ligatures, keyboard URL hints, live theme reload, inline images (Kitty + Sixel) | All four selected. |

### Honest scope estimate

With tabs, splits, GPU rendering, and inline images, this is a **large** project.
Ghostty is ~100k lines of Zig; kitty is ~90k of C and Python. A focused version
with exactly this feature set lands around **15–25k lines**, realistically
**3–6 months part-time**. Phases 1–4 (§5) reach daily-driver usability in a small
fraction of that; tabs, splits, and images are the long tail. Sequence accordingly and
switch to it as your daily terminal at the end of phase 4 — dogfooding is what will
actually find the bugs.

## 2. Process and thread model

Latency is the headline requirement, so the threading model is the most consequential
design choice in this document.

```
┌─ main thread ─────────────────────────────────────────────┐
│  epoll:                                                   │
│    wl_display fd    → input, configure, frame callbacks   │
│    inotify fd       → config + theme flavour reload       │
│    eventfd (wake)   → "a pane has damage, please render"  │
│    timerfd          → cursor blink, key repeat            │
│                                                           │
│  keypress → xkb → encode → write(pty_fd)   [NO handoff]   │
│  frame callback → render all visible panes → eglSwap      │
└───────────────────────────────────────────────────────────┘
        ▲ eventfd wake                       ▲
┌───────┴────────────┐            ┌──────────┴─────────────┐
│ pane 0 io+parse    │            │ pane N io+parse        │
│  read(pty) → VT    │    ...     │  read(pty) → VT        │
│  → mutate grid     │            │  → mutate grid         │
│  (per-pane mutex)  │            │  (per-pane mutex)      │
└────────────────────┘            └────────────────────────┘
```

Three rules that matter more than anything else here:

1. **Keypress writes to the PTY on the main thread, synchronously, before rendering.**
   No queue, no thread handoff, no waiting for a frame. This is the entire input latency
   path and it must be a straight line.
2. **Parsing never blocks the UI thread.** A `yes` flood or `cat` of a 500 MB file must
   not delay a keystroke or a window resize. This is why parse lives on its own thread
   per pane.
3. **Render at most once per frame callback.** Under output flood, drain the PTY as far
   as it will go, coalesce all damage, then draw one frame. Rendering per read chunk is
   the single most common reason terminals are slow at `cat`.

Grid access uses a per-pane mutex. It is held only for the duration of a parse batch or a
render read — never across I/O or GPU calls. If contention shows up in profiling, the
upgrade path is a seqlock with a render-side snapshot, but do not start there.

No daemon/client split: it was not selected, and with tabs and splits in-process the
window-spawn cost that a daemon would amortize mostly disappears anyway.

## 3. Module layout

```
myterm/
├── build.zig                  # incl. wayland-scanner codegen step
├── build.zig.zon
├── .mise.toml                 # pins zig 0.16.0
├── protocols/                 # vendored .xml (see §9)
├── src/
│   ├── main.zig               # arg parsing, App init, event loop
│   ├── vt/
│   │   ├── parser.zig         # DEC ANSI/VT500 table-driven DFA
│   │   ├── fastpath.zig       # bulk printable-ASCII run scanner (@Vector)
│   │   ├── utf8.zig           # incremental UTF-8 decode
│   │   ├── csi.zig  osc.zig  dcs.zig  apc.zig
│   │   └── charset.zig        # DEC special graphics, G0-G3
│   ├── term/
│   │   ├── grid.zig           # rows, ring-buffer scrollback
│   │   ├── cell.zig           # packed cell + grapheme side table
│   │   ├── style.zig          # interned style table
│   │   ├── screen.zig         # cursor, margins, modes, tabstops
│   │   ├── reflow.zig         # resize + rewrap (bug farm — see §8)
│   │   ├── selection.zig
│   │   ├── search.zig
│   │   └── hyperlink.zig      # OSC 8 registry + URL scanner
│   ├── pty/
│   │   ├── pty.zig            # openpty, TIOCSWINSZ, winsize
│   │   └── spawn.zig          # fork/exec, session leader, env, cwd
│   ├── wl/
│   │   ├── display.zig  registry.zig  seat.zig
│   │   ├── window.zig         # xdg-surface/toplevel, configure state
│   │   ├── keyboard.zig       # xkbcommon + compose + repeat
│   │   ├── pointer.zig        # cursor-shape, scroll, click
│   │   ├── clipboard.zig      # wl_data_device (CLIPBOARD)
│   │   ├── primary.zig        # primary-selection-v1 (PRIMARY)
│   │   └── scale.zig          # fractional-scale + viewporter
│   ├── gfx/
│   │   ├── egl.zig            # EGL ctx on wl_egl_window
│   │   ├── atlas.zig          # shelf packer, R8 + RGBA8 atlases
│   │   ├── glyph_cache.zig    # (font,glyph,scale) → atlas region
│   │   ├── renderer.zig       # bg pass, glyph pass, deco pass
│   │   ├── images.zig         # image store, placements, z-order
│   │   └── shaders/
│   ├── font/
│   │   ├── fcft.zig           # phase 1 backend
│   │   ├── shaper.zig         # run segmentation for ligatures
│   │   └── metrics.zig        # cell size, baseline, underline pos
│   ├── ui/
│   │   ├── keybind.zig        # binding table → actions
│   │   ├── action.zig
│   │   ├── layout.zig         # split tree, directional focus
│   │   ├── tabbar.zig
│   │   ├── hints.zig          # keyboard URL hint overlay
│   │   └── open.zig           # safe URL launch (see §7)
│   └── config/
│       ├── parse.zig  theme.zig  watch.zig  defaults.zig
├── terminfo/myterm.ti
└── tests/
```

## 4. Core data structures

Cell packing drives both memory and render throughput, so fix it early and deliberately.

```zig
/// 8 bytes. At 2560x1440 / 12pt FiraCode (~10x19 px cells) a screen is
/// ~256x75 = 19k cells; 10k lines of scrollback ≈ 2.6M cells ≈ 21 MB. Fine.
pub const Cell = packed struct {
    /// Either a codepoint (<= 0x10FFFF), or an index into Grid.graphemes
    /// when .grapheme is set. Sentinel 0 = empty, 1 = wide-char spacer.
    content: u32,
    /// Index into the interned Style table. 24-bit fg + 24-bit bg + attr
    /// bits would be 8 bytes per cell on its own; interning collapses the
    /// common case (a whole screen usually uses < 100 distinct styles).
    style: u16,
    wide: u2,          // 0 narrow, 1 lead of wide, 2 spacer
    grapheme: bool,    // content is a grapheme-cluster index
    dirty: bool,
    _pad: u4,
};

pub const Style = struct {
    fg: Color, bg: Color, underline_color: Color,
    attrs: packed struct {
        bold: bool, dim: bool, italic: bool, inverse: bool,
        invisible: bool, strike: bool, blink: bool,
        underline: enum(u3) { none, single, double, curly, dotted, dashed },
    },
    hyperlink: u16,    // index into Hyperlink registry, 0 = none
};
```

- **Grid**: `ArrayList(Row)` used as a ring buffer for scrollback. `Row` carries its cells
  plus `wrapped: bool` (soft line continuation) and a dirty flag. `wrapped` is what makes
  triple-click-selects-logical-line, URL-detection-across-wraps, and reflow all work — it
  is not optional.
- **Grapheme side table**: emoji ZWJ sequences and combining marks exceed one codepoint.
  Store them out of line, keyed by index, so the common single-codepoint case stays 8 bytes.
- **Style interning**: hash map + dense array, refcounted per screen, rebuilt on clear.
- **Hyperlink registry**: OSC 8 `id=` → URI, scoped per pane, evicted with scrollback.
- **Alt screen**: a second `Grid` with no scrollback, swapped on DECSET 1049.

## 5. Phases

Each phase ends in something runnable. Do not proceed while the previous acceptance
criteria fail.

### Phase 0 — environment and a window ✅ done (2026-07-29)

Install toolchain and deps, wire `build.zig` to run `wayland-scanner` over the vendored
protocol XML, open an `xdg_toplevel` on sway, get an EGL/GLES3 context, clear it to a
color, handle `configure`/`close` correctly.

**Acceptance:** window appears tiled in sway, resizes cleanly, `$mod+Shift+q` closes it,
no protocol errors on `WAYLAND_DEBUG=1`.

**Result:** `GL_RENDERER = AMD Radeon 890M (radeonsi, strix1, ACO)`, GLES 3.2 / Mesa
26.0.3. Frame pacing measured at a steady **75.0 fps** on the MSI, i.e. frame callbacks
track the output refresh exactly. sway reports `app_id=myterm`, `shell=xdg_shell` —
native Wayland, no XWayland. Server-side decorations negotiated.

Findings worth keeping, each of which cost a build cycle:
- `usingnamespace` was **removed** in Zig 0.16 → C types are reached via
  `@import("c.zig").c`.
- The core `wayland.xml` must **not** be passed through wayland-scanner: libwayland-dev
  already ships that header and libwayland-client.so already exports every
  `wl_*_interface`. Only extension protocols get codegen.
- `@cImport` still works in 0.16, and translated all **237** of Wayland's
  `static inline` request wrappers — the risk noted in §10 is closed.
- `EGLNativeWindowType` is `*struct wl_egl_window` on the Wayland platform, so no
  handle cast at `eglCreateWindowSurface`.
- `std.posix.getenv` is gone; use `std.c.getenv`.

### Phase 1 — PTY and text on screen ✅ done (2026-07-29)

`openpty`, fork/exec `zsh` as session leader with correct `TERM`/`winsize`. Minimal VT:
printable ASCII, `\n \r \b \t`, SGR 0/1/30-37/40-47. Load FiraCode via fcft, rasterize
into the R8 atlas, render one instanced quad per cell. Background pass, then glyph pass.

**Acceptance:** `ls --color`, `echo`, and a shell prompt render correctly at both DPIs.

**Result:** cell 10x20 px, baseline 15, on `FiraCode Nerd Font:size=12:dpi=96`. Verified by
screenshot: `ls --color` directory colours and `tmp`'s background highlight, 16/256/truecolor
SGR, underline, inverse, dim, strikethrough, UTF-8 (`café → λ ★ ✓`), 8-column tab stops,
cursor block. Survived four rapid compositor resizes with no crash or corruption. fcft
reports `text-run=true`, so the ligature shaping phase 7 needs is available.

Delivered beyond the phase 1 line, and why:
- **Full Williams VT500 DFA**, not just the phase 1 subset — CSI/OSC/DCS/APC states all
  exist so phase 2 only fills in handlers, and phase 8 can hang Sixel and the Kitty
  graphics protocol off `dcsHook`/APC without restructuring.
- **Minimal xkb keyboard** (`src/wl/keyboard.zig`). Phase 3 owns keyboard properly, but
  phase 1's acceptance criteria cannot be checked interactively without being able to
  type. Missing on purpose: key repeat, Kitty keyboard protocol, compose/dead keys,
  DECCKM application cursor keys.
- **`test-pure` build target** — the C-free suite (27 tests) runs in well under a second,
  which is what makes the phase 2 reflow property tests practical to iterate on.
- **`-e cmd`** for scripted checks without a keyboard.

Deviation from §2 worth revisiting with data: the loop is **single-threaded** poll over
Wayland + PTY, not a per-pane parse thread. Threading only starts paying for itself with
multiple panes (phase 5), and foot shows a single-threaded loop is fully competitive.
Decide by measurement then, not on principle.

Known gaps carried into phase 2, all visible in the verification screenshots:
- Double-width characters render narrow and overlap (`日本語`); needs wcwidth plus the
  spacer cell and grapheme side table.
- Resize truncates instead of reflowing — deliberate, since rewrap needs the `wrapped`
  row flag that arrives with scrollback.
- No scrollback, no alt screen, no scroll regions, so nvim/htop are not usable yet.
- Style ids are never reclaimed (append-only until reset).
- `TERM=xterm-256color`, pending the myterm terminfo entry.

Zig 0.16 API findings, in addition to phase 0's:
- `std.posix.write`/`close` were removed (the `Io` interface supersedes them); with libc
  linked, call `std.c.write`/`std.c.close` and read errno via `std.c.errno(rc)`.
- `std.ArrayList` is now the **unmanaged** variant — `.empty`, and every method takes the
  allocator.
- `std.mem.trimRight`/`trimLeft` are now `trimEnd`/`trimStart`.
- `std.process.argsAlloc` and `std.os.argv` are gone. `main` takes
  `std.process.Init.Minimal`, whose `args.vector` is `[]const [*:0]const u8` — already C
  argv, so no duplication is needed before a fork/exec.
- `std.posix.PROT` is a packed struct of flags: `.{ .READ = true }`.

### Phase 2 — VT conformance, scrollback, reflow (≈3–4 weeks) — *in progress*

**Done (2026-07-29): scrollback and reflow.** Pulled forward ahead of the rest of phase 2
because truncation-on-resize was the most visible defect in daily use — narrowing the
window cut text off, and widening could not bring it back since the cells were genuinely
gone.

- `Row.wrapped` records a soft wrap, which is the one bit of state that lets resize tell
  "one long line" from "two short lines". Everything else here depends on it.
- Storage is now a single ring buffer covering scrollback *and* screen, so scrolling is
  "append a blank line" and history eviction falls out for free. Two allocations total: one
  cell slab plus one row-metadata array, with ring slot `k` permanently owning
  `slab[k * cols ..]`, so recycling a line during scroll is a memset.
- `resizeReflow` recovers logical lines across `wrapped`, re-splits at the new width, and
  carries the cursor by converting it to an offset within its logical line and back.
- Trailing empty screen lines are dropped before rewrapping. Without that, the blank
  remainder of the screen counts as real logical lines and every resize pushes actual
  output further up into scrollback — which looks like content scrolling away for no
  reason. The cursor's own line is always kept, since the prompt usually sits on an
  otherwise-empty line.

Verified by screenshot at 33 columns (long line spanning 5 rows, nothing lost) and back at
90 columns (original 2-row layout and colours restored), plus 33 unit tests including a
randomised width round-trip property test.

**Done (2026-07-29): full-screen application support.** The threshold for dogfooding, so
taken next.

- **Alternate screen** (1049, plus 47/1047/1048). The two grids are swapped *by value*, so
  `Screen` stays movable — an internal self-pointer would dangle as soon as the struct
  returned from `init` were copied. The alt grid is created with zero scrollback: a
  full-screen app's redraws are not history anyone wants to scroll through.
- **Scroll regions** (DECSTBM), with IND/RI/NEL, SU/SD, IL/DL. Region scrolls never reach
  scrollback — only a full-screen scroll on the primary grid does, or history would fill
  with fragments of every TUI repaint.
- **Line editing**: ICH, DCH, ECH, IRM insert mode, REP.
- **Tab stops**: a real stop table with HTS, TBC, CHT, CBT rather than fixed multiples of 8.
- **Saved cursor**: DECSC/DECRC and CSI s/u, carrying pen, origin mode and autowrap.
- **DECOM** origin mode, **DECCKM** application cursor keys (wired through to the input
  encoder — nvim and less need SS3 arrows), **DECALN** for vttest.
- **Device reports**: DA1, DA2, DSR 5, DSR 6/CPR. Every reply is a fixed shape with no
  attacker-influenced content — a report that echoes bytes chosen by remote output injects
  them into our own input stream. DECDSR (`CSI ? … n`) is deliberately unanswered, and
  `CSI t` window manipulation stays unimplemented for the same reason (§7).
- **Synchronized output** (2026): presentation is held off mid-update so an app's screen
  appears atomically. A 150 ms deadline is the safety valve, on a *monotonic* clock — wall
  time can step backwards under NTP and a deadline that never expires would freeze the
  terminal.

Verified by screenshot: **nvim** (syntax highlighting, git signs, tab line, powerline
statusline with Nerd Font glyphs), **htop** (24 CPU meters, tab headers, selection
highlight, function-key bar), **lazygit** (box-drawing panels, diff colours, full-width
layout). 52 unit tests.

A bug the tests caught that screenshots would not have: `Screen.resize` judged "did the
scroll region span the whole screen" against the *new* row count, so a full-screen region
stayed pinned to the old height and full-screen apps scrolled wrongly after any resize.

**Done (2026-07-29): character widths and grapheme clusters.** Prompted by Claude Code
rendering wrong: its UI is box-drawn frames full of emoji, and the right border landed on a
different column on every row.

Widths come from **utf8proc**, not libc `wcwidth()`, which consults the process locale and
would make layout depend on how the terminal was launched.

- Double-width characters occupy a lead cell plus a spacer (`wide = 1` / `wide = 2`).
  Overwriting either half clears the other, or an orphaned half corrupts the row from that
  point on. A wide character never straddles the right edge: it wraps whole, leaving the
  final column blank.
- Zero-width codepoints (combining marks, variation selectors) attach to the preceding cell
  through a grapheme side table, so `e` + `´` is one column and renders composed.
- **Emoji presentation is honoured**: `⚠` alone is one column, but `⚠️` (with U+FE0F) is
  two. That is what `string-width` (Node), `wcwidth` (Python) and `go-runewidth` all report,
  so it is what every TUI's own layout assumes. Following the narrower reading would keep
  those UIs misaligned — matching the ecosystem matters more here than matching the spec
  most literally.
- Clusters are capped at 8 codepoints. A remote process can emit thousands of combining
  marks against one base character ("zalgo" text); uncapped, that is an unbounded
  allocation driven by untrusted input.
- Reflow keeps pairs intact. Row breaks can no longer be computed arithmetically, so
  counting rows and emitting them share one walker (`Grid.Wrap`) that cannot disagree with
  itself.

Verified by generating a frame whose padding is computed with the ecosystem's width model
and checking it renders as a true rectangle across ASCII, emoji, VS16, CJK, combining marks
and mixed rows. 61 tests, 47 ms.

Cosmetic gap: `⚠️` renders in its monochrome text form, because we draw the base
codepoint's glyph and fcft resolves that to a text-presentation font. Correct emoji
presentation needs `fcft_rasterize_grapheme_utf32` shaping, which belongs with the phase 7
typography work. Alignment is unaffected.

**Done (2026-07-29): private-marker CSI sequences.** Claude Code still rendered every
character underlined after the width fix. `csiDispatch` was switching on the final byte
without consulting the private marker, so sequences from an entirely different namespace
were executed as their unmarked namesakes:

| Sequence | Actually means | Was executed as |
|---|---|---|
| `CSI > 4 ; 2 m` | xterm XTMODKEYS | SGR 4 + SGR 2 — underline and dim everything after |
| `CSI > 1 u` / `CSI < u` | kitty keyboard push/pop | CSI u — restore cursor, moving it at random |

Private-marked sequences are now dispatched separately, with only `?h`/`?l` and `>c`
acted on and the rest recognised but inert until phase 3 brings the keyboard protocols.

Worth keeping as a method note: this was found by capturing what the application actually
emits (`script -q -e -c claude`) and tabulating every CSI sequence in it, rather than by
reasoning about which SGR code might be at fault. The capture is also replayable, so the
fix could be verified against the real byte stream instead of a hand-written approximation
— and the first hand-written repro had in fact been misleading, because its padding was
hand-counted and so could never have aligned.

**Still outstanding in this phase:** the myterm terminfo entry plus `--print-terminfo`;
scrollback *viewing* (the data is there, the view offset and keybinding are not); style-id
and grapheme-id reclamation; and the `38:2::r:g:b` colon form with a colour-space id.

The bulk of correctness work.

- Full DEC ANSI DFA: CSI (params, intermediates, private markers), OSC (BEL and ST
  terminated), DCS, APC, SS2/SS3, DEC special graphics charset.
- Cursor movement, scroll regions (DECSTBM), insert/delete line/char, ED/EL variants,
  DECSET/DECRST modes, origin mode, auto-wrap, tab stops, alt screen (1049),
  bracketed paste (2004), mouse reporting (1000/1002/1003/1006), focus events (1004),
  synchronized output (2026 — cheap, and it fixes tmux/nvim flicker).
- 256-color and 24-bit SGR, underline styles 4:1–4:5, underline color (58/59).
- Scrollback ring buffer, configurable (default 10000, matching your current configs).
- **Resize with reflow**: rewrap soft-wrapped lines, keep the cursor anchored, preserve
  selection where possible.
- Ship `terminfo/myterm.ti`. Provide `myterm --print-terminfo` for remote hosts, and
  document `TERM=xterm-256color` fallback — missing terminfo over SSH is the single most
  common papercut of new terminals.

**Acceptance:** `vttest` menus 1–3 and 11 pass. `nvim`, `htop`, `lazygit`, `k9s`, `fzf`
are fully usable. Repeated random resizes never corrupt the grid or crash (§8 fuzz).

### Phase 3 — keyboard, selection, clipboard (≈2 weeks) — *your stated requirements*

- **Keyboard**: xkbcommon keymap from the compositor fd, layout/group changes, dead keys,
  `xkbcommon-compose`, repeat from `repeat_info`.
- **Kitty keyboard protocol** (progressive enhancement, CSI u) plus legacy
  `modifyOtherKeys`. Your nvim is 0.12.4 and supports it; this is what lets nvim tell
  `Ctrl+I` from `Tab` and see key releases. Central to "keyboard friendly".
- **Keybinding table** parsed from config → actions: tab new/close/next/prev/move,
  split h/v, directional focus, resize/zoom split, copy, paste, paste-primary, scroll
  line/page/top/bottom, search, hint mode, font size ±/reset, reload config, fullscreen,
  new window, visual select mode. Default prefix `Ctrl+Shift+*` so app keys stay free.
- **Selection**: drag = char; double-click = word (configurable separators);
  triple-click = *logical* line (follows `wrapped`); `Shift+click` extends;
  `Ctrl+drag` = rectangular block. Auto-scroll when dragging past an edge.
- **PRIMARY selection** via `primary-selection-v1`: set the offer as soon as a selection
  completes; **middle-click pastes PRIMARY**. This is the "classic clipboard buffer".
- **CLIPBOARD** via `wl_data_device`: `Ctrl+Shift+C` / `Ctrl+Shift+V`, offering
  `text/plain;charset=utf-8`, `UTF8_STRING`, `text/plain`, `TEXT`, `STRING`.
- **Keyboard visual-select mode** so selection never requires the mouse.
- Paste safety per §7.

**Acceptance:** select-to-PRIMARY and middle-click round-trip against `wl-paste -p`;
`Ctrl+Shift+C` round-trips against `wl-paste`; both interoperate with Chrome and nvim.

### Phase 4 — links (≈1 week) — *your stated requirement*

- **OSC 8** explicit hyperlinks resolved through the per-pane registry.
- **Plain-text URL scanner** over the grid: scheme allowlist, balanced-paren and
  trailing-punctuation handling, and joining across `wrapped` rows.
- **Hover**: underline the match and switch to a pointer via `cursor-shape-v1` while the
  configured modifier is held (default `Ctrl`, so hover never fights selection).
- **Click to open**: `posix_spawn` with an **argv array** — see §7, this is a real
  security boundary, not a style preference.
- **Hint mode**: keybind overlays a letter label on every visible match; press to open,
  or with a modifier to copy the URL instead.

**Acceptance:** click and hint-open both launch Chrome for `https://`, `file://`,
`mailto:`. A line containing `https://x/$(id>/tmp/pwn)` opens harmlessly and creates no
file. → **Switch to myterm as daily driver here.**

### Phase 5 — tabs and splits (≈3 weeks)

Layout tree `Leaf(pane) | Split{dir, ratio, [child]}` per tab. Per-pane PTY, grid, parse
thread, `TIOCSWINSZ`, and viewport rect. Geometric directional focus like sway. Bottom
tab bar (matching your current wezterm/kitty configs) with per-pane title from OSC 0/2.
Track cwd from **OSC 7** so new tabs and splits inherit the current directory — small
feature, disproportionate daily payoff.

**Acceptance:** 4-way split, all panes live and independently resizable; killing a pane
collapses its parent correctly; no PTY or thread leaks under repeated open/close
(check with `/proc/self/fd` and valgrind).

### Phase 6 — config and live theming (≈1 week)

Kitty-style parser with `include`. inotify watch on the config *and* on
`~/.config/.app-theme-flavour`, so your `dayfox`/`nightfox` switch re-themes every open
pane instantly instead of only at startup — a live upgrade over the current WezTerm
setup. Themes carry 16 ANSI colors plus fg/bg/cursor/selection. `OSC 4/10/11/12` runtime
color changes, and `OSC 104/110/111` resets.

**Acceptance:** editing config or flipping the flavour file re-themes without restart and
without dropping a frame.

### Phase 7 — performance and typography (≈2–3 weeks)

- **Parser fast path**: the DFA is correct but byte-at-a-time. Add a bulk scanner that
  finds the next control byte with `@Vector` (SSE2/AVX2) and blits the printable run
  straight into cells. This is *the* throughput win — typically 5–10x on `cat`.
- **Latency**: use `wp_presentation_feedback` to learn the compositor's frame deadline and
  render *late* in the frame rather than immediately on the callback. This is what wins
  latency benchmarks and it is invisible until you measure it.
- Damage-aware `eglSwapBuffersWithDamageKHR` so the compositor can partial-update.
- Typography: linear-space (gamma-correct) text blending to fix thin light-on-dark glyphs;
  optional subpixel positioning; move from fcft to direct FreeType + HarfBuzz for control
  over run segmentation, so FiraCode ligatures break correctly at cursor and selection
  boundaries.
- Atlas eviction under LRU with a memory budget.

### Phase 8 — inline images (≈4 weeks)

The largest single feature; sequence it last deliberately.

- **Kitty graphics protocol** over APC: transmission `a=T`/`a=t`, formats `f=32/24/100`,
  chunked `m=1`, placement `a=p` with `z`/crop/cell-span, unicode placeholders, deletion
  `a=d`, and shared-memory transfer.
- **PNG decode via `libspng`** (hardened, fast, packaged). Enforce hard dimension, pixel,
  and total-memory caps *before* allocating — this is attacker-controlled input (§7).
- **Image store**: id → GL texture, LRU with a memory budget; placements anchored to grid
  rows so they scroll with content and are freed when they fall out of scrollback.
- **Render order**: background → images `z<0` → text → images `z>=0`.
- **Sixel**: DCS parser, palette handling, raster attributes, convert to RGBA, then reuse
  the same placement machinery.

**Acceptance:** `kitten icat` renders and scrolls correctly; image memory returns to
baseline after `clear`; a truncated or malicious PNG is rejected without crashing.

### Phase 9 — hardening (ongoing)

Fuzzing (§8), the §7 security checklist, `valgrind`/ASan clean under the full test suite,
leak checks on pane churn, and a crash handler that does **not** dump grid contents.

## 6. Performance budgets

Targets, and how each is measured. Numbers to beat are `foot` (fastest software renderer)
and `kitty` (fastest GPU renderer) — both already installed, so A/B is easy.

| Metric | Target | Measurement |
|---|---|---|
| Cold start → first frame | < 40 ms | `hyperfine 'myterm -e true'` |
| Keypress → pixels | < 1 frame (13 ms @75 Hz) | internal timestamps: `wl_keyboard` event → `eglSwapBuffers`, plus `wp_presentation_feedback` for actual scan-out |
| `cat` 100 MB ASCII | ≥ kitty | `vtebench`, `hyperfine` |
| Frame time, full 1440p redraw | < 1 ms GPU | `GL_EXT_disjoint_timer_query` |
| Idle CPU | ~0.0% | `top` with cursor blink off |
| RSS, 10k scrollback filled, 4 panes | < 150 MB | `/proc/self/status` |

Build a `--bench` mode early: feed a file straight into the parser with no rendering, so
parse throughput can be profiled with `perf` in isolation from the GPU.

## 7. Security model

This is a work machine that handles secrets, and a terminal renders **untrusted remote
output**. Any SSH session, container log, or `curl` output is an attack surface. These are
not hypotheticals — each has a CVE history in real terminals.

- **URL launch**: `posix_spawn` with an argv array (`{"xdg-open", url}`). Never `system()`,
  never a shell string, never string interpolation. Validate the scheme against an
  allowlist (`http`, `https`, `file`, `mailto`, `ssh`, `git`), reject C0/C1 control
  characters and newlines, cap length. A hostile log line must not become RCE on click.
- **OSC 52 clipboard read: denied by default.** Remote-triggered clipboard *reads* let a
  compromised host exfiltrate whatever you last copied — often a password or a key. Writes
  allowed, optionally with a prompt.
- **Paste**: bracketed paste on by default; confirm on multi-line paste; strip C0 controls
  except `\t`. Bracketed-paste bypass via embedded escape sequences is a known
  command-injection class.
- **No title reporting.** Do not implement the OSC/CSI title *query* responses. Output can
  set the title, then read it back into the input stream — a classic
  write-then-execute exfiltration primitive.
- **Bound every response.** DA1/DA2/DECRQSS/DSR replies must be fixed-shape and never echo
  attacker-controlled bytes back onto the PTY.
- **Image decoders**: caps on dimensions, pixel count, and total store bytes enforced
  before allocation. Fuzz `libspng` and the Sixel parser as untrusted parsers (§8).
- **Scrollback holds secrets**: no persistence to disk, no grid content in crash dumps or
  logs.
- Not setuid, no network, no telemetry, no auto-update.

## 8. Testing

- **Unit** (`zig build test`): parser against a sequence corpus; grid ops (scroll,
  insert/delete, ED/EL); selection ranges; URL scanner edge cases (trailing punctuation,
  wrapped lines, adjacent URLs); style interning refcounts.
- **Reflow suite**: resize-with-rewrap is the single richest source of bugs in every
  terminal emulator. Property test it — random content, random resize sequences, assert
  invariants (no cell loss on width round-trip, cursor stays on its logical line,
  wrapped-flag consistency).
- **Conformance**: `vttest` (packaged), plus Thomas Dickey's `esctest2` for CSI/OSC/DCS
  coverage. Track a pass list in the repo so regressions are visible.
- **Golden images**: render to an offscreen FBO, hash the PNG, diff on change. Catches
  shaper, atlas, and blending regressions that unit tests never see.
- **Fuzzing** (high value, cheap): AFL++ or `zig build fuzz` on the VT parser, the Sixel
  parser, and the Kitty-graphics APC parser. All three consume untrusted bytes.
- **Integration**: a pexpect-style harness driving real `nvim`, `htop`, `lazygit`, `k9s`
  through a headless compositor (`sway --headless` or `cage`) and asserting on the grid.
- **Sanitizers**: ASan/UBSan builds in CI; valgrind on the pane-churn leak test.

## 9. Dependencies — all packaged on Ubuntu 26.04

```sh
# Toolchain (mise already manages your Pythons; keep it consistent)
mise use -g zig@0.16.0        # NOT apt's `zig`, which is stale

# Build + Wayland + input
sudo apt install build-essential pkg-config libwayland-dev libwayland-bin \
    wayland-protocols libxkbcommon-dev

# Rendering
sudo apt install libegl-dev libgles-dev libwayland-egl-backend-dev libpixman-1-dev

# Fonts (fcft for phase 1; freetype/harfbuzz directly from phase 7)
sudo apt install libfcft-dev libfreetype-dev libfontconfig-dev libharfbuzz-dev

# Images + text
sudo apt install libspng-dev libutf8proc-dev

# Testing + benchmarking
sudo apt install vttest hyperfine ncurses-bin valgrind
```

Confirmed candidate versions: wayland 1.24.0, wayland-protocols 1.47, xkbcommon 1.13.1,
fcft 3.3.2, harfbuzz 12.3.2, freetype 2.14.2, pixman 0.46.4, spng 0.7.4, utf8proc 2.10.0,
vttest 2.7, hyperfine 1.19.0.

**Wayland protocols to vendor into `protocols/`** (verify each exists in
`/usr/share/wayland-protocols` as the first task of phase 0):

| Protocol | Why |
|---|---|
| `wayland.xml` | core |
| `xdg-shell` | toplevel windows |
| `xdg-decoration-unstable-v1` | tell sway we draw no client-side decorations |
| `primary-selection-unstable-v1` | **PRIMARY selection — your "classic clipboard buffer"** |
| `fractional-scale-v1` + `viewporter` | **mixed-DPI dual monitor, crisp glyphs** |
| `cursor-shape-v1` | pointer/text cursors without loading XCursor themes |
| `xdg-activation-v1` | focus handoff when opening a URL in Chrome |
| `text-input-unstable-v3` | optional — only if you need `ibus` IME input |

## 10. Risks

| Risk | Mitigation |
|---|---|
| **Scope.** Tabs + splits + GPU + images is ~4x the minimum viable terminal. | Phases are ordered so 1–4 is a usable daily driver. If momentum stalls, stopping after phase 4 still leaves something you use every day. |
| **Zig 0.16 churn.** `build.zig` and stdlib APIs move between releases. | Pin `zig@0.16.0` in `.mise.toml`; upgrade deliberately, never mid-phase. |
| **Reflow correctness.** Every terminal has bugs here. | Property tests from phase 2, before splits multiply the geometry cases. |
| **Mixed-DPI glyph handling.** Two different-density monitors is the case most terminals get wrong. | Key the glyph cache on `(font, glyph, scale)` from day one. Retrofitting scale into the cache key is painful. |
| **Kitty graphics protocol is under-specified in corners.** | Test against `kitten icat` and real `yazi`/`ranger` output; accept partial support and document exactly what's implemented. |
| **Terminfo over SSH.** | `--print-terminfo` plus documented `xterm-256color` fallback, from phase 2. |
| **Losing to `foot` on latency.** A software renderer genuinely can beat GPU at small damage. | Measure against foot from phase 1. The phase-7 presentation-feedback work is the answer; if it isn't, that's real data worth having. |

## 11. Phase 0, concretely

```sh
cd /home/avoiney/w/myterm
git init
mise use zig@0.16.0
# ...apt install block from §9...
ls /usr/share/wayland-protocols/{stable,staging,unstable}   # verify §9 table
mkdir -p protocols src/{vt,term,pty,wl,gfx/shaders,font,ui,config} terminfo tests
```

Then, in order: `build.zig` with the `wayland-scanner` codegen step → registry bind →
`xdg_toplevel` + configure handling → `wl_egl_window` + EGL context → `glClear` →
verify clean under `WAYLAND_DEBUG=1`.

Sway binding to add once phase 1 runs, alongside your existing WezTerm bindings so you can
switch back instantly:

```
bindsym $mod+Shift+Return exec /home/avoiney/w/myterm/zig-out/bin/myterm
```
