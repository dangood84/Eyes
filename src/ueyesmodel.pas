unit ueyesmodel;

{$mode objfpc}{$H+}

{ Behaviour only: idle, blink, lids, and the pupil clamp.
  No pixels and no Cocoa/Win32/GTK types. Pose() is a pure read of the
  current lids plus two Track() calls — that is why the menu extra and the
  desktop window can aim at different canvases while sharing one blink. }

interface

type
  TVec2 = record
    X, Y: Double;
  end;

  { Eye geometry in *canvas* pixels (y down). Same formula sizes the 44×22
    extra and the 240×120 window. }
  TEyesLayout = record
    LeftCX, RightCX, CY: Double;
    RX, RY, PupilR, MaxTravel: Double;
  end;

  { One frame of where to paint. Left/Right are pupil centres, not eye centres. }
  TEyesPose = record
    Left: TVec2;
    Right: TVec2;
    LidOpen: Double;   { 0 = shut, 1 = fully open }
    Asleep: Boolean;
    Drowsy: Boolean;
  end;

  TEyesModel = class
  private
    FLastMouse: TVec2;
    FHaveMouse: Boolean;
    FIdle: Double;
    FLid: Double;
    FLidTarget: Double;
    FBlinkT: Double;
    FBlinkPhase: Double;
    FNextBlink: Double;
    FDoubleBlink: Boolean;
    FAsleep: Boolean;
    FDrowsy: Boolean;
    procedure ScheduleBlink;
    function Track(const Eye, Mouse: TVec2; MaxTravel: Double): TVec2;
  public
    constructor Create;
    { Screen-space mouse. Mutates idle / blink / lids. Does not draw. }
    procedure Update(Dt, MouseX, MouseY: Double);
    { Canvas-space mouse. Does not mutate idle. }
    function Pose(const MouseCanvas: TVec2; const Layout: TEyesLayout): TEyesPose;
    property LidOpen: Double read FLid;
    property Asleep: Boolean read FAsleep;
  end;

function Vec2(AX, AY: Double): TVec2;
function MakeLayout(CanvasW, CanvasH: Integer): TEyesLayout;
function MouseToCanvas(MouseX, MouseY, ViewX, ViewY, ViewW, ViewH,
  CanvasW, CanvasH: Double; FlipY: Boolean): TVec2;

implementation

uses
  Math;

const
  IdleDrowsy = 14.0;  { seconds of stillness before a sleepy squint }
  IdleSleep = 26.0;   { lids fully close; blinks stop }
  WakeMove = 4.0;     { pixels of pointer travel that count as “activity” }
  BlinkMin = 2.4;
  BlinkMax = 6.2;

function Vec2(AX, AY: Double): TVec2;
begin
  Result.X := AX;
  Result.Y := AY;
end;

function Smooth(Current, Target, Speed, Dt: Double): Double;
var
  T: Double;
begin
  { Exponential ease, not a fixed “lid units per tick”, so a blink still lasts
    ~0.16 s if the timer jitters (33 ms vs 50 ms). }
  T := 1.0 - Exp(-Speed * Dt);
  if T < 0 then
    T := 0
  else if T > 1 then
    T := 1;
  Result := Current + (Target - Current) * T;
end;

function MakeLayout(CanvasW, CanvasH: Integer): TEyesLayout;
var
  S: Double;
begin
  S := Min(CanvasW / 2.15, CanvasH / 1.05);
  Result.RX := S * 0.42;
  Result.RY := S * 0.40;           { slightly oval, like classic Mac Eyes }
  Result.LeftCX := CanvasW * 0.27;
  Result.RightCX := CanvasW * 0.73;
  Result.CY := CanvasH * 0.52;
  Result.PupilR := Min(Result.RX, Result.RY) * 0.36;
  { Travel budget is sclera minus pupil so the disc stays inside the white. }
  Result.MaxTravel := Min(Result.RX, Result.RY) - Result.PupilR - 0.85;
  if Result.MaxTravel < 1 then
    Result.MaxTravel := 1;
end;

function MouseToCanvas(MouseX, MouseY, ViewX, ViewY, ViewW, ViewH,
  CanvasW, CanvasH: Double; FlipY: Boolean): TVec2;
begin
  if (ViewW < 0.5) or (ViewH < 0.5) then
  begin
    { Extra not realised yet: rest the pupils rather than divide by zero. }
    Result := Vec2(CanvasW * 0.5, CanvasH * 0.5);
    Exit;
  end;
  Result.X := (MouseX - ViewX) * (CanvasW / ViewW);
  if FlipY then
    { Cocoa screen space is y-up; the pixel buffer is y-down. }
    Result.Y := CanvasH - (MouseY - ViewY) * (CanvasH / ViewH)
  else
    Result.Y := (MouseY - ViewY) * (CanvasH / ViewH);
end;

constructor TEyesModel.Create;
begin
  inherited Create;
  Randomize;
  FLid := 1.0;
  FLidTarget := 1.0;
  FNextBlink := 1.0 + Random * 2.0;
  FLastMouse := Vec2(0, 0);
end;

procedure TEyesModel.ScheduleBlink;
begin
  FNextBlink := BlinkMin + Random * (BlinkMax - BlinkMin);
  FDoubleBlink := Random < 0.12;
end;

function TEyesModel.Track(const Eye, Mouse: TVec2; MaxTravel: Double): TVec2;
var
  DX, DY, Dist, Scale: Double;
begin
  { Classic xeyes / Mac Eyes clamp: aim at the pointer, but never leave the
    sclera. There is no “if between the eyes then cross” branch — when the
    pointer sits between the two centres, the left pupil is pulled right and
    the right pupil left all by themselves. }
  DX := Mouse.X - Eye.X;
  DY := Mouse.Y - Eye.Y;
  Dist := Sqrt(DX * DX + DY * DY);
  if Dist < 0.0001 then
  begin
    Result := Eye;
    Exit;
  end;
  if Dist > MaxTravel then
    Scale := MaxTravel / Dist
  else
    Scale := 1.0;
  Result := Vec2(Eye.X + DX * Scale, Eye.Y + DY * Scale);
end;

procedure TEyesModel.Update(Dt, MouseX, MouseY: Double);
var
  Moved, Speed: Double;
begin
  if Dt < 0 then
    Dt := 0
  else if Dt > 0.2 then
    { Cap so a breakpoint or stalled run loop cannot skip drowsy → asleep in one jump. }
    Dt := 0.2;

  if FHaveMouse then
  begin
    Moved := Sqrt(Sqr(MouseX - FLastMouse.X) + Sqr(MouseY - FLastMouse.Y));
    if Moved >= WakeMove then
    begin
      FIdle := 0;
      FAsleep := False;
      FDrowsy := False;
    end
    else
      FIdle := FIdle + Dt;
  end
  else
    FHaveMouse := True; { first sample only stamps position, so launch is not a “wake” }

  FLastMouse := Vec2(MouseX, MouseY);

  if FIdle >= IdleSleep then
  begin
    FAsleep := True;
    FDrowsy := False;
    FLidTarget := 0.0;
    FBlinkPhase := 0;   { no blinks while napping }
  end
  else if FIdle >= IdleDrowsy then
  begin
    FDrowsy := True;
    FAsleep := False;
    FLidTarget := 0.42;
  end
  else
  begin
    FDrowsy := False;
    FAsleep := False;
    FLidTarget := 1.0;
  end;

  if FAsleep then
    FBlinkT := 0
  else
  begin
    FBlinkT := FBlinkT + Dt;
    if (FBlinkPhase = 0) and (FBlinkT >= FNextBlink) then
    begin
      FBlinkPhase := 0.001;
      FBlinkT := 0;
    end;
  end;

  if FBlinkPhase > 0 then
  begin
    FBlinkPhase := FBlinkPhase + Dt;
    { Close, open, and sometimes a second close — a texture swap would look
      mechanical; we just retarget FLid and Smooth() does the rest. }
    if FBlinkPhase < 0.07 then
      FLidTarget := 0.0
    else if FBlinkPhase < 0.16 then
      FLidTarget := 1.0
    else if FDoubleBlink and (FBlinkPhase < 0.28) then
      FLidTarget := 0.0
    else if FDoubleBlink and (FBlinkPhase < 0.38) then
      FLidTarget := 1.0
    else
    begin
      FBlinkPhase := 0;
      ScheduleBlink;
      if FDrowsy then
        FLidTarget := 0.42
      else if not FAsleep then
        FLidTarget := 1.0;
    end;
  end;

  if FAsleep or (FBlinkPhase > 0) then
    Speed := 18
  else if FDrowsy then
    Speed := 3.2   { heavy lids ease shut slowly }
  else
    Speed := 14;
  FLid := Smooth(FLid, FLidTarget, Speed, Dt);
  if FLid < 0 then
    FLid := 0
  else if FLid > 1 then
    FLid := 1;
end;

function TEyesModel.Pose(const MouseCanvas: TVec2; const Layout: TEyesLayout): TEyesPose;
begin
  Result.Left := Track(Vec2(Layout.LeftCX, Layout.CY), MouseCanvas, Layout.MaxTravel);
  Result.Right := Track(Vec2(Layout.RightCX, Layout.CY), MouseCanvas, Layout.MaxTravel);
  Result.LidOpen := FLid;
  Result.Asleep := FAsleep and (FLid < 0.2);
  Result.Drowsy := FDrowsy;
end;

end.
