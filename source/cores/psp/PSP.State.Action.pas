unit PSP.State.Action;

// Explicit continuations: a named owner method and ordinary captured state.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses System.SysUtils, System.Classes;

type
  TPSPStateAction = class;
  IPSPStateAction = interface
    ['{F38D6EF5-C4ED-4DD4-AF35-03FD09773910}']
    procedure Run(Value: Cardinal = 0);
  end;
  TPSPStateActionHandler = procedure(Action: TPSPStateAction; Value: Cardinal) of object;

  TPSPStateAction = class(TInterfacedObject, IPSPStateAction)
  public
    Handler: TPSPStateActionHandler;
    Target: TObject;
    Objects: TArray<TObject>;
    Values: TArray<Int64>;
    Data: TBytes;
    Text: string;
    Next: IPSPStateAction;
    constructor Create(const Callback: TPSPStateActionHandler; const Captures: array of TObject;
      const Args: array of Int64; const Tag: string = ''; const After: IPSPStateAction = nil);
    function Arg(Index: Integer): Int64;
    function Obj(Index: Integer): TObject;
    procedure Run(Value: Cardinal = 0);
  end;

implementation

constructor TPSPStateAction.Create(const Callback: TPSPStateActionHandler; const Captures: array of TObject;
  const Args: array of Int64; const Tag: string; const After: IPSPStateAction);
begin
  inherited Create;
  Handler := Callback;
  SetLength(Objects, Length(Captures));
  for var I := 0 to High(Captures) do Objects[I] := Captures[I];
  SetLength(Values, Length(Args));
  for var I := 0 to High(Args) do Values[I] := Args[I];
  Text := Tag;
  Next := After;
end;

function TPSPStateAction.Arg(Index: Integer): Int64;
begin
  if (Index < 0) or (Index >= Length(Values)) then raise EReadError.Create('Invalid state action argument');
  Result := Values[Index];
end;

function TPSPStateAction.Obj(Index: Integer): TObject;
begin
  if (Index < 0) or (Index >= Length(Objects)) then raise EReadError.Create('Invalid state action capture');
  Result := Objects[Index];
end;

procedure TPSPStateAction.Run(Value: Cardinal);
begin
  if not Assigned(Handler) then raise EReadError.Create('Missing state action handler');
  Handler(Self, Value);
end;

end.
