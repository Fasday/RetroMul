unit PSP.GE.Engine;

// The GE's command processor below list control: register writes, matrix
// uploads, primitives, block transfers. Flow commands (JUMP, CALL, END, ...)
// are run by the list driver in PSP.GE, which owns the program counter.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.GE.Types;

type
  TPSPGEEngine = class
  private
    FMemory: TPSPMemory;
  public
    Regs: TPSPGERegs;
    // Set by BBOX: the box is (possibly) visible.
    BoxVisible: Boolean;
    constructor Create(Memory: TPSPMemory);
    procedure Reset;
    // Address of a 24-bit pointer parameter with the BASE upper bits and OFFSET.
    function Address(Param: Cardinal): Cardinal; inline;
    // Runs one command; returns its cost in GE nanoseconds.
    function Execute(Op, PC: Cardinal): Integer;
    procedure SaveContext(Address: Cardinal);
    procedure RestoreContext(Address: Cardinal);
    property Memory: TPSPMemory read FMemory;
  end;

const
  // Context words: a header, then the state commands in this order, then the matrices.
  GEContextCmdStart = 17;

var
  GEContextCmds: array of Byte;

implementation

constructor TPSPGEEngine.Create(Memory: TPSPMemory);
begin
  inherited Create;
  FMemory := Memory;
  Reset;
end;

procedure TPSPGEEngine.Reset;
begin
  Regs := Default(TPSPGERegs);
  for var I := 0 to 255 do
    Regs.Cmd[I] := Cardinal(I) shl 24;
  BoxVisible := True;
end;

function TPSPGEEngine.Address(Param: Cardinal): Cardinal;
begin
  Result := (((Regs.Cmd[GE_BASE] and $0F0000) shl 8) or (Param and $FFFFFF)) + Regs.Offset;
end;

function TPSPGEEngine.Execute(Op, PC: Cardinal): Integer;
begin
  Result := 4;
  var Cmd := Op shr 24;
  var P := Op and $FFFFFF;
  case Cmd of
    GE_VADDR:
      Regs.VAddr := Address(P);
    GE_IADDR:
      Regs.IAddr := Address(P);
    GE_BBOX:
      BoxVisible := (P and $FFFF) <> 0;
    GE_OFFSETADDR:
      Regs.Offset := P shl 8;
    GE_ORIGIN:
      Regs.Offset := PC;
    GE_BONEMATRIXNUMBER:
      Regs.BoneNum := P and $7F;
    GE_BONEMATRIXDATA:
      begin
        if Regs.BoneNum < 96 then
          Regs.Bone[Regs.BoneNum] := P;
        Regs.BoneNum := (Regs.BoneNum + 1) and $7F;
        Exit;
      end;
    GE_WORLDMATRIXNUMBER:
      Regs.WorldNum := P and $F;
    GE_WORLDMATRIXDATA:
      begin
        if Regs.WorldNum < 12 then
          Regs.World[Regs.WorldNum] := P;
        Regs.WorldNum := (Regs.WorldNum + 1) and $F;
        Exit;
      end;
    GE_VIEWMATRIXNUMBER:
      Regs.ViewNum := P and $F;
    GE_VIEWMATRIXDATA:
      begin
        if Regs.ViewNum < 12 then
          Regs.View[Regs.ViewNum] := P;
        Regs.ViewNum := (Regs.ViewNum + 1) and $F;
        Exit;
      end;
    GE_PROJMATRIXNUMBER:
      Regs.ProjNum := P and $F;
    GE_PROJMATRIXDATA:
      begin
        Regs.Proj[Regs.ProjNum and 15] := P;
        Regs.ProjNum := (Regs.ProjNum + 1) and $F;
        Exit;
      end;
    GE_TGENMATRIXNUMBER:
      Regs.TGenNum := P and $F;
    GE_TGENMATRIXDATA:
      begin
        if Regs.TGenNum < 12 then
          Regs.TGen[Regs.TGenNum] := P;
        Regs.TGenNum := (Regs.TGenNum + 1) and $F;
        Exit;
      end;
  end;
  Regs.Cmd[Cmd] := Op;
end;

procedure TPSPGEEngine.SaveContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  FillChar(W, SizeOf(W), 0);
  W[0] := $00000001;
  W[5] := Regs.VAddr;
  W[6] := Regs.IAddr;
  W[7] := Regs.Offset;
  W[8] := Regs.BoneNum;
  W[9] := Regs.WorldNum;
  W[10] := Regs.ViewNum;
  W[11] := Regs.ProjNum;
  W[12] := Regs.TGenNum;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    W[N] := Regs.Cmd[C];
    Inc(N);
  end;
  for var I := 0 to 95 do begin W[N] := Regs.Bone[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.World[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.View[I]; Inc(N); end;
  for var I := 0 to 15 do begin W[N] := Regs.Proj[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.TGen[I]; Inc(N); end;
  FMemory.WriteBytes(Address, W[0], N * 4);
end;

procedure TPSPGEEngine.RestoreContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  var Total := GEContextCmdStart + Length(GEContextCmds) + 96 + 12 + 12 + 16 + 12;
  FMemory.ReadBytes(Address, W[0], Total * 4);
  Regs.VAddr := W[5];
  Regs.IAddr := W[6];
  Regs.Offset := W[7];
  Regs.BoneNum := W[8] and $7F;
  Regs.WorldNum := W[9] and $F;
  Regs.ViewNum := W[10] and $F;
  Regs.ProjNum := W[11] and $F;
  Regs.TGenNum := W[12] and $F;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    Regs.Cmd[C] := (Cardinal(C) shl 24) or (W[N] and $FFFFFF);
    Inc(N);
  end;
  for var I := 0 to 95 do begin Regs.Bone[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.World[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.View[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 15 do begin Regs.Proj[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.TGen[I] := W[N] and $FFFFFF; Inc(N); end;
end;

procedure InitContextCmds;
const
  Ranges: array[0..15, 0..1] of Byte = (
    ($00, $02), ($10, $10), ($12, $28), ($2C, $33), ($36, $38), ($42, $4D), ($50, $51), ($53, $58),
    ($5B, $B5), ($B8, $C3), ($C5, $D0), ($D2, $E9), ($EB, $EC), ($EE, $EE), ($F0, $F6), ($F8, $F9));
begin
  for var R := 0 to High(Ranges) do
    for var C := Ranges[R, 0] to Ranges[R, 1] do
      GEContextCmds := GEContextCmds + [Byte(C)];
end;

initialization
  InitContextCmds;

end.
