unit uhostwin;

{$mode objfpc}{$H+}

{ Windows taskbar extra + optional desktop window. Same TEyesController as
  macOS; this unit only presents pixels (BGRA HICON + StretchDIBits).
  The small pair is the window icon (always on the taskbar). A notify-area
  icon would sit under Windows 11 “Hidden icons”. }

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
  BarW = 32;
  BarH = 32;
  DeskW = 240;
  DeskH = 120;
  DeskBack = (218 shl 16) or (228 shl 8) or 232; { platinum, same as RenderEyes }

var
  Controller: TEyesController;
  MainWnd: HWND;
  TaskIcon: HICON;
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

procedure ApplyTaskIcon(Wnd: HWND; Icon: HICON);
var
  Prev: HICON;
begin
  if Icon = 0 then
    Exit;
  Prev := TaskIcon;
  SendMessage(Wnd, WM_SETICON, ICON_SMALL, LPARAM(Icon));
  SendMessage(Wnd, WM_SETICON, ICON_BIG, LPARAM(Icon));
  TaskIcon := Icon;
  if (Prev <> 0) and (Prev <> Icon) then
    DestroyIcon(Prev);
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
    ShowWindow(Wnd, SW_RESTORE); { hide was SW_HIDE, which drops the taskbar button }
    SetWindowPos(Wnd, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end
  else
    ShowWindow(Wnd, SW_MINIMIZE); { button stays; that is the Windows extra }
end;

function ClientScreenRect(Wnd: HWND): TRect;
begin
  GetClientRect(Wnd, @Result);
  ClientToScreen(Wnd, PPoint(@Result.Left)^);
  ClientToScreen(Wnd, PPoint(@Result.Right)^);
end;

function AimCanvas(Wnd: HWND; const Mouse: TPoint; CanvasW, CanvasH: Integer): TVec2;
var
  R: TRect;
begin
  { Same view as the large pair while it is up, or the two icons disagree and
    one pupil looks “inverted” next to the window. }
  if Controller.ShowDesktop and (not IsIconic(Wnd)) then
  begin
    R := ClientScreenRect(Wnd);
    Result := MouseToCanvas(Mouse.X, Mouse.Y, R.Left, R.Top,
      R.Right - R.Left, R.Bottom - R.Top, CanvasW, CanvasH, False);
  end
  else
    Result := MouseToCanvas(Mouse.X, Mouse.Y, 0, 0,
      GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
      CanvasW, CanvasH, False);
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

  Canvas := AimCanvas(Wnd, Mouse, Controller.Bar.Width, Controller.Bar.Height);
  Controller.RenderBar(Canvas.X, Canvas.Y);

  SetLength(BgraBar, Controller.Bar.Width * Controller.Bar.Height * 4);
  CopyBGRA(Controller.Bar, @BgraBar[0]);
  Icon := CreateIconFromBuffer(Controller.Bar);
  ApplyTaskIcon(Wnd, Icon); { taskbar button, not the overflow chevron }

  if Controller.ShowDesktop then
  begin
    Canvas := AimCanvas(Wnd, Mouse, Controller.Desk.Width, Controller.Desk.Height);
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
        Controller.ShowDesktop := False
      else if (WParam = SIZE_RESTORED) or (WParam = SIZE_MAXIMIZED) then
        Controller.ShowDesktop := True;
    WM_CONTEXTMENU:
      PopupMenuAtCursor(Wnd);
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
        { First close tucks the large pair (taskbar extra stays). Close while
          already iconic actually quits, so the jump-list Close still works. }
        if IsIconic(Wnd) then
          DestroyWindow(Wnd)
        else
        begin
          Controller.ShowDesktop := False;
          SyncDesktop(Wnd);
        end;
      end;
    WM_DESTROY:
      begin
        KillTimer(Wnd, 1);
        if TaskIcon <> 0 then
          DestroyIcon(TaskIcon);
        TaskIcon := 0;
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
  Controller := TEyesController.Create(BarW, BarH, DeskW * 2, DeskH * 2);
  Controller.ShowDesktop := True; { Windows: the window button is the extra }

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
    { APPWINDOW = taskbar button; TOOLWINDOW would hide it. }
    WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX,
    ScreenW - DeskW - 40, ScreenH - DeskH - 80, DeskW + 16, DeskH + 40,
    0, 0, HInstance, nil);

  SyncDesktop(MainWnd);
  ShowWindow(MainWnd, SW_SHOW);
  UpdateWindow(MainWnd);
  TickFrame(MainWnd); { first taskbar icon before the timer }

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
