unit uhostgtk;

{$mode objfpc}{$H+}

{ Linux panel extra (GtkStatusIcon) + optional window. Same TEyesController;
  FPC's gtk2 unit often omits status-icon symbols, so they are cdecl externals. }

interface

procedure HostRun;

implementation

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}

uses
  SysUtils, ctypes, gtk2, gdk2, gdk2pixbuf, glib2, ueyesmodel, ueyesrender, ueyesapp;

type
  PGtkStatusIcon = Pointer;

function gtk_status_icon_new: PGtkStatusIcon; cdecl; external;
{ Not always in the FPC gtk2 ppu; the linker still finds them in libgtk-x11-2.0. }
procedure gtk_status_icon_set_from_pixbuf(icon: PGtkStatusIcon; pixbuf: PGdkPixbuf); cdecl; external;
procedure gtk_status_icon_set_visible(icon: PGtkStatusIcon; visible: gboolean); cdecl; external;
procedure gtk_status_icon_set_tooltip_text(icon: PGtkStatusIcon; text: Pgchar); cdecl; external;
function gtk_widget_get_window(widget: PGtkWidget): PGdkWindow; cdecl; external;
function gtk_status_icon_get_geometry(icon: PGtkStatusIcon; screen: Pointer;
  area: Pointer; orientation: Pointer): gboolean; cdecl; external;

const
  BarW = 48;
  BarH = 24;
  DeskW = 240;
  DeskH = 120;

var
  Controller: TEyesController;
  StatusIcon: PGtkStatusIcon;
  DeskWin: PGtkWidget;
  DeskImage: PGtkWidget;
  BarPix, DeskPix: PGdkPixbuf;
  LastTick: GTimeVal;
  HaveTick: Boolean;

procedure PixbufFromBuffer(Pix: PGdkPixbuf; Buf: TPixelBuffer);
var
  Pixels: PByte;
  Row: Integer;
  Src, Dst: PByte;
begin
  if Pix = nil then
    Exit;
  Pixels := PByte(gdk_pixbuf_get_pixels(Pix));
  for Row := 0 to Buf.Height - 1 do
  begin
    Src := Buf.Ptr + Row * Buf.Width * 4;
    Dst := Pixels + Row * gdk_pixbuf_get_rowstride(Pix);
    { Rowstride can be larger than width*4; copy one scanline at a time. }
    Move(Src^, Dst^, Buf.Width * 4);
  end;
end;

procedure ShowAbout(Parent: PGtkWidget);
var
  Dlg: PGtkWidget;
begin
  Dlg := gtk_message_dialog_new(PGtkWindow(Parent), GTK_DIALOG_MODAL,
    GTK_MESSAGE_INFO, GTK_BUTTONS_OK, PChar(EyesAboutText));
  gtk_window_set_title(PGtkWindow(Dlg), EyesAboutTitle);
  gtk_dialog_run(PGtkDialog(Dlg));
  gtk_widget_destroy(Dlg);
end;

procedure SyncDesktop;
begin
  if Controller.ShowDesktop then
    gtk_widget_show_all(DeskWin)
  else
    gtk_widget_hide(DeskWin);
end;

procedure OnQuit(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  gtk_main_quit;
end;

procedure OnAbout(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  ShowAbout(DeskWin);
end;

procedure OnToggleDesktop(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ToggleDesktop;
  SyncDesktop;
end;

procedure PopupMenu(Button: guint; ActivateTime: guint32);
var
  Menu, Item: PGtkWidget;
begin
  Menu := gtk_menu_new;
  Item := gtk_menu_item_new_with_label('Desktop Eyes    Ctrl+Shift+E');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnToggleDesktop), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('About Eyes');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnAbout), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Quit Eyes');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnQuit), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  gtk_widget_show_all(Menu);
  gtk_menu_popup(PGtkMenu(Menu), nil, nil, nil, nil, Button, ActivateTime);
end;

procedure OnStatusPopup(Icon: PGtkStatusIcon; Button: guint; ActivateTime: guint32; Data: gpointer); cdecl;
begin
  PopupMenu(Button, ActivateTime);
end;

procedure OnStatusActivate(Icon: PGtkStatusIcon; Data: gpointer); cdecl;
begin
  Controller.ToggleDesktop;
  SyncDesktop;
end;

procedure OnDeskDelete(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  Controller.ShowDesktop := False;
  gtk_widget_hide(Widget);
  Result := True; { stop GTK destroying the window so we can show it again }
end;

function OnDeskKey(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
const
  KeyE = $065;
  KeyShiftE = $045;
var
  Mods: guint;
begin
  Result := False;
  if Event = nil then
    Exit;
  Mods := Event^.key.state and (GDK_CONTROL_MASK or GDK_SHIFT_MASK or GDK_MOD1_MASK);
  if ((Event^.key.keyval = KeyE) or (Event^.key.keyval = KeyShiftE)) and
     (Mods = (GDK_CONTROL_MASK or GDK_SHIFT_MASK)) then
  begin
    OnToggleDesktop(Widget, Data);
    Result := True;
  end;
end;

function OnTick(Data: gpointer): gboolean; cdecl;
var
  Now: GTimeVal;
  Dt: Double;
  MX, MY: gint;
  Area: TGdkRectangle;
  Screen: PGdkScreen;
  Canvas: TVec2;
  Win: PGdkWindow;
  OX, OY: gint;
begin
  g_get_current_time(@Now);
  if not HaveTick then
  begin
    LastTick := Now; { first tick only stamps time so dt is not “since process start” }
    HaveTick := True;
    Dt := 1 / 30;
  end
  else
    Dt := (Now.tv_sec - LastTick.tv_sec) + (Now.tv_usec - LastTick.tv_usec) / 1000000.0;
  LastTick := Now;

  gdk_display_get_pointer(gdk_display_get_default, nil, @MX, @MY, nil); { may fail on Wayland }
  Controller.Tick(Dt, MX, MY);

  FillChar(Area, SizeOf(Area), 0);
  Screen := nil;
  if (StatusIcon <> nil) and gtk_status_icon_get_geometry(StatusIcon, @Screen, @Area, nil) then
    Canvas := MouseToCanvas(MX, MY, Area.x, Area.y, Area.width, Area.height,
      Controller.Bar.Width, Controller.Bar.Height, False)
  else
    { Icon not embedded yet: pretend the extra is top-right of the screen. }
    Canvas := MouseToCanvas(MX, MY, gdk_screen_get_width(gdk_screen_get_default) - BarW, 0,
      BarW, BarH, Controller.Bar.Width, Controller.Bar.Height, False);
  Controller.RenderBar(Canvas.X, Canvas.Y);
  PixbufFromBuffer(BarPix, Controller.Bar);
  gtk_status_icon_set_from_pixbuf(StatusIcon, BarPix);

  if Controller.ShowDesktop then
  begin
    Win := gtk_widget_get_window(DeskWin);
    OX := 0;
    OY := 0;
    if Win <> nil then
      gdk_window_get_origin(Win, @OX, @OY); { window origin in root coords, for MouseToCanvas }
    Canvas := MouseToCanvas(MX, MY, OX, OY, DeskW, DeskH,
      Controller.Desk.Width, Controller.Desk.Height, False);
    Controller.RenderDesk(Canvas.X, Canvas.Y);
    PixbufFromBuffer(DeskPix, Controller.Desk);
    gtk_image_set_from_pixbuf(PGtkImage(DeskImage), DeskPix);
  end;
  Result := True; { keep the timeout; False would cancel the 33 ms loop }
end;

procedure HostRun;
begin
  gtk_init(@argc, @argv); { GTK takes the real argv so --display still works }
  Controller := TEyesController.Create(BarW, BarH, DeskW * 2, DeskH * 2);
  Controller.ShowDesktop := True;

  BarPix := gdk_pixbuf_new(GDK_COLORSPACE_RGB, True, 8, Controller.Bar.Width, Controller.Bar.Height);
  DeskPix := gdk_pixbuf_new(GDK_COLORSPACE_RGB, True, 8, Controller.Desk.Width, Controller.Desk.Height);

  StatusIcon := gtk_status_icon_new;
  gtk_status_icon_set_tooltip_text(StatusIcon, 'Eyes');
  gtk_status_icon_set_visible(StatusIcon, True);
  g_signal_connect(G_OBJECT(StatusIcon), 'popup-menu', TG_SIGNAL_FUNC(@OnStatusPopup), nil);
  g_signal_connect(G_OBJECT(StatusIcon), 'activate', TG_SIGNAL_FUNC(@OnStatusActivate), nil);

  DeskWin := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(DeskWin), 'Eyes');
  gtk_window_set_default_size(PGtkWindow(DeskWin), DeskW, DeskH);
  gtk_window_set_keep_above(PGtkWindow(DeskWin), True);
  gtk_window_set_skip_taskbar_hint(PGtkWindow(DeskWin), False); { appear on the panel task list }
  DeskImage := gtk_image_new;
  gtk_container_add(PGtkContainer(DeskWin), DeskImage);
  g_signal_connect(G_OBJECT(DeskWin), 'delete-event', TG_SIGNAL_FUNC(@OnDeskDelete), nil);
  g_signal_connect(G_OBJECT(DeskWin), 'key-press-event', TG_SIGNAL_FUNC(@OnDeskKey), nil);

  g_timeout_add(33, TGSourceFunc(@OnTick), nil); { ~30 FPS, GUI thread }
  OnTick(nil); { first frame before gtk_main so the icon is not blank }
  SyncDesktop;
  gtk_main;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
