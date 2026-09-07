# Execution flow: from `begin` to a drawn frame

A step-by-step trace of what happens from `program Eyes` through host initialisation and timer startup, down to how individual frames are calculated and drawn.

Default launch (`make run`) opens the **macOS menu extra**. `make windows` / `make linux` use the same model and renderer; only the present step changes. This trace is **macOS** (`uhostcocoa`) unless a step says otherwise.

One thread does everything after startup:

- **main (Pascal, then Cocoa run loop)** — `HostRun`, `setup`, `tick:`, `updateImages`, AppKit drawing

There is no Swing EDT. `NSTimer` and `NSStatusItem.setImage` run on the same thread that called `NSApplication.run`.

---

## Phase A — process entry

**1.** The OS loads `Eyes.app/Contents/MacOS/Eyes` (or `./build/Eyes`). FPC unit initialisation runs (`TEyesModel` is not constructed yet).

**2.** `program Eyes` executes `HostRun`.

```pascal
{ src/eyes.pas }
begin
  HostRun;
end.
```

**3.** `HostRun` (Cocoa):

```pascal
procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
  Pool.release;
end;
```

Accessory policy (plus `LSUIElement` in `bundle/Info.plist`) means: **no Dock icon**, menu extra only. `App.run` does not return until Quit.

Windows: `HostRun` registers a window class, `CreateWindowEx`, `Shell_NotifyIcon(NIM_ADD)`, then `GetMessage`.  
Linux: `gtk_init`, `gtk_status_icon_new`, `g_timeout_add(33, ...)`, `gtk_main`.

---

## Phase B — screen initialisation (`setup`)

**4.** `TAppDelegate.setup` is idempotent (`if ready then Exit`). `applicationDidFinishLaunching` calls it again after `App.run` has started; the second call is a no-op except `syncDesktop`.

**5.** Pixel scale: `NSScreen.mainScreen.backingScaleFactor` (typically `2`). Controller buffers are in **pixels**, status-item size in **points** (44×22 and 240×120).

**6.** `controller := TEyesController.Create(barW, barH, deskW, deskH)`:

- `TEyesModel.Create` — `Randomize`, `FLid = 1`, first blink in 1–3 s
- `Bar` / `Desk` `TPixelBuffer`s allocated (RGBA, zeroed later by `Clear`)
- `ShowDesktop := True` on the Cocoa host so the floating window is offered immediately

**7.** Menu items target the delegate: `toggleDesktopAction:`, `aboutAction:`, `quitAction:`.

**8.** Status item:

```pascal
statusItem := NSStatusBar.systemStatusBar.statusItemWithLength(BarPointsW);
statusItem.retain;
statusItem.setMenu(Menu);
statusItem.button.setImagePosition(NSImageOnly);
```

No title string — the extra is only the painted pair.

**9.** Desktop window: titled, closable, `NSStatusWindowLevel`, opaque platinum background, top-right of `visibleFrame`. Content view is `TEyesDeskView` (unflipped, same as the status item, so the y-down buffer is not drawn upside down). `windowShouldClose` hides rather than destroys.

**10.** Timer is armed; **first** `updateImages` + `syncDesktop` run **before** `App.run` so the extra is not blank for a frame.

```pascal
animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
  1.0 / 30.0, self, objcselector('tick:'), nil, True);
animTimer.retain;
NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);
updateImages;
syncDesktop;
```

Common modes keep `tick:` firing while the status-item menu is open.

**11.** `App.run` starts. Cocoa may also send `applicationDidFinishLaunching` → `setup` (already `ready`) → `syncDesktop` again (`orderFrontRegardless`).

---

## Phase C — per-tick update (main thread, ~30 times per second)

**12.** The timer fires → `tick:`.

**13.** A fresh `NSAutoreleasePool` wraps the tick (images created/released every frame must not accumulate).

**14.** `Dt = now - lastTick` (`NSDate.timeIntervalSinceReferenceDate`). First real interval is ~0.033 s after `setup` stamped `lastTick`.

**15.** Mouse in **screen** space: `NSEvent.mouseLocation` (origin bottom-left).

**16.** `controller.Tick(Dt, Mouse.x, Mouse.y)` → `TEyesModel.Update`:

```pascal
procedure TEyesModel.Update(Dt, MouseX, MouseY: Double);
begin
  if Dt > 0.2 then Dt := 0.2;

  Moved := hypot(MouseX - FLastMouse.X, MouseY - FLastMouse.Y);
  if Moved >= 4 then
  begin
    FIdle := 0;
    FAsleep := False;
    FDrowsy := False;
  end
  else
    FIdle := FIdle + Dt;

  { FIdle ≥ 26 → asleep, lid target 0
    FIdle ≥ 14 → drowsy, lid target 0.42
    else awake, lid target 1, and maybe start a blink }

  FLid := Smooth(FLid, FLidTarget, Speed, Dt);
end;
```

State after a tick: **idle / lids changed**; pixels on the extra have not, until the draw pass.

Windows: `GetTickCount64` and `GetCursorPos` (origin top-left).  
Linux: `g_get_current_time` and `gdk_display_get_pointer`.

---

## Phase D — per-frame draw (`updateImages` then AppKit)

**17.** `updateImages` locates the extra in screen space:

```pascal
Bounds := Btn.window.convertRectToScreen(Btn.convertRect_toView(Btn.bounds, nil));
BarCanvas := MouseToCanvas(Mouse.x, Mouse.y,
  Bounds.origin.x, Bounds.origin.y, Bounds.size.width, Bounds.size.height,
  controller.Bar.Width, controller.Bar.Height, True);
```

`FlipY=True` converts Cocoa y-up into the buffer’s y-down.

**18.** `controller.RenderBar(BarCanvas.X, BarCanvas.Y)`:

```pascal
Layout := MakeLayout(Bar.Width, Bar.Height);
Pose := Model.Pose(Vec2(MouseCanvasX, MouseCanvasY), Layout);
RenderEyes(Bar, Pose, False);
```

**19.** `Pose` calls `Track` **twice** (left eye, right eye):

```pascal
function TEyesModel.Track(const Eye, Mouse: TVec2; MaxTravel: Double): TVec2;
begin
  DX := Mouse.X - Eye.X;
  DY := Mouse.Y - Eye.Y;
  Dist := Sqrt(DX * DX + DY * DY);
  if Dist > MaxTravel then
    Scale := MaxTravel / Dist
  else
    Scale := 1.0;
  Result := Vec2(Eye.X + DX * Scale, Eye.Y + DY * Scale);
end;
```

Example: extra 88×44 px, `MaxTravel ≈ 8`. Pointer 200 px left of the extra → both pupils sit on the left rim. Pointer between the two centres, 4 px away → left pupil shifts right, right pupil shifts left (cross-eyed).

**20.** `RenderEyes`:

- `Clear(0,0,0,0)` (transparent for the extra; desktop path also `DrawBackdrop`)
- `DrawEye` left and right:
  - if `Lid < 0.12` → closed-lid arc
  - else squash sclera `OpenRY = RY * (0.16 + Lid * 0.84)`, fill cream ellipse, clip pupil + highlight, stroke outline

**21.** `MakeImage` allocates an `NSBitmapImageRep` with **nil planes** (AppKit owns the bytes), copies `Bar.Ptr` into `bitmapData`, and wraps that in a new `NSImage` (`setTemplate(False)`, `NSImageCacheNever`). The previous `barImage` is released. Do **not** alias the Pascal buffer and `recache`: the extra would stick on the first frame.

**22.** `statusItem.button.setImage(nil)` then `setImage(barImage)` + `setNeedsDisplay`. Clearing first forces AppKit to drop the cached extra. It then composites the new picture into the menu bar.

**23.** If the desktop window is showing: same Pose/render into `Desk` (with backdrop), a fresh `deskImage` snapshot, `deskView.setNeedsDisplay`. Cocoa later calls `TEyesDeskView.drawRect`, which fills platinum and `deskImage.drawInRect`.

---

## The repeating loop

```text
NSTimer (~33 ms, main thread, common modes)
  → tick:  Model.Update(dt, screenMouse)
  → updateImages:
        MouseToCanvas
        Pose (Track × 2)
        RenderEyes
        MakeImage copy → setImage(nil) / setImage
        drawRect (desktop window)
  → wait for next timer event
```

Quit: menu **Quit Eyes** → `NSApplication.terminate`. Close box on the desktop window → `ShowDesktop := False`, `orderOut`, process **keeps running** (the extra stays).

---

## Windows path (same draw loop)

`WM_TIMER` → `TickFrame`:

1. `Controller.Tick` with `GetCursorPos`.
2. `RenderBar` aiming against the virtual screen (tray geometry is not queried).
3. `CopyBGRA` + `CreateIconIndirect` + `Shell_NotifyIcon(NIM_MODIFY)`.
4. If the window is shown: `RenderDesk` from the client rect in screen space, `InvalidateRect` → `WM_PAINT` `StretchDIBits`.

The window is `WS_EX_APPWINDOW`, so it has a **taskbar** button. Right-click the tray icon for the same menu idea.

---

## Linux path (same draw loop)

`OnTick` (glib timeout):

1. `Controller.Tick` with `gdk_display_get_pointer`.
2. `gtk_status_icon_get_geometry` → `MouseToCanvas` into the panel icon; fallback assumes top-right `BarW×BarH`.
3. Copy RGBA into a `GdkPixbuf`, `gtk_status_icon_set_from_pixbuf`.
4. If the window is shown: origin via `gdk_window_get_origin`, `gtk_image_set_from_pixbuf`.

Left-click the icon toggles the desktop window. Right-click pops Desktop Eyes / About / Quit.

On Wayland, global pointer queries can fail; the desktop window still tracks if the compositor reports origin. The panel icon may rest until an X11 / XWayland session.

---

## One-line map

`begin HostRun` → `setup` (status item + timer) → **`Update` idle/lids** → **`Track` clamps pupils** → **`RenderEyes` writes RGBA** → **`MakeImage` copies a snapshot** → **`setImage` on the extra**.

Debugger: `HostRun`, `TAppDelegate.setup`, `TEyesModel.Update`, `TEyesModel.Track`, `RenderEyes`, `MakeImage`. First `tick:` already moves; there is no “stamp time only” frame like the Java savers.

See also `WORKINGS.md` for class responsibilities and the clamp / blink / sleep math in more detail.
