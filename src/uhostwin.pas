unit uhostwin;

{$mode objfpc}{$H+}

{ Windows tray icon + taskbar window. Same TEyesController as macOS;
  this unit only presents pixels (BGRA HICON + StretchDIBits). }

interface

procedure HostRun;

implementation

{$IFDEF WINDOWS}

uses
  Windows, Messages, ShellAPI, SysUtils, ueyesmodel, ueyesrender, ueyesapp;

const
  AppName = 'EyesClassicPtr';
  WmTray = WM_APP + 42; { not a system message; tray callback lands here }
  IdTray = 1;
  CmdDesktop = 1001;
  CmdAbout = 1002;
  CmdQuit = 1003;
  BarW = 32;
  BarH = 32;
  DeskW = 240;
  DeskH = 120;

var
  Controller: TEyesController;
  MainWnd: HWND;
  TrayIcon: NOTIFYICONDATA;
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
begin
  Result := 0;
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  Info.bmiHeader.biWidth := Buf.Width;
  Info.bmiHeader.biHeight := -Buf.Height; { negative = top-down DIB, matches our y-down buffer }
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;
  SetLength(Bgra, Buf.Width * Buf.Height * 4);
  CopyBGRA(Buf, @Bgra[0]);
  DC := GetDC(0);
  Bits := nil;
  Dib := CreateDIBSection(DC, Info, DIB_RGB_COLORS, Bits, 0, 0);
  if (Dib <> 0) and (Bits <> nil) then
    Move(Bgra[0], Bits^, Length(Bgra));
  Mask := CreateBitmap(Buf.Width, Buf.Height, 1, 1, nil);
  FillChar(IconInfo, SizeOf(IconInfo), 0);
  IconInfo.fIcon := True;
  IconInfo.hbmMask := Mask; { 1-bit mask required even for a 32-bit colour icon }
  IconInfo.hbmColor := Dib;
  Result := CreateIconIndirect(IconInfo);
  if Dib <> 0 then
    DeleteObject(Dib);
  if Mask <> 0 then
    DeleteObject(Mask);
  ReleaseDC(0, DC);
end;

procedure PaintDesk(Wnd: HWND);
var
  PS: PAINTSTRUCT;
  DC: HDC;
  Info: BITMAPINFO;
  R: TRect;
begin
  DC := BeginPaint(Wnd, @PS);
  GetClientRect(Wnd, @R);
  if Length(BgraDesk) = Controller.Desk.Width * Controller.Desk.Height * 4 then
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
    Info.bmiHeader.biWidth := Controller.Desk.Width;
    Info.bmiHeader.biHeight := -Controller.Desk.Height; { same top-down DIB as the tray icon }
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
  AppendMenu(Menu, MF_STRING, CmdDesktop, PChar('Desktop Eyes'));
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
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE); { keep the taskbar button }
  end
  else
    ShowWindow(Wnd, SW_HIDE);
end;

procedure TickFrame(Wnd: HWND);
var
  NowTick: QWord;
  Dt: Double;
  Mouse: TPoint;
  Client: TRect;
  Canvas: TVec2;
  Icon: HICON;
begin
  NowTick := GetTickCount64;
  Dt := (NowTick - LastTick) / 1000.0;
  LastTick := NowTick;
  Mouse := MousePos;
  Controller.Tick(Dt, Mouse.X, Mouse.Y);

  { Tray icons have no reliable geometry API here; aim against the virtual screen. }
  Controller.RenderBar(
    MouseToCanvas(Mouse.X, Mouse.Y, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
      Controller.Bar.Width, Controller.Bar.Height, False).X,
    MouseToCanvas(Mouse.X, Mouse.Y, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
      Controller.Bar.Width, Controller.Bar.Height, False).Y);

  SetLength(BgraBar, Controller.Bar.Width * Controller.Bar.Height * 4);
  CopyBGRA(Controller.Bar, @BgraBar[0]);
  Icon := CreateIconFromBuffer(Controller.Bar);
  if Icon <> 0 then
  begin
    if TrayIcon.hIcon <> 0 then
      DestroyIcon(TrayIcon.hIcon);
    TrayIcon.hIcon := Icon;
    Shell_NotifyIcon(NIM_MODIFY, @TrayIcon); { replacing the HICON is what animates the tray }
  end;

  if Controller.ShowDesktop then
  begin
    GetClientRect(Wnd, @Client);
    { Client is local; pupils aim in screen space, so both corners go through ClientToScreen. }
    ClientToScreen(Wnd, PPoint(@Client.Left)^);
    ClientToScreen(Wnd, PPoint(@Client.Right)^);
    Canvas := MouseToCanvas(Mouse.X, Mouse.Y, Client.Left, Client.Top,
      Client.Right - Client.Left, Client.Bottom - Client.Top,
      Controller.Desk.Width, Controller.Desk.Height, False);
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
      end;
    WM_TIMER:
      TickFrame(Wnd);
    WM_PAINT:
      PaintDesk(Wnd);
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
    WmTray:
      case LOWORD(LParam) of
        WM_RBUTTONUP, WM_CONTEXTMENU:
          PopupMenuAtCursor(Wnd);
        WM_LBUTTONDBLCLK:
          begin
            Controller.ShowDesktop := True;
            SyncDesktop(Wnd);
          end;
      end;
    WM_CLOSE:
      begin
        { Hide, do not destroy — the tray extra stays, like closing the Mac window. }
        Controller.ShowDesktop := False;
        SyncDesktop(Wnd);
      end;
    WM_DESTROY:
      begin
        KillTimer(Wnd, 1);
        Shell_NotifyIcon(NIM_DELETE, @TrayIcon);
        if TrayIcon.hIcon <> 0 then
          DestroyIcon(TrayIcon.hIcon);
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
begin
  Controller := TEyesController.Create(BarW, BarH, DeskW * 2, DeskH * 2);
  Controller.ShowDesktop := True; { Windows: window is how they appear on the taskbar }

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @WndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := GetStockObject(LTGRAY_BRUSH);
  WC.lpszClassName := AppName;
  RegisterClass(WC);

  ScreenW := GetSystemMetrics(SM_CXSCREEN);
  ScreenH := GetSystemMetrics(SM_CYSCREEN);
  MainWnd := CreateWindowEx(WS_EX_APPWINDOW or WS_EX_TOPMOST, AppName, 'Eyes',
    { APPWINDOW = taskbar button; TOOLWINDOW would hide it. }
    WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX,
    ScreenW - DeskW - 40, ScreenH - DeskH - 80, DeskW + 16, DeskH + 40,
    0, 0, HInstance, nil);

  FillChar(TrayIcon, SizeOf(TrayIcon), 0);
  TrayIcon.cbSize := SizeOf(TrayIcon);
  TrayIcon.Wnd := MainWnd;
  TrayIcon.uID := IdTray;
  TrayIcon.uFlags := NIF_MESSAGE or NIF_ICON or NIF_TIP;
  TrayIcon.uCallbackMessage := WmTray;
  TrayIcon.hIcon := LoadIcon(0, IDI_APPLICATION);
  lstrcpyn(TrayIcon.szTip, 'Eyes', 128);
  Shell_NotifyIcon(NIM_ADD, @TrayIcon);

  SyncDesktop(MainWnd);
  ShowWindow(MainWnd, SW_SHOW);
  UpdateWindow(MainWnd);

  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
