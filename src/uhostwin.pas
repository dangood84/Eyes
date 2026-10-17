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
  Windows, Messages, SysUtils, Variants, ActiveX, ueyesmodel, ueyesrender, ueyesapp;

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
  ABM_GETTASKBARPOS = 5;
  OBJID_CLIENT = DWORD($FFFFFFFC);
  IID_IAccessible: TGUID = '{618736E0-3C3D-11CF-810C-00AA00389B71}';

type
  TAppBarData = record
    cbSize: DWORD;
    hWnd: HWND;
    uCallbackMessage: UINT;
    uEdge: UINT;
    rc: TRect;
    lParam: LPARAM;
  end;

  IAccessible = interface(IDispatch)
    ['{618736E0-3C3D-11CF-810C-00AA00389B71}']
    function Get_accParent(out ppdispParent: IDispatch): HRESULT; stdcall;
    function Get_accChildCount(out pcountChildren: Integer): HRESULT; stdcall;
    function Get_accChild(varChild: OleVariant; out ppdispChild: IDispatch): HRESULT; stdcall;
    function Get_accName(varChild: OleVariant; out pszName: WideString): HRESULT; stdcall;
    function Get_accValue(varChild: OleVariant; out pszValue: WideString): HRESULT; stdcall;
    function Get_accDescription(varChild: OleVariant; out pszDescription: WideString): HRESULT; stdcall;
    function Get_accRole(varChild: OleVariant; out pvarRole: OleVariant): HRESULT; stdcall;
    function Get_accState(varChild: OleVariant; out pvarState: OleVariant): HRESULT; stdcall;
    function Get_accHelp(varChild: OleVariant; out pszHelp: WideString): HRESULT; stdcall;
    function Get_accHelpTopic(out pszHelpFile: WideString; varChild: OleVariant; out pidTopic: Integer): HRESULT; stdcall;
    function Get_accKeyboardShortcut(varChild: OleVariant; out pszKeyboardShortcut: WideString): HRESULT; stdcall;
    function Get_accFocus(out pvarChild: OleVariant): HRESULT; stdcall;
    function Get_accSelection(out pvarChildren: OleVariant): HRESULT; stdcall;
    function Get_accDefaultAction(varChild: OleVariant; out pszDefaultAction: WideString): HRESULT; stdcall;
    function accSelect(flagsSelect: Integer; varChild: OleVariant): HRESULT; stdcall;
    function accLocation(out pxLeft: Integer; out pyTop: Integer; out pcxWidth: Integer;
      out pcyHeight: Integer; varChild: OleVariant): HRESULT; stdcall;
    function accNavigate(navDir: Integer; varStart: OleVariant; out pvarEndUpAt: OleVariant): HRESULT; stdcall;
    function accHitTest(xLeft: Integer; yTop: Integer; out pvarChild: OleVariant): HRESULT; stdcall;
    function accDoDefaultAction(varChild: OleVariant): HRESULT; stdcall;
    function Set_accName(varChild: OleVariant; const pszName: WideString): HRESULT; stdcall;
    function Set_accValue(varChild: OleVariant; const pszValue: WideString): HRESULT; stdcall;
  end;

function SHAppBarMessage(dwMessage: DWORD; var pData: TAppBarData): UINT; stdcall;
  external 'shell32.dll' name 'SHAppBarMessage';
function AccessibleObjectFromWindow(hwnd: HWND; dwObjectID: DWORD; const riid: TGUID;
  out ppvObject): HRESULT; stdcall; external 'oleacc.dll' name 'AccessibleObjectFromWindow';

var
  Controller: TEyesController;
  MainWnd: HWND;
  TaskIcon: HICON;
  LastTick: QWord;
  BgraBar: array of Byte;
  BgraDesk: array of Byte;
  CachedBtn: TRect;
  CachedBtnAt: QWord;
  HaveCachedBtn: Boolean;

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

function FindDescendantClass(Parent: HWND; const Cls: string): HWND;
var
  Child: HWND;
begin
  Result := FindWindowEx(Parent, 0, PChar(Cls), nil);
  if Result <> 0 then
    Exit;
  Child := GetWindow(Parent, GW_CHILD);
  while Child <> 0 do
  begin
    Result := FindDescendantClass(Child, Cls);
    if Result <> 0 then
      Exit;
    Child := GetWindow(Child, GW_HWNDNEXT);
  end;
end;

function AccName(Acc: IAccessible; Child: Integer): string;
var
  V: OleVariant;
  W: WideString;
begin
  Result := '';
  V := Child;
  if (Acc.Get_accName(V, W) = S_OK) and (W <> '') then
    Result := W;
end;

function AccRect(Acc: IAccessible; Child: Integer; out R: TRect): Boolean;
var
  V: OleVariant;
  Lft, Tp, Wd, Ht: Integer;
begin
  Result := False;
  V := Child;
  if Acc.accLocation(Lft, Tp, Wd, Ht, V) <> S_OK then
    Exit;
  if (Wd < 4) or (Ht < 4) then
    Exit;
  { Windows.Rect is a type, not SysUtils.Rect(). }
  R.Left := Lft;
  R.Top := Tp;
  R.Right := Lft + Wd;
  R.Bottom := Tp + Ht;
  Result := True;
end;

function TitleMatchesButton(const Title, Button: string): Boolean;
begin
  Result := (Button <> '') and ((CompareText(Title, Button) = 0) or
    (Pos(AnsiLowerCase(Title), AnsiLowerCase(Button)) = 1));
end;

function FindNamedAccRect(Acc: IAccessible; const Title: string; out R: TRect): Boolean;
var
  Count, I: Integer;
  ChildDisp: IDispatch;
  ChildAcc: IAccessible;
  V: OleVariant;
begin
  Result := False;
  if (Acc = nil) or (Title = '') then
    Exit;
  if Acc.Get_accChildCount(Count) <> S_OK then
    Count := 0;
  for I := 1 to Count do
  begin
    if TitleMatchesButton(Title, AccName(Acc, I)) and AccRect(Acc, I, R) then
    begin
      Result := True;
      Exit;
    end;
    V := I;
    ChildDisp := nil;
    if (Acc.Get_accChild(V, ChildDisp) = S_OK) and (ChildDisp <> nil) and
       (ChildDisp.QueryInterface(IAccessible, ChildAcc) = S_OK) then
      if FindNamedAccRect(ChildAcc, Title, R) then
      begin
        Result := True;
        Exit;
      end;
  end;
end;

function TaskbarButtonRect(AppWnd: HWND; out R: TRect): Boolean;
var
  Tray, List: HWND;
  AccUnk: IUnknown;
  Acc: IAccessible;
  Title: array[0..255] of Char;
  Abd: TAppBarData;
  ListR: TRect;
  Thick: Integer;
begin
  if HaveCachedBtn and (GetTickCount64 - CachedBtnAt < 500) then
  begin
    R := CachedBtn;
    Result := True;
    Exit;
  end;
  Result := False;
  Tray := FindWindow('Shell_TrayWnd', nil);
  List := 0;
  if Tray <> 0 then
    List := FindDescendantClass(Tray, 'MSTaskListWClass');
  if (List <> 0) and (AccessibleObjectFromWindow(List, OBJID_CLIENT, IID_IAccessible, AccUnk) = S_OK) and
     (AccUnk <> nil) and (AccUnk.QueryInterface(IAccessible, Acc) = S_OK) then
  begin
    FillChar(Title, SizeOf(Title), 0);
    GetWindowText(AppWnd, Title, 255);
    Result := FindNamedAccRect(Acc, string(Title), R);
  end;
  if Result then
  begin
    InflateRect(R, 2, 2);
    CachedBtn := R;
    CachedBtnAt := GetTickCount64;
    HaveCachedBtn := True;
    Exit;
  end;
  { Fallback: a square on the taskbar so Y is “up from the bar”, not the
    whole desktop (which makes a pointer above the icon look left/down). }
  FillChar(Abd, SizeOf(Abd), 0);
  Abd.cbSize := SizeOf(Abd);
  if SHAppBarMessage(ABM_GETTASKBARPOS, Abd) = 0 then
    Exit;
  if (List <> 0) and GetWindowRect(List, ListR) then
    R := ListR
  else
    R := Abd.rc;
  Thick := R.Bottom - R.Top;
  if (R.Right - R.Left) < Thick then
    Thick := R.Right - R.Left;
  if Thick < 24 then
    Thick := 40;
  if Abd.uEdge in [0, 2] then { left / right bar: pin a square at the top of the strip }
  begin
    R.Bottom := R.Top + Thick;
    R.Right := R.Left + Thick;
  end
  else
  begin
    R.Right := R.Left + Thick;
    R.Bottom := R.Top + Thick;
  end;
  CachedBtn := R;
  CachedBtnAt := GetTickCount64;
  HaveCachedBtn := True;
  Result := True;
end;

function AimDeskCanvas(Wnd: HWND; const Mouse: TPoint): TVec2;
var
  R: TRect;
begin
  R := ClientScreenRect(Wnd);
  Result := MouseToCanvas(Mouse.X, Mouse.Y, R.Left, R.Top,
    R.Right - R.Left, R.Bottom - R.Top, Controller.Desk.Width, Controller.Desk.Height, False);
end;

function AimBarCanvas(Wnd: HWND; const Mouse: TPoint): TVec2;
var
  R: TRect;
begin
  { The extra lives on the taskbar button. Aiming at the desktop window (or
    the whole screen) makes a pointer above the icon look “side on to the left”. }
  if TaskbarButtonRect(Wnd, R) then
    Result := MouseToCanvas(Mouse.X, Mouse.Y, R.Left, R.Top,
      R.Right - R.Left, R.Bottom - R.Top, Controller.Bar.Width, Controller.Bar.Height, False)
  else
    Result := MouseToCanvas(Mouse.X, Mouse.Y, 0, 0,
      GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
      Controller.Bar.Width, Controller.Bar.Height, False);
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
  ApplyTaskIcon(Wnd, Icon); { taskbar button, not the overflow chevron }

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
  CoInitialize(nil); { IAccessible walk of the taskbar button }
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
  CoUninitialize;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
