unit ueyesapp;

{$mode objfpc}{$H+}

interface

uses
  ueyesmodel, ueyesrender;

const
  EyesAboutTitle = 'Eyes';
  EyesAboutText =
    'A classic Macintosh-inspired pointer watcher.' + LineEnding + LineEnding +
    'The eyes follow the mouse, go cross-eyed when the pointer slips between them, ' +
    'blink on their own, and doze off if nothing moves for a while.' + LineEnding + LineEnding +
    'Click the desktop window or use the menu to quit.';

type
  TEyesController = class
  public
    Model: TEyesModel;
    Bar: TPixelBuffer;
    Desk: TPixelBuffer;
    ShowDesktop: Boolean;
    constructor Create(BarW, BarH, DeskW, DeskH: Integer);
    destructor Destroy; override;
    procedure Tick(Dt, MouseScreenX, MouseScreenY: Double);
    procedure RenderBar(MouseCanvasX, MouseCanvasY: Double);
    procedure RenderDesk(MouseCanvasX, MouseCanvasY: Double);
    procedure ToggleDesktop;
  end;

implementation

constructor TEyesController.Create(BarW, BarH, DeskW, DeskH: Integer);
begin
  inherited Create;
  Model := TEyesModel.Create;
  Bar := TPixelBuffer.Create(BarW, BarH);
  Desk := TPixelBuffer.Create(DeskW, DeskH);
  ShowDesktop := False;
end;

destructor TEyesController.Destroy;
begin
  Desk.Free;
  Bar.Free;
  Model.Free;
  inherited Destroy;
end;

procedure TEyesController.Tick(Dt, MouseScreenX, MouseScreenY: Double);
begin
  Model.Update(Dt, MouseScreenX, MouseScreenY);
end;

procedure TEyesController.RenderBar(MouseCanvasX, MouseCanvasY: Double);
var
  Layout: TEyesLayout;
  Pose: TEyesPose;
begin
  Layout := MakeLayout(Bar.Width, Bar.Height);
  Pose := Model.Pose(Vec2(MouseCanvasX, MouseCanvasY), Layout);
  RenderEyes(Bar, Pose, False);
end;

procedure TEyesController.RenderDesk(MouseCanvasX, MouseCanvasY: Double);
var
  Layout: TEyesLayout;
  Pose: TEyesPose;
begin
  Layout := MakeLayout(Desk.Width, Desk.Height);
  Pose := Model.Pose(Vec2(MouseCanvasX, MouseCanvasY), Layout);
  RenderEyes(Desk, Pose, True);
end;

procedure TEyesController.ToggleDesktop;
begin
  ShowDesktop := not ShowDesktop;
end;

end.
