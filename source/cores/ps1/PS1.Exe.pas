unit PS1.Exe;

interface

uses
  System.SysUtils, PS1.Types;

const
  PS1ExeHeaderSize = $800;
  // The BIOS jumps here to start its shell once the kernel is initialized.
  PS1ShellEntry = $80030000;

type
  TPS1Exe = record
    PC, GP, Destination, Size, BSS, BSSSize, StackBase, StackOffset: Cardinal;
    Image: TBytes;
  end;

function IsPS1Exe(const Data: TBytes): Boolean;

// Validates the header and that the image fits main RAM.
function ParsePS1Exe(const Data: TBytes): TPS1Exe;

implementation

function Read32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
    (Cardinal(Data[Offset + 2]) shl 16) or (Cardinal(Data[Offset + 3]) shl 24);
end;

function IsPS1Exe(const Data: TBytes): Boolean;
const
  Magic: array[0..7] of Byte = (Ord('P'), Ord('S'), Ord('-'), Ord('X'), Ord(' '), Ord('E'), Ord('X'), Ord('E'));
begin
  Result := (Length(Data) >= PS1ExeHeaderSize) and CompareMem(@Data[0], @Magic[0], SizeOf(Magic));
end;

function ParsePS1Exe(const Data: TBytes): TPS1Exe;
begin
  if not IsPS1Exe(Data) then
    raise EPS1Error.Create('Not a PS-X EXE file');

  Result.PC := Read32(Data, $10);
  Result.GP := Read32(Data, $14);
  Result.Destination := Read32(Data, $18);
  Result.Size := Read32(Data, $1C);
  Result.BSS := Read32(Data, $28);
  Result.BSSSize := Read32(Data, $2C);
  Result.StackBase := Read32(Data, $30);
  Result.StackOffset := Read32(Data, $34);
  // Some tools write a smaller size than the file holds; never read past it.
  var Available := Cardinal(Length(Data) - PS1ExeHeaderSize);
  if Result.Size > Available then
    Result.Size := Available;
  var Start := Result.Destination and $1FFFFF;
  if ((Result.Destination and $1F000000) <> 0) or (Start + Int64(Result.Size) > PS1RAMSize) or
    ((Result.PC and 3) <> 0) then
    raise EPS1Error.Create('PS-X EXE does not fit main RAM');
  if (Result.BSSSize <> 0) and (((Result.BSS and $1FFFFF) + Int64(Result.BSSSize) > PS1RAMSize) or
    ((Result.BSS and $1F000000) <> 0)) then
    raise EPS1Error.Create('PS-X EXE BSS does not fit main RAM');
  Result.Image := Copy(Data, PS1ExeHeaderSize, Result.Size);
end;

end.
