# Eyes

A classic Macintosh-inspired pointer watcher: a pair of eyes that live in the **menu bar** (macOS / Linux panel) or the **Windows taskbar / notification area**, and follow the mouse wherever it goes.

Written in **Free Pascal**. Lazarus and Delphi are not required — `fpc` plus the platform GUI libraries already on the machine are enough. There is no 3D engine and no game toolkit. Pupils, blinks, and sleep are a few numbers; each tick those numbers are turned into RGBA pixels and shown as a status-item image.

The eyes:

- follow the pointer
- go **cross-eyed** when the pointer sits between them
- **blink** on their own
- **doze off** if nothing moves for a while, and wake as soon as it does

How the pieces fit together (same style as Goody's Scrolling Text, Flying Through Space, and Moiré): `WORKINGS.md` for responsibilities and pupil math, `EXECUTION_FLOW.md` for a frame-by-frame trace.

## Requirements

- **Free Pascal** 3.2+ (`fpc` on your `PATH`)

macOS (Homebrew):

```bash
brew install fpc
```

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
```

Windows: a native Free Pascal install (the `Windows` / `ShellAPI` units ship with FPC).

## Run

From the project root:

```bash
make
make run
```

That compiles to `build/` and opens `Eyes.app` on macOS. The pair appears in the **right-hand menu extras**. There is no Dock icon (`LSUIElement`).

Or with Make on other OSes:

```bash
make linux      # Linux / Raspberry Pi OS panel icon + optional window
make windows    # Eyes.exe — tray icon + taskbar window
make clean      # remove build/
```

Manual compile on macOS:

```bash
fpc -Mobjfpc -Scgi -O2 -Fusrc -FUbuild -FEbuild -obuild/Eyes src/eyes.pas
open build/Eyes.app
```

## Using it

1. Move the mouse. Both pupils track it.
2. Hover between the two eyes (or park the pointer on the menu extra itself). They go cross-eyed.
3. Leave the mouse still for about 14 seconds to see a drowsy squint, or about 26 seconds to see them sleep.
4. Click the menu-bar eyes for **Show Desktop Eyes**, **About Eyes**, and **Quit Eyes**. **⌘⇧E** (macOS) shows or hides the desktop pair even after they are tucked away. On Windows / Linux, **Ctrl+Shift+E** does the same while that window is focused.
5. Close the desktop window to tuck the large pair away. The menu-bar pair stays put.

## Where they appear

| OS | Presence |
|----|----------|
| **macOS** | Menu bar extra (right-hand extras). Optional floating desktop window. |
| **Windows** | Notification-area icon **and** a taskbar window (always on top). |
| **Linux** | GTK 2 status icon on the panel / menu bar (Raspberry Pi OS friendly), plus an optional desktop window. |

## Project layout

```
src/
  eyes.pas          # program; picks the host with {$IFDEF}
  ueyesmodel.pas    # pupil tracking, blink, sleep
  ueyesrender.pas   # software RGBA canvas (ellipses, lids)
  ueyesapp.pas      # TEyesController: two buffers, one model
  uhostcocoa.pas    # macOS NSStatusItem + NSWindow
  uhostwin.pas      # Windows tray icon + HWND
  uhostgtk.pas      # Linux GtkStatusIcon + GtkWindow
bundle/
  Info.plist        # LSUIElement menu extra, retina-capable
Makefile
```
