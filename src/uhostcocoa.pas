unit uhostcocoa;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

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

  NSBitmapImageRepEyes = objccategory external (NSBitmapImageRep)
    function initRGBA(planes: Pointer; aWidth: NSInteger; aHeight: NSInteger;
      aBits: NSInteger; aSamples: NSInteger; aAlpha: ObjCBOOL;
      aPlanar: ObjCBOOL; aSpace: NSString; aBpr: NSInteger;
      aBpp: NSInteger): id; message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol, NSWindowDelegateProtocol)
  public
    controller: TEyesController;
    statusItem: NSStatusItem;
    deskWindow: NSWindow;
    deskView: TEyesDeskView;
    barImage: NSImage;
    deskImage: NSImage;
    animTimer: NSTimer;
    scale: Double;
    lastTick: NSTimeInterval;
    ready: ObjCBOOL;
    procedure applicationDidFinishLaunching(notification: NSNotification); message 'applicationDidFinishLaunching:';
    procedure tick(timer: NSTimer); message 'tick:';
    procedure quitAction(sender: id); message 'quitAction:';
    procedure toggleDesktopAction(sender: id); message 'toggleDesktopAction:';
    procedure aboutAction(sender: id); message 'aboutAction:';
    function windowShouldClose(sender: id): ObjCBOOL; message 'windowShouldClose:';
    procedure syncDesktop; message 'syncDesktop';
    procedure updateImages; message 'updateImages';
    procedure setup; message 'setup';
  end;

  TEyesDeskView = objcclass(NSView)
  public
    app: TAppDelegate;
    procedure drawRect(dirtyRect: NSRect); override;
    function isFlipped: ObjCBOOL; override;
  end;

var
  SharedApp: TAppDelegate;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

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
  Mouse := NSEvent.mouseLocation;
  Btn := statusItem.button;
  if (Btn <> nil) and (Btn.window <> nil) then
  begin
    Bounds := Btn.window.convertRectToScreen(Btn.convertRect_toView(Btn.bounds, nil));
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
  deskWindow.setLevel(NSStatusWindowLevel);
  deskWindow.setHidesOnDeactivate(False);
  if controller.ShowDesktop then
    deskWindow.orderFrontRegardless
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

  controller := TEyesController.Create(
    Round(BarPointsW * scale), Round(BarPointsH * scale),
    Round(DeskPointsW * scale), Round(DeskPointsH * scale));
  controller.ShowDesktop := True;

  Menu := NSMenu.alloc.init;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(NSStr('Show Desktop Eyes'), objcselector('toggleDesktopAction:'), NSStr('d'));
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
  statusItem.retain;
  statusItem.setMenu(Menu);
  if statusItem.button <> nil then
    statusItem.button.setImagePosition(NSImageOnly);
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
  deskWindow := NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
    Vis, Style, NSBackingStoreBuffered, False);
  deskWindow.setTitle(NSStr('Eyes'));
  deskWindow.setLevel(NSStatusWindowLevel);
  deskWindow.setReleasedWhenClosed(False);
  deskWindow.setHidesOnDeactivate(False);
  deskWindow.setOpaque(True);
  deskWindow.setBackgroundColor(NSColor.colorWithCalibratedRed_green_blue_alpha(0.91, 0.89, 0.85, 1.0));
  deskWindow.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces);
  deskWindow.setDelegate(self);
  deskView := TEyesDeskView.alloc.initWithFrame(NSMakeRect(0, 0, DeskPointsW, DeskPointsH));
  deskView.app := self;
  deskWindow.setContentView(deskView);

  lastTick := NSDate.date.timeIntervalSinceReferenceDate;
  animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    1.0 / 30.0, self, objcselector('tick:'), nil, True);
  animTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);
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
  Pool := NSAutoreleasePool.alloc.init;
  Now := NSDate.date.timeIntervalSinceReferenceDate;
  Dt := Now - lastTick;
  lastTick := Now;
  Mouse := NSEvent.mouseLocation;
  controller.Tick(Dt, Mouse.x, Mouse.y);
  updateImages;
  Pool.release;
end;

procedure TAppDelegate.quitAction(sender: id);
begin
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppDelegate.toggleDesktopAction(sender: id);
begin
  if (not controller.ShowDesktop) or (deskWindow = nil) or (not deskWindow.isVisible) then
  begin
    controller.ShowDesktop := True;
    syncDesktop;
  end
  else
    deskWindow.orderFrontRegardless;
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
  Result := False;
end;

procedure TEyesDeskView.drawRect(dirtyRect: NSRect);
begin
  NSColor.colorWithCalibratedRed_green_blue_alpha(0.91, 0.89, 0.85, 1.0).set_;
  NSRectFill(self.bounds);
  if (app = nil) or (app.deskImage = nil) then
    Exit;
  app.deskImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0);
end;

function TEyesDeskView.isFlipped: ObjCBOOL;
begin
  Result := True;
end;

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

end.
