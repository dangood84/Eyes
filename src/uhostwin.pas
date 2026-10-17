unit uhostwin;

{$mode objfpc}{$H+}

{ Windows notification-area extra + optional desktop window. Same TEyesController
  as macOS / Linux; this unit only presents pixels (BGRA HICON + StretchDIBits).
  Windows has no status-item bounds. We aim through one icon tile (GetRect if
  it is actually a tile; otherwise the SysPager strip, never the clock). }

interface

procedure HostRun;

implementation

{$IFDEF WINDOWS}

uses
  Windows, Messages, SysUtils, ueyesmodel, ueyesrender, ueyesapp;

const
  AppName = 'EyesClassicPtr';
  CmdDesktop = 1001;
  CmdAbout = 1002;
  CmdQuit = 1003;
  TrayId = 1;
  WM_TRAY = WM_APP + 1;
  { FPC's Windows unit does not publish these shell32 tray flags. }
  NIM_ADD = 0;
  NIM_MODIFY = 1;
  NIM_DELETE = 2;
  NIF_MESSAGE = 1;
  NIF_ICON = 2;
  NIF_TIP = 4;
  BarW = 48; { same wide pair as the Linux extra }
  BarH = 24;
  DeskW = 240;
  DeskH = 120;
  DeskBack = (218 shl 16) or (228 shl 8) or 232; { platinum, same as RenderEyes }
  ABM_GETTASKBARPOS = 5;
  ABE_LEFT = 0;
  ABE_TOP = 1;
  ABE_RIGHT = 2;
  ABE_BOTTOM = 3;

type
  TAppBarData = record
    cbSize: DWORD;
    hWnd: HWND;
    uCallbackMessage: UINT;
    uEdge: UINT;
    rc: TRect;
    lParam: LPARAM;
  end;

  { Named A struct so we do not hit Shell_NotifyIcon A/W overloads. }
  TTrayIconData = record
    cbSize: DWORD;
    hWnd: HWND;
    uID: UINT;
    uFlags: UINT;
    uCallbackMessage: UINT;
    hIcon: HICON;
    szTip: array[0..127] of AnsiChar;
  end;

  { Packed to the SDK layout. A default-aligned record is 32 or 40 bytes on
    Win64; Shell_NotifyIconGetRect wants 28 (x86) or 36 (x64) and otherwise
    fails, after which we aimed at the clock and could not look right. }
  TNotifyIconIdentifier = packed record
    cbSize: DWORD;
{$IFDEF CPU64}
    PadHwnd: DWORD;
{$ENDIF}
    hWnd: HWND;
    uID: UINT;
    guidItem: TGUID;
  end;

function SHAppBarMessage(dwMessage: DWORD; var pData: TAppBarData): UINT; stdcall;
  external 'shell32.dll' name 'SHAppBarMessage';
function Shell_NotifyIconA(dwMessage: DWORD; var data: TTrayIconData): BOOL; stdcall;
  external 'shell32.dll' name 'Shell_NotifyIconA';
function Shell_NotifyIconGetRect(const identifier: TNotifyIconIdentifier;
  var iconLocation: TRect): HRESULT; stdcall;
  external 'shell32.dll' name 'Shell_NotifyIconGetRect';
function EyesSetProcessDPIAware: BOOL; stdcall; external 'user32.dll' name 'SetProcessDPIAware';

var
  Controller: TEyesController;
  MainWnd: HWND;
  TrayIcon: HICON;
  TrayAdded: Boolean;
  LastTick: QWord;
  BgraBar: array of Byte;
  BgraDesk: array of Byte;

function MousePos: TPoint;
begin
  if not GetCursorPos(Result) then
  begin
    Result.X := 0;
    Result.Y := 0;
  end;
end;

function CreateIconFromBuffer(Buf: TPixelBuffer): HICON;
var
  Info: BITMAPINFO;
  Bits: Pointer;
  DC: HDC;
  Dib: HBITMAP;
  Mask: HBITMAP;
  IconInfo: TIconInfo;
  Bgra: array of Byte;
  MaskBits: array of Byte;
  RowBytes, X, Y, Alpha: Integer;
begin
  Result := 0;
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  Info.bmiHeader.biWidth := Buf.Width;
  Info.bmiHeader.biHeight := Buf.Height; { positive = bottom-up, matches the AND mask DDB }
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;
  SetLength(Bgra, Buf.Width * Buf.Height * 4);
  CopyBGRA(Buf, @Bgra[0]);
  { DDBs and CreateIconIndirect are bottom-up. A top-down colour DIB with a
    top-down mask punches the AND bits through the wrong half of the pair —
    one pupil looks fine, the other looks inverted. }
  RowBytes := ((Buf.Width + 15) div 16) * 2;
  SetLength(MaskBits, RowBytes * Buf.Height);
  if Length(MaskBits) > 0 then
    FillChar(MaskBits[0], Length(MaskBits), 0);
  for Y := 0 to Buf.Height - 1 do
    for X := 0 to Buf.Width - 1 do
    begin
      Alpha := Buf.Ptr[(Y * Buf.Width + X) * 4 + 3];
      if Alpha < 16 then
        MaskBits[(Buf.Height - 1 - Y) * RowBytes + X div 8] :=
          MaskBits[(Buf.Height - 1 - Y) * RowBytes + X div 8] or Byte($80 shr (X and 7));
    end;
  DC := GetDC(0);
  Bits := nil;
  Dib := CreateDIBSection(DC, Info, DIB_RGB_COLORS, Bits, 0, 0);
  if (Dib <> 0) and (Bits <> nil) then
    for Y := 0 to Buf.Height - 1 do
      Move(Bgra[Y * Buf.Width * 4],
        PByte(Bits)[(Buf.Height - 1 - Y) * Buf.Width * 4],
        Buf.Width * 4);
  Mask := CreateBitmap(Buf.Width, Buf.Height, 1, 1, @MaskBits[0]);
  FillChar(IconInfo, SizeOf(IconInfo), 0);
  IconInfo.fIcon := True;
  IconInfo.hbmMask := Mask;
  IconInfo.hbmColor := Dib;
  Result := CreateIconIndirect(IconInfo);
  if Dib <> 0 then
    DeleteObject(Dib);
  if Mask <> 0 then
    DeleteObject(Mask);
  ReleaseDC(0, DC);
end;

procedure FillTray(var Nid: TTrayIconData; Wnd: HWND);
begin
  FillChar(Nid, SizeOf(Nid), 0);
  Nid.cbSize := SizeOf(Nid);
  Nid.hWnd := Wnd;
  Nid.uID := TrayId;
end;

procedure ApplyTrayIcon(Wnd: HWND; Icon: HICON);
var
  Nid: TTrayIconData;
  Prev: HICON;
begin
  if Icon = 0 then
    Exit;
  Prev := TrayIcon;
  FillTray(Nid, Wnd);
  Nid.hIcon := Icon;
  if TrayAdded then
  begin
    Nid.uFlags := NIF_ICON;
    Shell_NotifyIconA(NIM_MODIFY, Nid);
  end
  else
  begin
    Nid.uFlags := NIF_MESSAGE or NIF_ICON or NIF_TIP;
    Nid.uCallbackMessage := WM_TRAY;
    lstrcpynA(Nid.szTip, 'Eyes', 127);
    TrayAdded := Shell_NotifyIconA(NIM_ADD, Nid);
  end;
  TrayIcon := Icon;
  if (Prev <> 0) and (Prev <> Icon) then
    DestroyIcon(Prev);
end;

procedure RemoveTray(Wnd: HWND);
var
  Nid: TTrayIconData;
begin
  if not TrayAdded then
    Exit;
  FillTray(Nid, Wnd);
  Shell_NotifyIconA(NIM_DELETE, Nid);
  TrayAdded := False;
end;

procedure PaintDesk(Wnd: HWND);
var
  PS: PAINTSTRUCT;
  DC: HDC;
  Info: BITMAPINFO;
  R: TRect;
  Brush: HBRUSH;
begin
  DC := BeginPaint(Wnd, @PS);
  GetClientRect(Wnd, @R);
  Brush := CreateSolidBrush(DeskBack);
  FillRect(DC, R, Brush);
  DeleteObject(Brush);
  if Length(BgraDesk) = Controller.Desk.Width * Controller.Desk.Height * 4 then
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
    Info.bmiHeader.biWidth := Controller.Desk.Width;
    Info.bmiHeader.biHeight := -Controller.Desk.Height; { same top-down DIB as the icon }
    Info.bmiHeader.biPlanes := 1;
    Info.bmiHeader.biBitCount := 32;
    Info.bmiHeader.biCompression := BI_RGB;
    StretchDIBits(DC, 0, 0, R.Right - R.Left, R.Bottom - R.Top,
      0, 0, Controller.Desk.Width, Controller.Desk.Height,
      @BgraDesk[0], Info, DIB_RGB_COLORS, SRCCOPY);
  end;
  EndPaint(Wnd, @PS);
end;

procedure ShowAbout(Wnd: HWND);
begin
  MessageBox(Wnd, PChar(EyesAboutText), EyesAboutTitle, MB_OK or MB_ICONINFORMATION);
end;

procedure PopupMenuAtCursor(Wnd: HWND);
var
  Menu: HMENU;
  Pt: TPoint;
begin
  Menu := CreatePopupMenu;
  AppendMenu(Menu, MF_STRING, CmdDesktop, PChar('Desktop Eyes'#9'Ctrl+Shift+E'));
  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, CmdAbout, PChar('About Eyes'));
  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, CmdQuit, PChar('Quit Eyes'));
  GetCursorPos(Pt);
  SetForegroundWindow(Wnd); { without this, a tray popup often vanishes on the first click }
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, Wnd, nil);
  DestroyMenu(Menu);
end;

procedure SyncDesktop(Wnd: HWND);
begin
  if Controller.ShowDesktop then
  begin
    ShowWindow(Wnd, SW_SHOW);
    SetWindowPos(Wnd, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end
  else
    ShowWindow(Wnd, SW_HIDE); { extra stays; same as orderOut / gtk_widget_hide }
end;

function ClientScreenRect(Wnd: HWND): TRect;
begin
  GetClientRect(Wnd, @Result);
  ClientToScreen(Wnd, PPoint(@Result.Left)^);
  ClientToScreen(Wnd, PPoint(@Result.Right)^);
end;

function IsIconSized(const R: TRect): Boolean;
var
  Wd, Ht: Integer;
begin
  Wd := R.Right - R.Left;
  Ht := R.Bottom - R.Top;
  { One extra is a squat tile. The clock, notify cluster, or whole taskbar
    are hundreds of pixels wide — mapping through those keeps the pupils
    left of centre when the pointer is already right of the eyes. }
  Result := (Wd >= 8) and (Ht >= 8) and (Wd <= 64) and (Ht <= 64);
end;

procedure TightIconBox(var R: TRect);
var
  Wd, Ht, Side: Integer;
begin
  if IsIconSized(R) then
    Exit;
  Wd := R.Right - R.Left;
  Ht := R.Bottom - R.Top;
  Side := Ht;
  if Wd < Ht then
    Side := Wd;
  if Side < 16 then
    Side := 16;
  if Side > 40 then
    Side := 40;
  { Wide band: icons sit on the left, clock on the right. A box flush with
    the right edge is the clock, so “pointer right of the tray” still aims
    left of the view. }
  if Wd >= Ht then
  begin
    R.Right := R.Left + Side;
    R.Top := R.Top + (Ht - Side) div 2;
    R.Bottom := R.Top + Side;
  end
  else
  begin
    R.Bottom := R.Top + Side;
    R.Left := R.Left + (Wd - Side) div 2;
    R.Right := R.Left + Side;
  end;
end;

function ExtraRect(Wnd: HWND; out R: TRect): Boolean;
var
  Id: TNotifyIconIdentifier;
begin
  FillChar(Id, SizeOf(Id), 0);
  Id.cbSize := SizeOf(Id);
  Id.hWnd := Wnd;
  Id.uID := TrayId;
  Result := (Shell_NotifyIconGetRect(Id, R) = S_OK) and IsIconSized(R);
end;

function NotifyBandRect(out R: TRect): Boolean;
var
  Tray, Notify, Pager, Tool: HWND;
begin
  { SysPager is the icon strip only — not the clock to its right. }
  Result := False;
  Tray := FindWindow('Shell_TrayWnd', nil);
  if Tray = 0 then
    Exit;
  Notify := FindWindowEx(Tray, 0, 'TrayNotifyWnd', nil);
  if Notify = 0 then
    Exit;
  Pager := FindWindowEx(Notify, 0, 'SysPager', nil);
  Tool := 0;
  if Pager <> 0 then
    Tool := FindWindowEx(Pager, 0, 'ToolbarWindow32', nil);
  if Tool = 0 then
    Tool := FindWindowEx(Notify, 0, 'ToolbarWindow32', nil);
  if Tool <> 0 then
    Result := GetWindowRect(Tool, R)
  else if Pager <> 0 then
    Result := GetWindowRect(Pager, R)
  else
    Result := GetWindowRect(Notify, R);
end;

function FallbackExtraRect: TRect;
var
  Data: TAppBarData;
  Side, Inset: Integer;
begin
  if NotifyBandRect(Result) then
  begin
    TightIconBox(Result);
    Exit;
  end;
  FillChar(Data, SizeOf(Data), 0);
  Data.cbSize := SizeOf(Data);
  if SHAppBarMessage(ABM_GETTASKBARPOS, Data) <> 0 then
    Result := Data.rc
  else
  begin
    Result.Left := 0;
    Result.Top := 0;
    Result.Right := GetSystemMetrics(SM_CXSCREEN);
    Result.Bottom := GetSystemMetrics(SM_CYSCREEN);
    Data.uEdge := ABE_BOTTOM;
  end;
  Side := 24;
  Inset := 72; { skip the clock / Show Desktop sliver }
  case Data.uEdge of
    ABE_LEFT:
      begin
        Result.Top := Result.Bottom - Inset - Side;
        Result.Bottom := Result.Top + Side;
        Result.Right := Result.Left + Side;
      end;
    ABE_TOP:
      begin
        Result.Left := Result.Right - Inset - Side;
        Result.Right := Result.Left + Side;
        Result.Bottom := Result.Top + Side;
      end;
    ABE_RIGHT:
      begin
        Result.Top := Result.Bottom - Inset - Side;
        Result.Bottom := Result.Top + Side;
        Result.Left := Result.Right - Side;
      end;
    else
      begin
        Result.Left := Result.Right - Inset - Side;
        Result.Right := Result.Left + Side;
        Result.Top := Result.Bottom - Side;
      end;
  end;
end;

function AimBarCanvas(Wnd: HWND; const Mouse: TPoint): TVec2;
var
  R: TRect;
begin
  { Windows has no status-item bounds. Use the icon tile only — never the
    taskbar, the clock, or the whole notify cluster. }
  if not ExtraRect(Wnd, R) then
    R := FallbackExtraRect;
  TightIconBox(R);
  Result := MouseToCanvas(Mouse.X, Mouse.Y, R.Left, R.Top,
    R.Right - R.Left, R.Bottom - R.Top,
    Controller.Bar.Width, Controller.Bar.Height, False);
end;

function AimDeskCanvas(Wnd: HWND; const Mouse: TPoint): TVec2;
var
  R: TRect;
begin
  R := ClientScreenRect(Wnd);
  Result := MouseToCanvas(Mouse.X, Mouse.Y, R.Left, R.Top,
    R.Right - R.Left, R.Bottom - R.Top,
    Controller.Desk.Width, Controller.Desk.Height, False);
end;

procedure TickFrame(Wnd: HWND);
var
  NowTick: QWord;
  Dt: Double;
  Mouse: TPoint;
  Canvas: TVec2;
  Icon: HICON;
begin
  NowTick := GetTickCount64;
  Dt := (NowTick - LastTick) / 1000.0;
  LastTick := NowTick;
  Mouse := MousePos;
  Controller.Tick(Dt, Mouse.X, Mouse.Y);

  Canvas := AimBarCanvas(Wnd, Mouse);
  Controller.RenderBar(Canvas.X, Canvas.Y);

  SetLength(BgraBar, Controller.Bar.Width * Controller.Bar.Height * 4);
  CopyBGRA(Controller.Bar, @BgraBar[0]);
  Icon := CreateIconFromBuffer(Controller.Bar);
  ApplyTrayIcon(Wnd, Icon);

  if Controller.ShowDesktop then
  begin
    Canvas := AimDeskCanvas(Wnd, Mouse);
    Controller.RenderDesk(Canvas.X, Canvas.Y);
    SetLength(BgraDesk, Controller.Desk.Width * Controller.Desk.Height * 4);
    CopyBGRA(Controller.Desk, @BgraDesk[0]);
    InvalidateRect(Wnd, nil, False); { WM_PAINT will StretchDIBits; erase=False avoids flicker }
  end;
end;

function WndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_CREATE:
      begin
        LastTick := GetTickCount64;
        SetTimer(Wnd, 1, 33, nil); { ~30 FPS, same cadence as the Cocoa NSTimer }
        AppendMenu(GetSystemMenu(Wnd, False), MF_SEPARATOR, 0, nil);
        AppendMenu(GetSystemMenu(Wnd, False), MF_STRING, CmdDesktop, PChar('Desktop Eyes'#9'Ctrl+Shift+E'));
        AppendMenu(GetSystemMenu(Wnd, False), MF_STRING, CmdAbout, PChar('About Eyes'));
        AppendMenu(GetSystemMenu(Wnd, False), MF_STRING, CmdQuit, PChar('Quit Eyes'));
      end;
    WM_TIMER:
      TickFrame(Wnd);
    WM_PAINT:
      PaintDesk(Wnd);
    WM_SIZE:
      if WParam = SIZE_MINIMIZED then
      begin
        Controller.ShowDesktop := False;
        SyncDesktop(Wnd);
      end
      else if (WParam = SIZE_RESTORED) or (WParam = SIZE_MAXIMIZED) then
        Controller.ShowDesktop := True;
    WM_CONTEXTMENU:
      PopupMenuAtCursor(Wnd);
    WM_TRAY:
      if (LParam = WM_RBUTTONUP) or (LParam = WM_CONTEXTMENU) then
        PopupMenuAtCursor(Wnd)
      else if LParam = WM_LBUTTONUP then
      begin
        Controller.ToggleDesktop;
        SyncDesktop(Wnd);
      end;
    WM_KEYDOWN:
      { Accelerator table is the real path; this catches the same chord if focus is here. }
      if (WParam = Ord('E')) and (GetKeyState(VK_CONTROL) < 0) and (GetKeyState(VK_SHIFT) < 0) then
      begin
        Controller.ToggleDesktop;
        SyncDesktop(Wnd);
      end;
    WM_SYSCOMMAND:
      case LOWORD(WParam) of
        CmdDesktop:
          begin
            Controller.ToggleDesktop;
            SyncDesktop(Wnd);
          end;
        CmdAbout:
          ShowAbout(Wnd);
        CmdQuit:
          PostQuitMessage(0);
        else
          Result := DefWindowProc(Wnd, Msg, WParam, LParam);
      end;
    WM_COMMAND:
      case LOWORD(WParam) of
        CmdDesktop:
          begin
            Controller.ToggleDesktop;
            SyncDesktop(Wnd);
          end;
        CmdAbout:
          ShowAbout(Wnd);
        CmdQuit:
          PostQuitMessage(0);
      end;
    WM_CLOSE:
      begin
        Controller.ShowDesktop := False;
        SyncDesktop(Wnd);
      end;
    WM_DESTROY:
      begin
        KillTimer(Wnd, 1);
        RemoveTray(Wnd);
        if TrayIcon <> 0 then
          DestroyIcon(TrayIcon);
        TrayIcon := 0;
        PostQuitMessage(0);
      end;
    else
      Result := DefWindowProc(Wnd, Msg, WParam, LParam);
  end;
end;

procedure HostRun;
var
  WC: WNDCLASS;
  Msg: TMsg;
  ScreenW, ScreenH: Integer;
  HotAccel: TACCEL; { not Accel: ACCEL — Pascal identifiers are case-blind }
  AccelTable: HACCEL;
begin
  EyesSetProcessDPIAware; { GetCursorPos and GetRect must share one pixel space }
  Controller := TEyesController.Create(BarW, BarH, DeskW * 2, DeskH * 2);
  Controller.ShowDesktop := True;

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @WndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := CreateSolidBrush(DeskBack);
  WC.lpszClassName := AppName;
  RegisterClass(WC);

  ScreenW := GetSystemMetrics(SM_CXSCREEN);
  ScreenH := GetSystemMetrics(SM_CYSCREEN);
  MainWnd := CreateWindowEx(WS_EX_APPWINDOW or WS_EX_TOPMOST, AppName, 'Eyes',
    WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX,
    ScreenW - DeskW - 40, ScreenH - DeskH - 80, DeskW + 16, DeskH + 40,
    0, 0, HInstance, nil);

  SyncDesktop(MainWnd);
  ShowWindow(MainWnd, SW_SHOW);
  UpdateWindow(MainWnd);
  TickFrame(MainWnd); { first tray icon before the timer }

  FillChar(HotAccel, SizeOf(HotAccel), 0);
  HotAccel.fVirt := FCONTROL or FSHIFT or FVIRTKEY;
  HotAccel.key := Ord('E');
  HotAccel.cmd := CmdDesktop;
  AccelTable := CreateAcceleratorTable(@HotAccel, 1);

  while GetMessage(Msg, 0, 0, 0) do
  begin
    if (AccelTable = 0) or (TranslateAccelerator(MainWnd, AccelTable, Msg) = 0) then
    begin
      TranslateMessage(Msg);
      DispatchMessage(Msg);
    end;
  end;
  if AccelTable <> 0 then
    DestroyAcceleratorTable(AccelTable);
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
