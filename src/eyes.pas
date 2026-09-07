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
  HostRun;
end.
