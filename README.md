# Terminal

**Agora's terminal application** — a window with a shell in it, the way `Terminal.app` is a window with a shell in
it. It is an *application*: it consumes the AppKit as a built package (`AgoraApp::App`), installs no library of its
own, and installs its bundle.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent directory
(`../README.md`).

## The division of labour

**Everything about the emulation is `libagora-tsm`'s** (libtsm, MIT, the kmscon state machine): the VT parser, the
primary and alternate screens, scrollback, attributes and colours, charsets, mouse-tracking modes, bracketed paste,
the reply generator for `DA1`/`DSR`, and the key handler that turns a keystroke into an escape sequence. What lives
here is the three things a library cannot do:

| Here | What it does |
|---|---|
| `src/AGTerminalGrid.m` | wraps the emulator: bytes in, replies out, the cell table, scrollback position, cursor |
| `src/AGTerminalRenderer.m` | the paint: cell metrics from one glyph, a glyph per codepoint with a fallback chain, the cursor |
| `src/AGTerminalSession.m` | the process: a login shell on a pty, its output on the run loop, `SIGWINCH` on resize |
| `src/AGTerminalView.m` | the glass and the keys: draw, and split commanding keys from typed ones |

**The key split is Apple's, and it is why the last three slices of the AppKit were worth doing.** A key that COMMANDS
— an arrow, Home, Escape, Tab, a Control combination — goes to the emulator with its keysym, the layout-independent
ASCII keysym, the modifiers and the character: `NSEvent -cg_keysym`, `-charactersIgnoringModifiers`, `-modifierFlags`
and `-characters`, which is exactly `tsm_vte_handle_keyboard`'s parameter list. A key that TYPES goes through
`-interpretKeyEvents:`, so the AppKit's input context composes it — a dead key becomes one character, and an input
method can slot in without this application changing.

## Build and run

```sh
cmake -S . -B build -DCMAKE_C_COMPILER=/usr/bin/clang-19 -DCMAKE_OBJC_COMPILER=/usr/bin/clang-19 \
  -DCMAKE_PREFIX_PATH=../build-prefix -DCMAKE_INSTALL_PREFIX=../build-prefix
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
./build/Terminal.app/Contents/Linux/amd64/Terminal
```

Test doors, named as ones: `--seconds N` bounds the run (a terminal is a thing that stays), `--shell PATH` picks the
shell, and `--command TEXT` types a command once the shell is up — which is how a probe gets a deterministic screen
without a keyboard.

## What is proven, and how

Three probes, none of which needs a compositor:

| Probe | Claim |
|---|---|
| `tests/terminal_draw.m` (22 checks) | the renderer's pixels: ground, ink in the right cell and no other, palette and 24-bit colour, a background filling an empty cell, a wide glyph spanning two cells, the cursor as an inverse cell, scrollback |
| `tests/terminal_view.m` (8 checks) | the VIEW, through `-displayRect:` — the AppKit's own dispatch, the same `-drawRect:` a window's frame path calls |
| `tests/terminal_session.m` (9 checks) | a real `/bin/sh` on a real pty: its own `TIOCGWINSZ` answering `24 80`, the line discipline echoing, a coloured line arriving in the grid, a resize reaching the child as `SIGWINCH` (`33 100`), and the exit noticed exactly once |

`/tmp/terminal-view.ppm` and `/tmp/terminal-draw.ppm` are written by the first two, so the pixels can be checked by
eye as well as by arithmetic.

**Four bugs these probes found, each of which would have shown as "the terminal is broken" on a person's screen:**

1. **The fill colour space.** `CGContextSetFillColor` reads its components in whatever space the context was last
   told it is filling with, and a bitmap context's default is DEVICE GRAY — so an RGBA ground of `(0,0,0,1)` painted
   transparent black and the ink painted grey at 89% alpha. The renderer sets colours through `…WithFillColor:` now,
   which carries its own space.
2. **The bounded run ran the wrong wait.** Draining `NSApplication`'s event queue dispatches keys and clicks but never
   services the `NSFileHandle` readability source the pty hangs off, so a shell printing every 100 ms produced four
   frames in five seconds and a frozen screen. The test path runs the run loop and *then* drains the queue.
3. **libtsm counts the scrollback position from the top.** `tsm_screen_sb_get_line_pos` answers the line the view
   starts at counted DOWN from the oldest line, and the live screen reports the line COUNT — so "scrolled back" is
   `pos < count`, not `pos > 0`.
4. **A monospace face has no CJK.** The renderer grew a fallback chain (`CTFontCreateForString`, nine slots): without
   it every non-Latin character was silently dropped.

## What is not here yet

- **Selection and Copy.** Paste works (`Cmd+V` is a menu item, and the emulator wraps it in bracketed paste when the
  program asked); Copy refuses until the view has a selection, and libtsm already provides the model
  (`tsm_screen_selection_{start,target,word,copy}`) to build it on.
- **Tabs and windows.** One window, one session.
- **Mouse reporting.** The emulator tracks the modes and encodes the events; the view does not send them yet.
- **Cursor blink.** The rate is the emulator's to say (`tsm_screen_get_cursor_blinking_rate_ms`); nothing ticks.
- **A window that is exactly whole cells** on a fractional output scale, and `-copy:` enabled in the menu.
- **The AppKit's own tab/`NSWindow` chrome** — this window is the plain one.

## Note on the headless compositor

A window's own pixels cannot be seen through `window-server --screenshot` at the time of writing: the known-good
controls demonstration renders a blank body through the same invocation, so the fault is in that screenshot path and
not in a client. The probes above deliberately do not depend on it.
