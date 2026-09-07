program Eyes;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$ENDIF}

{ Eyes — classic Mac-style pointer watchers in Pascal.

  macOS:    lives in the menu bar (right-hand extras).
  Windows:  notification-area icon plus a taskbar window.
  Linux:    panel / menu-bar status icon (GTK 2, Raspberry Pi OS friendly).

  Only one HostRun is linked; the other two host units are not compiled.
  Build: see the Makefile. }

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
  HostRun; { Cocoa run loop, Win32 GetMessage, or gtk_main — see uhost*.pas }
end.
