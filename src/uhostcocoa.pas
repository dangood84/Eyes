unit uhostcocoa;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{$linkframework Carbon}

{ macOS menu extra. Accessory policy + LSUIElement = no Dock icon.
  The pair is an NSStatusItem image, refreshed ~30 Hz from the Pascal canvas. }

interface

procedure HostRun;

implementation

uses
  SysUtils, CocoaAll, ueyesmodel, ueyesapp;

const
  BarPointsW = 44;
  BarPointsH = 22;
  DeskPointsW = 240;
  DeskPointsH = 120;

type
  TEyesDeskView = objcclass;
  TEyesDeskWindow = objcclass;
  EventHotKeyRef = Pointer;
  EventHandlerRef = Pointer;
  EventTargetRef = Pointer;
  EventHandlerCallRef = Pointer;
  EventRef = Pointer;
  EventHotKeyID = record
    signature, id: UInt32;
  end;
  EventTypeSpec = record
    eventClass, eventKind: UInt32;
  end;
  OSStatus = LongInt;

  NSBitmapImageRepEyes = objccategory external (NSBitmapImageRep)
    { FPC truncates the real method name past 127 chars; this category keeps
      a short Pascal identifier and the full ObjC selector. }
    function initRGBA(planes: Pointer; aWidth: NSInteger; aHeight: NSInteger;
      aBits: NSInteger; aSamples: NSInteger; aAlpha: ObjCBOOL;
      aPlanar: ObjCBOOL; aSpace: NSString; aBpr: NSInteger;
      aBpp: NSInteger): id; message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol, NSWindowDelegateProtocol)
  public
    controller: TEyesController;
    statusItem: NSStatusItem;
    deskWindow: TEyesDeskWindow;
    deskView: TEyesDeskView;
    barImage: NSImage;
    deskImage: NSImage;
    animTimer: NSTimer;
    scale: Double;
    lastTick: NSTimeInterval;
    ready: ObjCBOOL; { setup is called from HostRun *and* didFinishLaunching }
    procedure applicationDidFinishLaunching(notification: NSNotification); message 'applicationDidFinishLaunching:';
    procedure tick(timer: NSTimer); message 'tick:';
    procedure quitAction(sender: id); message 'quitAction:';
    procedure toggleDesktopAction(sender: id); message 'toggleDesktopAction:';
    procedure aboutAction(sender: id); message 'aboutAction:';
    function windowShouldClose(sender: id): ObjCBOOL; message 'windowShouldClose:';
    procedure syncDesktop; message 'syncDesktop';
    procedure updateImages; message 'updateImages';
    procedure setup; message 'setup';
    procedure handleDesktopShortcut; message 'handleDesktopShortcut';
  end;

  TEyesDeskWindow = objcclass(NSWindow)
  public
    app: TAppDelegate;
    function canBecomeKeyWindow: ObjCBOOL; override;
    function performKeyEquivalent(event: NSEvent): ObjCBOOL; override;
  end;

  TEyesDeskView = objcclass(NSView)
  public
    app: TAppDelegate;
    procedure drawRect(dirtyRect: NSRect); override;
    function acceptsFirstResponder: ObjCBOOL; override;
  end;

const
  kEventClassKeyboard = $6B657962; { 'keyb' }
  kEventHotKeyPressed = 5;
  CarbonCmdKey = 1 shl 8;
  CarbonShiftKey = 1 shl 9;
  kVK_ANSI_E = $0E;

function GetApplicationEventTarget: EventTargetRef; cdecl; external;
function RegisterEventHotKey(inHotKeyCode: UInt32; inHotKeyModifiers: UInt32;
  inHotKeyID: EventHotKeyID; inTarget: EventTargetRef; inOptions: UInt32;
  var outRef: EventHotKeyRef): OSStatus; cdecl; external;
function InstallEventHandler(inTarget: EventTargetRef; inHandler: Pointer;
  inNumTypes: UInt32; inList: Pointer; inUserData: Pointer;
  var outRef: EventHandlerRef): OSStatus; cdecl; external;

var
  SharedApp: TAppDelegate;
  DeskHotKey: EventHotKeyRef;
  DeskHotHandler: EventHandlerRef;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function IsDesktopShortcut(Event: NSEvent): Boolean;
var
  Chars: NSString;
  Mods: NSUInteger;
  Ch: unichar;
begin
  Result := False;
  if Event = nil then
    Exit;
  Chars := Event.charactersIgnoringModifiers;
  if (Chars = nil) or (Chars.length <> 1) then
    Exit;
  Ch := Chars.characterAtIndex(0);
  if (Ch <> Ord('e')) and (Ch <> Ord('E')) then
    Exit;
  Mods := Event.modifierFlags;
  Result := (Mods and NSCommandKeyMask <> 0) and (Mods and NSShiftKeyMask <> 0);
end;

function HotKeyHandler(nextHandler: EventHandlerCallRef; theEvent: EventRef;
  userData: Pointer): OSStatus; cdecl;
begin
  { Carbon delivers this even when we are an accessory and have no key window.
    That is how ⌘⇧E can show the pair after it has been hidden. }
  if SharedApp <> nil then
    SharedApp.handleDesktopShortcut;
  Result := 0;
end;

procedure RegisterDesktopHotKey; forward;

function MakeImage(Pixels: PByte; PixelW, PixelH: Integer; PointW, PointH: Double): NSImage;
var
  Rep: NSBitmapImageRep;
  Dest: PByte;
  Bytes: Integer;
begin
  { nil planes makes AppKit allocate its own buffer so each frame is a snapshot,
    not an alias of the Pascal canvas that NSImage would cache forever. }
  Rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initRGBA(nil, PixelW, PixelH, 8, 4,
    True, False, NSCalibratedRGBColorSpace, PixelW * 4, 32));
  Result := NSImage.alloc.initWithSize(NSMakeSize(PointW, PointH));
  if Rep <> nil then
  begin
    Dest := PByte(Rep.bitmapData);
    Bytes := PixelW * PixelH * 4;
    if (Dest <> nil) and (Pixels <> nil) and (Bytes > 0) then
      Move(Pixels^, Dest^, Bytes);
    Result.addRepresentation(Rep);
    Rep.release;
  end;
  { Template images become monochrome menu-bar glyphs; we want cream sclera. }
  Result.setTemplate(False);
  Result.setCacheMode(NSImageCacheNever);
end;

procedure TAppDelegate.updateImages;
var
  Mouse: NSPoint;
  BarCanvas, DeskCanvas: TVec2;
  Btn: NSStatusBarButton;
  Bounds: NSRect;
begin
  if (statusItem = nil) or (controller = nil) then
    Exit;
  Mouse := NSEvent.mouseLocation; { global, no Accessibility permission }
  Btn := statusItem.button;
  if (Btn <> nil) and (Btn.window <> nil) then
  begin
    Bounds := Btn.window.convertRectToScreen(Btn.convertRect_toView(Btn.bounds, nil));
    { FlipY: Cocoa y-up vs the y-down pixel buffer. }
    BarCanvas := MouseToCanvas(Mouse.x, Mouse.y, Bounds.origin.x, Bounds.origin.y,
      Bounds.size.width, Bounds.size.height, controller.Bar.Width, controller.Bar.Height, True);
  end
  else
    BarCanvas := Vec2(controller.Bar.Width * 0.5, controller.Bar.Height * 0.5);

  controller.RenderBar(BarCanvas.X, BarCanvas.Y);
  if barImage <> nil then
    barImage.release;
  barImage := MakeImage(controller.Bar.Ptr, controller.Bar.Width, controller.Bar.Height,
    BarPointsW, BarPointsH);
  if Btn <> nil then
  begin
    { Clearing first forces NSStatusItem to drop the cached extra. Reusing one
      NSImage and calling recache leaves the pair frozen on frame one. }
    Btn.setImage(nil);
    Btn.setImage(barImage);
    Btn.setNeedsDisplay_(True);
  end;

  if controller.ShowDesktop and (deskView <> nil) then
  begin
    if deskView.window <> nil then
    begin
      Bounds := deskView.window.convertRectToScreen(deskView.convertRect_toView(deskView.bounds, nil));
      DeskCanvas := MouseToCanvas(Mouse.x, Mouse.y, Bounds.origin.x, Bounds.origin.y,
        Bounds.size.width, Bounds.size.height, controller.Desk.Width, controller.Desk.Height, True);
    end
    else
      DeskCanvas := Vec2(controller.Desk.Width * 0.5, controller.Desk.Height * 0.5);
    controller.RenderDesk(DeskCanvas.X, DeskCanvas.Y);
    if deskImage <> nil then
      deskImage.release;
    deskImage := MakeImage(controller.Desk.Ptr, controller.Desk.Width, controller.Desk.Height,
      DeskPointsW, DeskPointsH);
    deskView.setNeedsDisplay_(True);
  end;
end;

procedure TAppDelegate.syncDesktop;
begin
  if deskWindow = nil then
    Exit;
  deskWindow.setLevel(NSFloatingWindowLevel);
  deskWindow.setHidesOnDeactivate(False);
  if controller.ShowDesktop then
  begin
    { Accessory apps stay inactive unless we insist; otherwise the window
      never becomes key and ⌘⇧E never reaches performKeyEquivalent. }
    NSApplication.sharedApplication.activateIgnoringOtherApps(True);
    deskWindow.makeKeyAndOrderFront(nil);
    if deskView <> nil then
      deskWindow.makeFirstResponder(deskView);
  end
  else
    deskWindow.orderOut(nil);
end;

procedure TAppDelegate.setup;
var
  Menu: NSMenu;
  Item: NSMenuItem;
  PixelScale: Double;
  Style: NSUInteger;
  Vis: NSRect;
begin
  if ready then
    Exit;
  ready := True;

  PixelScale := 2;
  if NSScreen.mainScreen <> nil then
    PixelScale := NSScreen.mainScreen.backingScaleFactor;
  if PixelScale < 1 then
    PixelScale := 1;
  scale := PixelScale;

  { Buffers are pixels; status-item size is points. }
  controller := TEyesController.Create(
    Round(BarPointsW * scale), Round(BarPointsH * scale),
    Round(DeskPointsW * scale), Round(DeskPointsH * scale));
  controller.ShowDesktop := True;

  Menu := NSMenu.alloc.init;
  { Title shows ⇧⌘E; we do not setKeyEquivalent — that is what produced the plonk. }
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Show Desktop Eyes    ⇧⌘E'), objcselector('toggleDesktopAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(NSStr('About Eyes'), objcselector('aboutAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(NSStr('Quit Eyes'), objcselector('quitAction:'), NSStr('q'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;

  statusItem := NSStatusBar.systemStatusBar.statusItemWithLength(BarPointsW);
  statusItem.retain; { statusItemWithLength may return an autoreleased item }
  statusItem.setMenu(Menu);
  if statusItem.button <> nil then
    statusItem.button.setImagePosition(NSImageOnly); { no “Eyes” title next to the pair }
  Menu.release;

  Style := NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask;
  Vis := NSMakeRect(80, 120, DeskPointsW, DeskPointsH);
  if NSScreen.mainScreen <> nil then
  begin
    Vis := NSScreen.mainScreen.visibleFrame;
    Vis := NSMakeRect(Vis.origin.x + Vis.size.width - DeskPointsW - 28,
      Vis.origin.y + Vis.size.height - DeskPointsH - 28,
      DeskPointsW, DeskPointsH);
  end;
  deskWindow := TEyesDeskWindow.alloc.initWithContentRect_styleMask_backing_defer(
    Vis, Style, NSBackingStoreBuffered, False);
  deskWindow.app := self;
  deskWindow.setTitle(NSStr('Eyes'));
  deskWindow.setLevel(NSFloatingWindowLevel); { status level often refuses to become key }
  deskWindow.setReleasedWhenClosed(False); { close box hides; we reuse this window }
  deskWindow.setHidesOnDeactivate(False);
  deskWindow.setOpaque(True);
  deskWindow.setBackgroundColor(NSColor.colorWithCalibratedRed_green_blue_alpha(0.91, 0.89, 0.85, 1.0));
  deskWindow.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces); { follow Spaces, like the extra }
  deskWindow.setDelegate(self);
  deskView := TEyesDeskView.alloc.initWithFrame(NSMakeRect(0, 0, DeskPointsW, DeskPointsH));
  deskView.app := self;
  deskWindow.setContentView(deskView);

  lastTick := NSDate.date.timeIntervalSinceReferenceDate; { stamp now so first dt is not “since 2001” }
  animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    1.0 / 30.0, self, objcselector('tick:'), nil, True);
  animTimer.retain;
  { Default mode pauses during menu tracking; common modes keep pupils moving. }
  NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);

  { Global hotkey: accessory extras have no key window once the pair is hidden. }
  RegisterDesktopHotKey;

  updateImages;
  syncDesktop;
end;

procedure TAppDelegate.applicationDidFinishLaunching(notification: NSNotification);
begin
  setup;
  syncDesktop;
end;

procedure TAppDelegate.tick(timer: NSTimer);
var
  Pool: NSAutoreleasePool;
  Now: NSTimeInterval;
  Dt: Double;
  Mouse: NSPoint;
begin
  Pool := NSAutoreleasePool.alloc.init; { 30 Hz NSImage allocs must not leak }
  Now := NSDate.date.timeIntervalSinceReferenceDate;
  Dt := Now - lastTick;
  lastTick := Now;
  Mouse := NSEvent.mouseLocation;
  controller.Tick(Dt, Mouse.x, Mouse.y); { screen space → idle / blink }
  updateImages;
  Pool.release;
end;

procedure TAppDelegate.quitAction(sender: id);
begin
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppDelegate.toggleDesktopAction(sender: id);
begin
  { Menu click: show or raise. The shortcut (handleDesktopShortcut) toggles. }
  if (not controller.ShowDesktop) or (deskWindow = nil) or (not deskWindow.isVisible) then
  begin
    controller.ShowDesktop := True;
    syncDesktop;
  end
  else
    deskWindow.makeKeyAndOrderFront(nil);
end;

procedure TAppDelegate.handleDesktopShortcut;
begin
  if controller.ShowDesktop and (deskWindow <> nil) and deskWindow.isVisible then
    controller.ShowDesktop := False
  else
    controller.ShowDesktop := True;
  syncDesktop;
end;

procedure TAppDelegate.aboutAction(sender: id);
var
  Alert: NSAlert;
begin
  Alert := NSAlert.alloc.init;
  Alert.setMessageText(NSStr(EyesAboutTitle));
  Alert.setInformativeText(NSStr(EyesAboutText));
  Alert.runModal;
  Alert.release;
end;

function TAppDelegate.windowShouldClose(sender: id): ObjCBOOL;
begin
  controller.ShowDesktop := False;
  deskWindow.orderOut(nil);
  Result := False; { hide, do not destroy — the extra stays running }
end;

procedure TEyesDeskView.drawRect(dirtyRect: NSRect);
begin
  NSColor.colorWithCalibratedRed_green_blue_alpha(0.91, 0.89, 0.85, 1.0).set_;
  NSRectFill(self.bounds);
  if (app = nil) or (app.deskImage = nil) then
    Exit;
  { Same unflipped draw as the status item. isFlipped + this older drawInRect
    stood the pair on its head (highlights under the pupils). }
  app.deskImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0);
end;

function TEyesDeskView.acceptsFirstResponder: ObjCBOOL;
begin
  Result := True;
end;

function TEyesDeskWindow.canBecomeKeyWindow: ObjCBOOL;
begin
  Result := True;
end;

function TEyesDeskWindow.performKeyEquivalent(event: NSEvent): ObjCBOOL;
begin
  { Swallow ⌘⇧E while we are key so AppKit does not beep. The Carbon hotkey
    is what toggles — doing it here as well would hide-then-show in one press. }
  Result := IsDesktopShortcut(event);
end;

procedure RegisterDesktopHotKey;
var
  Spec: EventTypeSpec;
  HotID: EventHotKeyID;
begin
  Spec.eventClass := kEventClassKeyboard;
  Spec.eventKind := kEventHotKeyPressed;
  InstallEventHandler(GetApplicationEventTarget, @HotKeyHandler, 1, @Spec, nil, DeskHotHandler);
  HotID.signature := $45594553; { 'EYES' }
  HotID.id := 1;
  RegisterEventHotKey(kVK_ANSI_E, CarbonCmdKey or CarbonShiftKey, HotID,
    GetApplicationEventTarget, 0, DeskHotKey);
end;

procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  { Accessory + Info.plist LSUIElement: menu extra only, no Dock / Cmd-Tab. }
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup; { do not wait for didFinishLaunching; extras need the item early }
  App.run;
  Pool.release;
end;

end.
