# How Eyes works

This note is for an automation tester who wants to see how a small Free Pascal desktop accessory is structured: where it starts, who owns state, who paints pixels, and how the pupils move.

You do not need to be a Cocoa, Win32, or GTK expert. The same ideas show up in many GUI and game-like apps: an entry point, a model, a view, and a timed loop that updates positions then redraws.

There is **no 3D engine** and **no Lazarus**. Each eye is a centre, a radius, and a pupil offset. Each tick the pupil is clamped onto a line toward the mouse. Each paint those numbers are turned into anti-aliased ellipses in an RGBA buffer. The host only uploads that buffer to the menu bar / tray / window.

Going **cross-eyed** is not a special case. When the pointer sits between the two centres, the left pupil is pulled right and the right pupil is pulled left because each is independently clamped inside its own sclera. That is the whole xeyes / classic Mac Eyes trick.

## Mental model

```
eyes.pas begin
  → HostRun                    # uhostcocoa / uhostwin / uhostgtk
      → create TEyesController (model + two pixel buffers)
      → create status item / tray icon / panel icon
      → optional desktop window
      → timer (~30 FPS)
           → Model.Update (idle, blink, lids)
           → MouseToCanvas + Model.Pose (pupil positions)
           → RenderEyes (RGBA pixels)
           → host shows the buffer as an icon / view
```

| Layer | Unit | Tester-friendly analogy |
|-------|------|-------------------------|
| Entry / routing | `eyes.pas` | Test runner that picks the OS host at compile time |
| State | `ueyesmodel` | Fixture: idle time, lid opening, pupil clamp |
| Composer | `ueyesapp` | Holds one model and two canvases (bar + desk) |
| Animation view | `ueyesrender` | The thing that actually paints sclera / pupil / lid |
| Window shell | `uhostcocoa` / `uhostwin` / `uhostgtk` | Menu extra, tray, or panel + “show / quit” |

The hosts are **event-driven**. Almost everything after `HostRun` runs on the GUI thread (Cocoa run loop, Windows message loop, GTK main loop). Clicks, timer ticks, and drawing all happen there. That is why the animation uses `NSTimer` / `SetTimer` / `g_timeout_add` instead of a raw `while true` loop on a background thread.

---

## 1. Entry point and execution lifecycle

### Where `main` lives

The process entry point is the Pascal `program Eyes` in `src/eyes.pas`. It has no logic of its own. `{$IFDEF}` chooses one host unit; `begin HostRun; end.`

```pascal
uses
  {$IFDEF DARWIN}
  uhostcocoa
  {$ELSE}
    {$IFDEF WINDOWS}
    uhostwin
    {$ELSE}
    uhostgtk
    {$ENDIF}
  {$ENDIF};

begin
  HostRun;
end.
```

Only one `HostRun` is linked. The other two host units are not compiled on that OS.

### Lifecycle, step by step (macOS — the reference host)

1. **The OS** starts `Eyes.app/Contents/MacOS/Eyes`.
2. **`HostRun`** creates an `NSAutoreleasePool`, gets `NSApplication.sharedApplication`, and sets **`NSApplicationActivationPolicyAccessory`** so there is no Dock icon (the bundle also has `LSUIElement`).
3. **`TAppDelegate.alloc.init`** becomes the application (and window) delegate.
4. **`setup`** (also called again from `applicationDidFinishLaunching`, but it is idempotent via `ready`):
   - reads `backingScaleFactor` (usually 2 on retina)
   - `TEyesController.Create` with bar `44×22` points and desk `240×120` points, scaled to pixels
   - builds the status-item menu (Show Desktop Eyes / About / Quit)
   - `NSStatusBar.statusItemWithLength(44)` and `setImagePosition(NSImageOnly)`
   - creates the floating `NSWindow` at the top-right of `visibleFrame`
   - starts `NSTimer` at `1/30` s → `tick:`
5. **`App.run`** enters the Cocoa run loop. The process stays alive until **Quit Eyes** calls `terminate`.

### Two user journeys

**Menu bar only** (default extra):

```
setup creates NSStatusItem
  → timer ticks
  → pupils track NSEvent.mouseLocation
  → bar RGBA buffer becomes the status-item image
  → click extra → menu (Show Desktop Eyes / About / Quit)
```

**Desktop window** (menu **Show Desktop Eyes**, or already shown on launch):

```
same model, second canvas (Desk)
  → mouse converted into the window's canvas
  → RenderEyes with a platinum backdrop
  → TEyesDeskView.drawRect blits deskImage
  → close box → windowShouldClose hides the window, does not quit
```

Windows and Linux follow the same composer: one `TEyesController`, a ~33 ms tick, a small “bar” buffer for the tray/panel, a larger “desk” buffer for the window.

### Why testers care

- **Compile-time host is the feature flag.** Automating “Mac extra” vs “Windows tray” is `make` vs `make windows`, not a CLI switch.
- **There is no preferences file.** Blink timing and sleep delays are constants in `ueyesmodel` (`IdleDrowsy = 14`, `IdleSleep = 26`). A test that wants sleep should leave the pointer still, not edit a config.
- **Exit is process-level** (`terminate` / `PostQuitMessage` / `gtk_main_quit`), not “navigate back to a page.”
- **The menu-bar image is the real renderer.** If pupils move in the extra, `RenderEyes` will move them in the desktop window. You are not testing a fake stub.

---

## 2. Main units and responsibilities

This is a **separation of UI vs state**, not a full MVC framework. There is no database and no service layer.

### `eyes.pas` — composition root

- Picks the host with `{$IFDEF}`
- Calls `HostRun`
- Does **not** draw eyes or store pupil coordinates

### `ueyesmodel` — state management

Holds *behaviour*, not pixels:

- last mouse (screen space) and idle seconds
- lid opening `FLid` / `FLidTarget` (0 = closed, 1 = open)
- blink schedule (`FNextBlink`, `FBlinkPhase`, optional double blink)
- drowsy / asleep flags

**`Update(Dt, MouseX, MouseY)`** is the only mutator for that state. It uses **elapsed real time** so a late tick does not skip the drowsy threshold in one jump (`Dt` is capped at 0.2 s).

**`Pose(MouseCanvas, Layout)`** does **not** mutate idle/blink. It only returns the two pupil positions plus the current lid. That is why the bar extra and the desktop window can disagree about *where* the mouse is (different canvases) while sharing the same blink.

**Clamping:** `Track` shortens the eye→mouse vector so the pupil stays inside `MaxTravel` (sclera radius minus pupil radius). That clamp *is* cross-eyed looking.

This unit is the closest thing to a **model**. It has no Cocoa/Win32/GTK types.

### `ueyesrender` — software canvas

- `TPixelBuffer`: a packed RGBA byte array (`Width × Height × 4`)
- `FillEllipse` / `StrokeEllipse` / `FillEllipseClipped` with coverage anti-aliasing
- `DrawEye`: sclera, pupil, highlight, outline; or `DrawClosedLid` when `Lid < 0.12`
- `RenderEyes`: clear, optional backdrop, two `DrawEye` calls from `MakeLayout`

It does **not** know about the mouse. It only paints a `TEyesPose`.

### `ueyesapp` — one controller, two buffers

- Owns `TEyesModel`, `Bar`, `Desk`
- `Tick` → `Model.Update` with **screen** mouse
- `RenderBar` / `RenderDesk` → `Model.Pose` with **canvas** mouse, then `RenderEyes`
- `ShowDesktop` is a boolean the host reads; the controller does not create windows

### `uhostcocoa` — macOS shell

- `NSStatusItem` in the menu bar; image is not a template (so the white sclera stays white)
- `NSTimer` at 30 Hz, also added to `NSRunLoopCommonModes` so it keeps firing while a menu is open
- `NSEvent.mouseLocation` (bottom-left Cocoa screen space)
- `MouseToCanvas(..., FlipY=True)` because the pixel buffer is y-down
- Each tick **copies** the RGBA canvas into a new `NSImage` (AppKit-owned bitmap). Reusing one image and calling `recache` is not enough: `NSStatusItem` keeps showing the first frame
- `setImage(nil)` then `setImage(fresh)` forces the extra to notice the new picture
- Accessory policy: no Dock. Menu is how you quit.

### `uhostwin` — Windows shell

- Hidden-less overlapped window (`WS_EX_APPWINDOW or WS_EX_TOPMOST`) so it **appears on the taskbar**
- `NOTIFYICONDATA` + `Shell_NotifyIcon(NIM_MODIFY)` for the notification-area icon
- `WM_TIMER` 33 ms, `GetCursorPos`, `CopyBGRA` (Windows icons are BGRA)
- Right-click tray → popup; double-click shows the desktop window

### `uhostgtk` — Linux shell

- `gtk_status_icon_new` for the panel (XEmbed / lxpanel / Raspberry Pi OS)
- `g_timeout_add(33, OnTick)`
- `gdk_display_get_pointer` + `gtk_status_icon_get_geometry` so the extra aims locally
- Left-click toggles the desktop window; right-click is the same menu idea

### What is *not* a unit

There is no `Camera`, `Scene`, or sprite class. The “objects” on screen are two ellipses. Position is a `TVec2` per pupil on `TEyesPose`.

---

## 3. How the render / animation loop works

This is **not** a classic game loop on a worker thread (`while running do begin Update; Render; end`).

It is a **GUI timer loop** on the UI thread:

```
timer (~33 ms, 30 FPS)
    → Tick / Model.Update     // idle, blink, lid target
        → Pose + RenderEyes   // pupils + pixels
            → host presents   // setImage / StretchDIBits / set_from_pixbuf
```

### Timer setup (macOS)

```text
interval = 1.0 / 30.0
animTimer = NSTimer.scheduledTimer(..., 'tick:', repeats)
animTimer.retain
NSRunLoop.currentRunLoop.addTimer(animTimer, NSRunLoopCommonModes)
```

`tick:` runs on the **main run loop**, so it may touch AppKit safely. Common modes keep ticks coming during menu tracking. A `NSAutoreleasePool` wraps each tick so 30 Hz `NSImage` traffic does not leak.

Each present builds a **new** `NSImage`: `MakeImage` asks `NSBitmapImageRep` for its own `bitmapData` (`planes = nil`) and `Move`s the Pascal pixels in. The status button is then `setImage(nil)` / `setImage(barImage)`. Aliasing `Bar.Ptr` and calling `recache` looks cheap, but AppKit caches the extra and the pair appears frozen (tracking, blink, and sleep still run in the model).

Windows uses `SetTimer(Wnd, 1, 33, nil)` → `WM_TIMER`. Linux uses `g_timeout_add(33, ...)`.

### When it starts and stops

| Hook | Meaning |
|------|--------|
| `setup` / `WM_CREATE` / `HostRun` | Timer is armed |
| `tick:` / `TickFrame` / `OnTick` | One frame |
| Quit menu / `WM_DESTROY` / `gtk_main_quit` | Process ends; timer dies with it |

There is no `addNotify` equivalent on the extra: the status item exists as soon as `setup` returns.

### Update vs draw (important split)

| Procedure | Mutates | Draws |
|-----------|---------|-------|
| `TEyesModel.Update` | idle, blink phase, `FLid` | no |
| `TEyesModel.Pose` | nothing | no (returns pupil points) |
| `RenderEyes` | pixel buffer only | yes |
| host `setImage` / `InvalidateRect` | nothing in the model | presents |

A tester debugging “they never sleep” should breakpoint `Update` and watch `FIdle`. A tester debugging “the extra is blank” should breakpoint `RenderEyes` / `MakeImage`. A tester debugging “they look the wrong way” should breakpoint `Track` / `MouseToCanvas`. A tester debugging “they are frozen in the menu bar but About still works” should check that `MakeImage` copies pixels each tick — the model may be animating behind a cached `NSImage`.

### Why not `Thread.sleep` in a loop?

A blocking loop on the GUI thread would freeze menus and paints. A loop on another thread would have to marshal every `setImage` / `InvalidateRect` back to the GUI thread. The timer is the platform-native “game loop.”

### Frame timing vs movement

The timer *aims* at 30 Hz, but it can jitter. Lid motion is **not** “subtract 0.1 every tick.” It uses **elapsed real time** (`Dt`) and an exponential approach (`Smooth`) so a blink still lasts ~0.16 s if a tick is late.

---

## 4. Position math on each tick

Two coordinate systems matter:

- **Screen space** — `NSEvent.mouseLocation` / `GetCursorPos` / `gdk_display_get_pointer`. Used only for idle / wake (`Update`).
- **Canvas space** — pixels inside `Bar` or `Desk`, **y down**. Used for `Pose` and painting.

`MouseToCanvas` maps the pointer into the extra or the window:

```text
canvasX = (mouseX - viewX) * (canvasW / viewW)
canvasY = (mouseY - viewY) * (canvasH / viewH)     # Win / GTK
canvasY = canvasH - (mouseY - viewY) * (canvasH / viewH)  # Cocoa (FlipY)
```

If the host cannot yet locate the extra (`viewW < 0.5`), it aims at the canvas centre so the pupils rest instead of jumping to infinity.

### Layout (`MakeLayout`)

```text
S       = min(canvasW / 2.15, canvasH / 1.05)
RX, RY  = 0.42 S, 0.40 S          # slightly oval, classic Mac
LeftCX  = 0.27 * canvasW
RightCX = 0.73 * canvasW
CY      = 0.52 * canvasH
PupilR  = 0.36 * min(RX, RY)
MaxTravel = min(RX, RY) - PupilR - 0.85
```

The same formula sizes the 44×22 extra and the 240×120 window. That is why both look like the same pair.

### Pupil clamp (`Track`) — this is cross-eyed

```text
dx, dy = mouse - eyeCentre
dist   = hypot(dx, dy)
if dist > MaxTravel
    scale = MaxTravel / dist
else
    scale = 1
pupil  = eyeCentre + (dx, dy) * scale
```

When the pointer is **far left**, both scales point left: the pair looks left.  
When the pointer is **between** the two centres and nearby, `dx` for the left eye is positive and `dx` for the right eye is negative: **cross-eyed**.  
When the pointer is **on** an eye, `dist < MaxTravel` and that pupil sits on the pointer.

There is no `if BetweenEyes then Cross` branch.

### Blink

Every 2.4–6.2 s (`ScheduleBlink`), `FBlinkPhase` runs:

| Phase (s) | Lid target |
|-----------|------------|
| 0.00–0.07 | 0 (closing) |
| 0.07–0.16 | 1 (opening) |
| 0.16–0.28 | 0 again if `Random < 0.12` (double blink) |
| 0.28–0.38 | 1 |

`FLid` eases toward the target with `Smooth` (speed 18 during a blink, 14 awake, 3.2 drowsy). The renderer uses `OpenRY = RY * (0.16 + Lid * 0.84)`, so a blink is a vertical squash of the sclera, not a texture swap.

### Sleep

```text
if mouse moved ≥ 4 px:  idle = 0; wake
else:                   idle += Dt

idle ≥ 14 s  → drowsy, lid target 0.42
idle ≥ 26 s  → asleep, lid target 0.0, blinks stop
```

Asleep and `Lid < 0.12` draws a closed-lid arc instead of a pupil. Any 4 px move clears idle and the lids open again.

### Who updates what

| Value | Updated when | Role |
|-------|----------------|------|
| `FIdle`, `FAsleep`, `FDrowsy` | every timer tick (`Update`) | sleep state |
| `FLid` | every timer tick | blink / drowsy squash |
| `Pose.Left/Right` | every render | pupil pixels in that canvas |
| pixel buffer | every render | thrown away next frame |
| status-item image | after render | what the user sees in the extra |

Idle tests: leave the mouse still and watch `FIdle` climb past 14 then 26. You are not changing a “sleep sprite”; you are changing the lid target.

---

## Quick map of files

```
src/
  eyes.pas          # program, {$IFDEF} host
  ueyesmodel.pas    # Update + Track + blink/sleep
  ueyesrender.pas   # RGBA ellipses, lids
  ueyesapp.pas      # controller, bar + desk buffers
  uhostcocoa.pas    # NSStatusItem, NSTimer, NSWindow
  uhostwin.pas      # tray icon, WM_TIMER, taskbar HWND
  uhostgtk.pas      # GtkStatusIcon, g_timeout_add
bundle/Info.plist   # LSUIElement, NSHighResolutionCapable
```

If you are tracing in a debugger, put breakpoints on `HostRun`, `TEyesModel.Update`, `TEyesModel.Track`, and `RenderEyes`. You will see: **tick updates idle/lids → Pose clamps pupils → paint ellipses → host presents**.
