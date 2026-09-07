unit ueyesrender;

{$mode objfpc}{$H+}

interface

uses
  ueyesmodel;

type
  TPixelBuffer = class
  private
    FWidth, FHeight: Integer;
    FData: array of Byte;
  public
    constructor Create(AWidth, AHeight: Integer);
    procedure Resize(AWidth, AHeight: Integer);
    procedure Clear(R, G, B, A: Byte);
    function Ptr: PByte;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

procedure RenderEyes(Buf: TPixelBuffer; const Pose: TEyesPose;
  Backdrop: Boolean);

procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);

implementation

uses
  Math;

type
  TColor = record
    R, G, B: Byte;
  end;

function C(R, G, B: Byte): TColor;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

constructor TPixelBuffer.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  Resize(AWidth, AHeight);
end;

procedure TPixelBuffer.Resize(AWidth, AHeight: Integer);
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FData, FWidth * FHeight * 4);
end;

procedure TPixelBuffer.Clear(R, G, B, A: Byte);
var
  I: Integer;
  P: PByte;
begin
  P := @FData[0];
  I := 0;
  while I < Length(FData) do
  begin
    P[I] := R;
    P[I + 1] := G;
    P[I + 2] := B;
    P[I + 3] := A;
    Inc(I, 4);
  end;
end;

function TPixelBuffer.Ptr: PByte;
begin
  Result := @FData[0];
end;

procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);
var
  I, N: Integer;
  S, D: PByte;
begin
  S := Buf.Ptr;
  D := Dest;
  N := Buf.Width * Buf.Height;
  for I := 0 to N - 1 do
  begin
    D[0] := S[2];
    D[1] := S[1];
    D[2] := S[0];
    D[3] := S[3];
    Inc(S, 4);
    Inc(D, 4);
  end;
end;

procedure BlendPixel(P: PByte; R, G, B: Byte; A: Double);
var
  SA, DA, OutA, Inv: Double;
begin
  if A <= 0.001 then
    Exit;
  if A > 1 then
    A := 1;
  SA := A;
  DA := P[3] / 255.0;
  Inv := 1.0 - SA;
  OutA := SA + DA * Inv;
  if OutA <= 0.001 then
    Exit;
  P[0] := Round((R * SA + P[0] * DA * Inv) / OutA);
  P[1] := Round((G * SA + P[1] * DA * Inv) / OutA);
  P[2] := Round((B * SA + P[2] * DA * Inv) / OutA);
  P[3] := Round(OutA * 255.0);
end;

function CoverEllipse(PX, PY, CX, CY, RX, RY: Double): Double;
var
  NX, NY, D, Edge: Double;
begin
  if (RX <= 0.2) or (RY <= 0.2) then
    Exit(0);
  NX := (PX - CX) / RX;
  NY := (PY - CY) / RY;
  D := Sqrt(NX * NX + NY * NY);
  Edge := (D - 1.0) * Min(RX, RY);
  if Edge <= -0.6 then
    Result := 1
  else if Edge >= 0.6 then
    Result := 0
  else
    Result := 1.0 - (Edge + 0.6) / 1.2;
end;

procedure FillEllipse(Buf: TPixelBuffer; CX, CY, RX, RY: Double; Col: TColor; Alpha: Double);
var
  X0, Y0, X1, Y1, X, Y, W: Integer;
  Cov: Double;
  P: PByte;
begin
  if (Alpha <= 0) or (RX <= 0) or (RY <= 0) then
    Exit;
  X0 := Max(0, Floor(CX - RX - 1));
  Y0 := Max(0, Floor(CY - RY - 1));
  X1 := Min(Buf.Width - 1, Ceil(CX + RX + 1));
  Y1 := Min(Buf.Height - 1, Ceil(CY + RY + 1));
  W := Buf.Width;
  for Y := Y0 to Y1 do
  begin
    P := Buf.Ptr + (Y * W + X0) * 4;
    for X := X0 to X1 do
    begin
      Cov := CoverEllipse(X + 0.5, Y + 0.5, CX, CY, RX, RY);
      if Cov > 0 then
        BlendPixel(P, Col.R, Col.G, Col.B, Cov * Alpha);
      Inc(P, 4);
    end;
  end;
end;

procedure FillEllipseClipped(Buf: TPixelBuffer; CX, CY, RX, RY, ClipCX, ClipCY, ClipRX, ClipRY: Double;
  Col: TColor; Alpha: Double);
var
  X0, Y0, X1, Y1, X, Y, W: Integer;
  Cov: Double;
  P: PByte;
begin
  if (Alpha <= 0) or (RX <= 0) or (RY <= 0) then
    Exit;
  X0 := Max(0, Floor(CX - RX - 1));
  Y0 := Max(0, Floor(CY - RY - 1));
  X1 := Min(Buf.Width - 1, Ceil(CX + RX + 1));
  Y1 := Min(Buf.Height - 1, Ceil(CY + RY + 1));
  W := Buf.Width;
  for Y := Y0 to Y1 do
  begin
    P := Buf.Ptr + (Y * W + X0) * 4;
    for X := X0 to X1 do
    begin
      Cov := CoverEllipse(X + 0.5, Y + 0.5, CX, CY, RX, RY) *
             CoverEllipse(X + 0.5, Y + 0.5, ClipCX, ClipCY, ClipRX, ClipRY);
      if Cov > 0 then
        BlendPixel(P, Col.R, Col.G, Col.B, Cov * Alpha);
      Inc(P, 4);
    end;
  end;
end;

procedure StrokeEllipse(Buf: TPixelBuffer; CX, CY, RX, RY, Thickness: Double; Col: TColor; Alpha: Double);
var
  InnerX, InnerY: Double;
  X0, Y0, X1, Y1, X, Y, W: Integer;
  Cov: Double;
  P: PByte;
begin
  InnerX := RX - Thickness;
  InnerY := RY - Thickness;
  if InnerX < 0.4 then
    InnerX := 0.4;
  if InnerY < 0.4 then
    InnerY := 0.4;
  X0 := Max(0, Floor(CX - RX - 1));
  Y0 := Max(0, Floor(CY - RY - 1));
  X1 := Min(Buf.Width - 1, Ceil(CX + RX + 1));
  Y1 := Min(Buf.Height - 1, Ceil(CY + RY + 1));
  W := Buf.Width;
  for Y := Y0 to Y1 do
  begin
    P := Buf.Ptr + (Y * W + X0) * 4;
    for X := X0 to X1 do
    begin
      Cov := CoverEllipse(X + 0.5, Y + 0.5, CX, CY, RX, RY) *
             (1.0 - CoverEllipse(X + 0.5, Y + 0.5, CX, CY, InnerX, InnerY));
      if Cov > 0 then
        BlendPixel(P, Col.R, Col.G, Col.B, Cov * Alpha);
      Inc(P, 4);
    end;
  end;
end;

procedure DrawClosedLid(Buf: TPixelBuffer; CX, CY, RX, RY: Double);
var
  T, X, Y, Cov: Double;
  I, PX, PY, W: Integer;
  P: PByte;
begin
  W := Buf.Width;
  for I := 0 to 48 do
  begin
    T := I / 48.0;
    X := CX + (T * 2 - 1) * RX;
    Y := CY + Sin(T * Pi) * RY * 0.22;
    for PY := Max(0, Floor(Y - 1.4)) to Min(Buf.Height - 1, Ceil(Y + 1.4)) do
      for PX := Max(0, Floor(X - 1.2)) to Min(Buf.Width - 1, Ceil(X + 1.2)) do
      begin
        Cov := 1.0 - Sqrt(Sqr(PX + 0.5 - X) + Sqr(PY + 0.5 - Y)) / 1.35;
        if Cov > 0 then
        begin
          P := Buf.Ptr + (PY * W + PX) * 4;
          BlendPixel(P, 36, 36, 36, Cov);
        end;
      end;
  end;
end;

procedure DrawEye(Buf: TPixelBuffer; CX, CY, RX, RY, PupilX, PupilY, PupilR, Lid: Double);
var
  OpenRY, Shade: Double;
  Hi: TVec2;
begin
  if Lid < 0.12 then
  begin
    DrawClosedLid(Buf, CX, CY, RX * 0.92, RY);
    Exit;
  end;

  OpenRY := RY * (0.16 + Lid * 0.84);
  Shade := 0.55 + 0.45 * Lid;

  FillEllipse(Buf, CX, CY + OpenRY * 0.08, RX, OpenRY, C(226, 222, 210), 1);
  FillEllipse(Buf, CX - RX * 0.08, CY - OpenRY * 0.10, RX * 0.92, OpenRY * 0.88,
    C(252, 250, 245), 1);

  FillEllipseClipped(Buf, PupilX, PupilY, PupilR, PupilR, CX, CY, RX * 0.90, OpenRY * 0.90,
    C(18, 18, 20), 1);

  Hi.X := PupilX - PupilR * 0.38;
  Hi.Y := PupilY - PupilR * 0.40;
  FillEllipseClipped(Buf, Hi.X, Hi.Y, PupilR * 0.28, PupilR * 0.22,
    CX, CY, RX * 0.90, OpenRY * 0.90, C(255, 255, 255), 0.9 * Shade);

  StrokeEllipse(Buf, CX, CY, RX, OpenRY, Max(1.1, Min(RX, OpenRY) * 0.08),
    C(38, 38, 40), 0.95);
end;

procedure DrawBackdrop(Buf: TPixelBuffer);
var
  CX, CY, RX, RY: Double;
begin
  CX := Buf.Width * 0.5;
  CY := Buf.Height * 0.5;
  RX := Buf.Width * 0.48;
  RY := Buf.Height * 0.46;
  FillEllipse(Buf, CX + 1, CY + 1.4, RX, RY, C(170, 166, 158), 0.35);
  FillEllipse(Buf, CX, CY, RX, RY, C(232, 228, 218), 0.92);
end;

procedure RenderEyes(Buf: TPixelBuffer; const Pose: TEyesPose; Backdrop: Boolean);
var
  Layout: TEyesLayout;
begin
  Buf.Clear(0, 0, 0, 0);
  if Backdrop then
    DrawBackdrop(Buf);
  Layout := MakeLayout(Buf.Width, Buf.Height);
  DrawEye(Buf, Layout.LeftCX, Layout.CY, Layout.RX, Layout.RY,
    Pose.Left.X, Pose.Left.Y, Layout.PupilR, Pose.LidOpen);
  DrawEye(Buf, Layout.RightCX, Layout.CY, Layout.RX, Layout.RY,
    Pose.Right.X, Pose.Right.Y, Layout.PupilR, Pose.LidOpen);
end;

end.
