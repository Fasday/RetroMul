unit GW.Script;

// Small native interpreter for the Lua source carried by MGW simulations.
// Scripts have no filesystem, network, process or native-library access.

interface

uses
  System.SysUtils, System.Generics.Collections, Core.Snapshots;

type
  TScriptObject = class;

  TScriptTable = class;

  TScriptEnv = class;

  TScriptNode = class;

  TScriptEngine = class;

  TScriptKind = (skNil, skBool, skNumber, skString, skObject);

  TScriptValue = record
    Kind: TScriptKind;
    Number: Double;
    Text: string;
    Obj: TScriptObject;
    class function NilValue: TScriptValue; static;
    class function Num(Value: Double): TScriptValue; static;
    class function Str(const Value: string): TScriptValue; static;
    class function Bool(Value: Boolean): TScriptValue; static;
    class function ObjectValue(Value: TScriptObject): TScriptValue; static;
    function Truth: Boolean;
    function AsNumber: Double;
    function AsString: string;
    function Key: string;
  end;

  TScriptValues = TArray<TScriptValue>;

  TScriptNative = reference to function(const Args: TScriptValues): TScriptValues;

  TScriptObject = class
    Marked: Boolean;
    procedure Mark; virtual;
  end;

  TScriptEntry = record
    Key, Value: TScriptValue;
  end;

  TScriptTable = class(TScriptObject)
  public
    Entries: TDictionary<string, TScriptEntry>;
    Meta: TScriptTable;
    constructor Create;
    destructor Destroy; override;
    function RawGet(const Key: TScriptValue): TScriptValue;
    procedure RawSet(const Key, Value: TScriptValue);
    function Count: Integer;
    procedure Mark; override;
  end;

  TScriptEnv = class(TScriptObject)
    Values: TDictionary<string, TScriptValue>;
    Parent: TScriptEnv;
    Extra: TScriptValues;
    constructor Create(AParent: TScriptEnv);
    destructor Destroy; override;
    function Get(const Name: string): TScriptValue;
    procedure Put(const Name: string; const Value: TScriptValue; local: Boolean);
    procedure Mark; override;
  end;

  TScriptNode = class
    Op, Text: string;
    Number: Double;
    Names: TArray<string>;
    Children: TArray<TScriptNode>;
  end;

  TScriptFunction = class(TScriptObject)
    Body: TScriptNode;
    Env: TScriptEnv;
    Native: TScriptNative;
    NativeId: Integer;
    procedure Mark; override;
  end;

  TScriptEngine = class
  private
    FObjects: TObjectList<TScriptObject>;
    FNodes: TObjectList<TScriptNode>;
    FGlobals: TScriptEnv;
    FNatives: TList<TScriptNative>;
    FSteps, FDepth: Integer;
    function Eval(Node: TScriptNode; Env: TScriptEnv): TScriptValues;
    function One(Node: TScriptNode; Env: TScriptEnv): TScriptValue;
    function ExprList(Node: TScriptNode; Env: TScriptEnv): TScriptValues;
    function Exec(Node: TScriptNode; Env: TScriptEnv; out Returned: TScriptValues): Integer;
    procedure Assign(Node: TScriptNode; Env: TScriptEnv; const Value: TScriptValue);
    procedure Step;
  public
    constructor Create;
    destructor Destroy; override;
    function NewNode(const Op: string): TScriptNode;
    function NewTable: TScriptTable;
    function NewEnv(Parent: TScriptEnv): TScriptEnv;
    function NewNative(const Callback: TScriptNative): TScriptValue;
    function Run(const Source: string): TScriptValues;
    function Call(const Func: TScriptValue; const Args: TScriptValues): TScriptValues;
    function Get(const Target, Key: TScriptValue): TScriptValue;
    procedure Put(const Target, Key, Value: TScriptValue);
    procedure Collect(const Roots: TScriptValues);
    function IsAlive(Obj: TScriptObject): Boolean;
    procedure BeginFrame;
    procedure SerializeState(Archive: TStateArchive);
    procedure TransferValue(Archive: TStateArchive; var Value: TScriptValue);
    procedure TransferTable(Archive: TStateArchive; var Value: TScriptTable);
    property Globals: TScriptEnv read FGlobals;
  end;

function SV(const Values: TScriptValues; Index: Integer = 0): TScriptValue;

implementation

uses
  System.Classes, System.Math;

function SV(const Values: TScriptValues; Index: Integer): TScriptValue;
begin
  if (Index >= 0) and (Index < Length(Values)) then
    Result := Values[Index]
  else
    Result := TScriptValue.NilValue;
end;

class function TScriptValue.NilValue: TScriptValue;
begin
  Result := Default(TScriptValue);
end;

class function TScriptValue.Num(Value: Double): TScriptValue;
begin
  Result := NilValue;
  Result.Kind := skNumber;
  Result.Number := Value;
end;

class function TScriptValue.Str(const Value: string): TScriptValue;
begin
  Result := NilValue;
  Result.Kind := skString;
  Result.Text := Value;
end;

class function TScriptValue.Bool(Value: Boolean): TScriptValue;
begin
  Result := NilValue;
  Result.Kind := skBool;
  Result.Number := Ord(Value);
end;

class function TScriptValue.ObjectValue(Value: TScriptObject): TScriptValue;
begin
  Result := NilValue;
  if Value <> nil then
  begin
    Result.Kind := skObject;
    Result.Obj := Value;
  end;
end;

function TScriptValue.Truth: Boolean;
begin
  Result := (Kind <> skNil) and ((Kind <> skBool) or (Number <> 0));
end;

function TScriptValue.AsNumber: Double;
begin
  if Kind = skNumber then
    Exit(Number);

  if (Kind = skString) and TryStrToFloat(Text, Result, TFormatSettings.Invariant) then
    Exit;

  raise EReadError.Create('MGW script: expected a number, got ' + AsString);
end;

function TScriptValue.AsString: string;
begin
  case Kind of
    skNil:
      Result := 'nil';
    skBool:
      if Number = 0 then
        Result := 'false'
      else
        Result := 'true';
    skNumber:
      Result := FloatToStr(Number, TFormatSettings.Invariant);
    skString:
      Result := Text;
  else
    if Obj is TScriptFunction then
      Result := 'function'
    else
      Result := 'table';
  end;
end;

function TScriptValue.Key: string;
begin
  Result := IntToStr(Ord(Kind)) + ':';
  if Kind = skObject then
    Result := Result + IntToHex(NativeUInt(Obj), 16)
  else
    Result := Result + AsString;
end;

procedure TScriptObject.Mark;
begin
  Marked := True;
end;

constructor TScriptTable.Create;
begin
  inherited;
  Entries := TDictionary<string, TScriptEntry>.Create;
end;

destructor TScriptTable.Destroy;
begin
  Entries.Free;
  inherited;
end;

function TScriptTable.RawGet(const Key: TScriptValue): TScriptValue;
begin
  var Entry: TScriptEntry;
  if Entries.TryGetValue(Key.Key, Entry) then
    Result := Entry.Value
  else
    Result := TScriptValue.NilValue;
end;

procedure TScriptTable.RawSet(const Key, Value: TScriptValue);
begin
  if Key.Kind = skNil then
    raise EReadError.Create('MGW script: nil table key');

  if Value.Kind = skNil then
    Entries.Remove(Key.Key)
  else
  begin
    var E: TScriptEntry;
    E.Key := Key;
    E.Value := Value;
    Entries.AddOrSetValue(Key.Key, E);
  end;
end;

function TScriptTable.Count: Integer;
begin
  Result := 0;
  while RawGet(TScriptValue.Num(Result + 1)).Kind <> skNil do
    Inc(Result);
end;

procedure TScriptTable.Mark;
begin
  if Marked then
    Exit;

  inherited;
  if Meta <> nil then
    Meta.Mark;
  for var E in Entries.Values do
  begin
    if E.Key.Obj <> nil then
      E.Key.Obj.Mark;
    if E.Value.Obj <> nil then
      E.Value.Obj.Mark;
  end;
end;

constructor TScriptEnv.Create(AParent: TScriptEnv);
begin
  inherited Create;
  Parent := AParent;
  if Parent <> nil then
    Extra := Parent.Extra;
  Values := TDictionary<string, TScriptValue>.Create;
end;

destructor TScriptEnv.Destroy;
begin
  Values.Free;
  inherited;
end;

function TScriptEnv.Get(const Name: string): TScriptValue;
begin
  if Values.TryGetValue(Name, Result) then
    Exit;

  if Parent <> nil then
    Result := Parent.Get(Name)
  else
    Result := TScriptValue.NilValue;
end;

procedure TScriptEnv.Put(const Name: string; const Value: TScriptValue; local: Boolean);
begin
  if local or Values.ContainsKey(Name) or (Parent = nil) then
    Values.AddOrSetValue(Name, Value)
  else
    Parent.Put(Name, Value, False);
end;

procedure TScriptEnv.Mark;
begin
  if Marked then
    Exit;

  inherited;
  if Parent <> nil then
    Parent.Mark;
  for var V in Values.Values do
    if V.Obj <> nil then
      V.Obj.Mark;
  for var V in Extra do
    if V.Obj <> nil then
      V.Obj.Mark;
end;

procedure TScriptFunction.Mark;
begin
  if Marked then
    Exit;

  inherited;
  if Env <> nil then
    Env.Mark;
end;

type
  TParser = class
    Engine: TScriptEngine;
    Source, Token, Kind: string;
    Pos, Line, Depth: Integer;
    constructor Create(AEngine: TScriptEngine; const Text: string);
    procedure Next;
    procedure Need(const S: string);
    function Accept(const S: string): Boolean;
    function Name: string;
    function Node(const Op: string; const Children: array of TScriptNode): TScriptNode;
    function Expr(MinPriority: Integer = 0): TScriptNode;
    function Atom: TScriptNode;
    function Func: TScriptNode;
    function List: TScriptNode;
    function Block: TScriptNode;
    function Statement: TScriptNode;
  end;

constructor TParser.Create(AEngine: TScriptEngine; const Text: string);
begin
  inherited Create;
  Engine := AEngine;
  Source := Text;
  Pos := 1;
  Line := 1;
  Next;
end;

procedure TParser.Next;

  function Peek(N: Integer = 0): Char;
  begin
    if Pos + N <= Length(Source) then
      Result := Source[Pos + N]
    else
      Result := #0;
  end;

  function LongString: string;
  begin
    var Start := Pos;
    Inc(Pos);
    var Equals := 0;
    while Peek = '=' do
    begin
      Inc(Equals);
      Inc(Pos);
    end;
    if Peek <> '[' then
      raise EReadError.Create('Invalid Lua long string');

    Inc(Pos);
    var Stop := ']' + StringOfChar('=', Equals) + ']';
    var EndPos := System.Pos(Stop, Source, Pos);
    if EndPos = 0 then
      raise EReadError.Create('Unterminated Lua long string');

    Result := Copy(Source, Pos, EndPos - Pos);
    Pos := EndPos + Length(Stop);
    if Result.StartsWith(#13#10) then
      Delete(Result, 1, 2)
    else if Result.StartsWith(#10) then
      Delete(Result, 1, 1);
    for var i := Start to Pos - 1 do
      if Source[i] = #10 then
        Inc(Line);
  end;

begin
  repeat
    while CharInSet(Peek, [#1..#32]) do
    begin
      if Peek = #10 then
        Inc(Line);
      Inc(Pos);
    end;
    if (Peek = '-') and (Peek(1) = '-') then
    begin
      Inc(Pos, 2);
      if (Peek = '[') and CharInSet(Peek(1), ['[', '=']) then
        LongString
      else
        while not CharInSet(Peek, [#0, #10]) do
          Inc(Pos);
    end
    else
      Break;
  until False;

  Token := '';
  Kind := 'symbol';
  var C := Peek;
  if C = #0 then
  begin
    Token := '<eof>';
    Exit;
  end;

  if CharInSet(C, ['A'..'Z', 'a'..'z', '_']) then
  begin
    Kind := 'name';
    var Start := Pos;
    repeat
      Inc(Pos);
    until not CharInSet(Peek, ['A'..'Z', 'a'..'z', '0'..'9', '_']);
    Token := Copy(Source, Start, Pos - Start);
    Exit;
  end;

  if CharInSet(C, ['0'..'9']) or ((C = '.') and CharInSet(Peek(1), ['0'..'9'])) then
  begin
    Kind := 'number';
    var Start := Pos;
    if (C = '0') and CharInSet(Peek(1), ['x', 'X']) then
    begin
      Inc(Pos, 2);
      while CharInSet(Peek, ['0'..'9', 'a'..'f', 'A'..'F']) do
        Inc(Pos);
    end
    else
    begin
      while CharInSet(Peek, ['0'..'9']) do
        Inc(Pos);
      if (Peek = '.') and (Peek(1) <> '.') then
      begin
        Inc(Pos);
        while CharInSet(Peek, ['0'..'9']) do
          Inc(Pos);
      end;
      if CharInSet(Peek, ['e', 'E']) then
      begin
        Inc(Pos);
        if CharInSet(Peek, ['+', '-']) then
          Inc(Pos);
        while CharInSet(Peek, ['0'..'9']) do
          Inc(Pos);
      end;
    end;
    Token := Copy(Source, Start, Pos - Start);
    Exit;
  end;

  if (C = '[') and CharInSet(Peek(1), ['[', '=']) then
  begin
    Kind := 'string';
    Token := LongString;
    Exit;
  end;

  if CharInSet(C, ['''', '"']) then
  begin
    Kind := 'string';
    Inc(Pos);
    while Peek <> C do
    begin
      if Peek = #0 then
        raise EReadError.Create('Unterminated MGW string');

      var V := Peek;
      Inc(Pos);
      if V = '\' then
      begin
        V := Peek;
        Inc(Pos);
        case V of
          'n':
            V := #10;
          'r':
            V := #13;
          't':
            V := #9;
          'a':
            V := #7;
          'b':
            V := #8;
          'f':
            V := #12;
          'v':
            V := #11;
          'x':
            begin
              var Hex := Copy(Source, Pos, 2);
              Inc(Pos, 2);
              V := Char(StrToInt('$' + Hex));
            end;
          '0'..'9':
            begin
              var N := Ord(V) - 48;
              var i := 1;
              while (i < 3) and CharInSet(Peek, ['0'..'9']) do
              begin
                N := N * 10 + Ord(Peek) - 48;
                Inc(Pos);
                Inc(i);
              end;
              V := Char(N);
            end;
        end;
      end;
      Token := Token + V;
    end;
    Inc(Pos);
    Exit;
  end;

  Token := C;
  Inc(Pos);
  var Pair := Token + Peek;
  if (Pair = '==') or (Pair = '~=') or (Pair = '<=') or (Pair = '>=') or (Pair = '//') or
    (Pair = '<<') or (Pair = '>>') or (Pair = '..') or (Pair = '::') then
  begin
    Token := Pair;
    Inc(Pos);
    if (Pair = '..') and (Peek = '.') then
    begin
      Token := '...';
      Inc(Pos);
    end;
  end;
end;

procedure TParser.Need(const S: string);
begin
  if not Accept(S) then
    raise EReadError.CreateFmt('MGW script line %d: expected %s, got %s', [Line, S, Token]);
end;

function TParser.Accept(const S: string): Boolean;
begin
  Result := Token = S;
  if Result then
    Next;
end;

function TParser.Name: string;
begin
  if Kind <> 'name' then
    raise EReadError.CreateFmt('MGW line %d: identifier expected, got %s', [Line, Token]);

  Result := Token;
  Next;
end;

function TParser.Node(const Op: string; const Children: array of TScriptNode): TScriptNode;
begin
  Result := Engine.NewNode(Op);
  for var C in Children do
    Result.Children := Result.Children + [C];
end;

function Priority(const Op: string): Integer;
begin
  Result := 0;
  if Op = 'or' then
    Result := 1
  else if Op = 'and' then
    Result := 2
  else if (Op = '==') or (Op = '~=') or (Op = '<') or (Op = '>') or (Op = '<=') or (Op = '>=') then
    Result := 3
  else if Op = '|' then
    Result := 4
  else if Op = '~' then
    Result := 5
  else if Op = '&' then
    Result := 6
  else if (Op = '<<') or (Op = '>>') then
    Result := 7
  else if Op = '..' then
    Result := 8
  else if (Op = '+') or (Op = '-') then
    Result := 9
  else if (Op = '*') or (Op = '/') or (Op = '//') or (Op = '%') then
    Result := 10
  else if Op = '^' then
    Result := 12;
end;

function TParser.Expr(MinPriority: Integer): TScriptNode;
begin
  Inc(Depth);
  if Depth > 256 then
    raise EReadError.Create('MGW expression nesting limit');

  try
    if (Token = 'not') or (Token = '-') or (Token = '#') or (Token = '~') then
    begin
      var Op := Token;
      Next;
      Result := Node('unary', [Expr(11)]);
      Result.Text := Op;
    end
    else
      Result := Atom;
    while (Kind <> 'string') and (Priority(Token) > MinPriority) do
    begin
      var Op := Token;
      var P := Priority(Op);
      Next;
      if (Op = '^') or (Op = '..') then
        Dec(P);
      Result := Node('binary', [Result, Expr(P)]);
      Result.Text := Op;
    end;
  finally
    Dec(Depth);
  end;
end;

function TParser.Func: TScriptNode;
begin
  Result := Node('function', []);
  Need('(');
  if not Accept(')') then
  begin
    repeat
      if Accept('...') then
      begin
        Result.Text := 'vararg';
        Break;
      end;

      Result.Names := Result.Names + [Name];
    until not Accept(',');
    Need(')');
  end;
  Result.Children := [Block];
  Need('end');
end;

function TParser.Atom: TScriptNode;
begin
  if Kind = 'number' then
  begin
    Result := Node('number', []);
    if Token.StartsWith('0x', True) then
      Result.Number := StrToInt64('$' + Copy(Token, 3, MaxInt))
    else
      Result.Number := StrToFloat(Token, TFormatSettings.Invariant);
    Next;
  end
  else if Kind = 'string' then
  begin
    Result := Node('string', []);
    Result.Text := Token;
    Next;
  end
  else if Accept('nil') then
    Result := Node('nil', [])
  else if Accept('true') then
    Result := Node('true', [])
  else if Accept('false') then
    Result := Node('false', [])
  else if Accept('...') then
    Result := Node('vararg', [])
  else if Accept('function') then
    Result := Func
  else if Accept('{') then
  begin
    Result := Node('table', []);
    while not Accept('}') do
    begin
      var Entry: TScriptNode;
      if Accept('[') then
      begin
        var Key := Expr;
        Need(']');
        Need('=');
        Entry := Node('field', [Key, Expr]);
      end
      else
      begin
        var Value := Expr;
        if Accept('=') then
        begin
          if Value.Op <> 'name' then
            raise EReadError.Create('MGW invalid table field');

          Value.Op := 'string';
          Entry := Node('field', [Value, Expr]);
        end
        else
          Entry := Node('element', [Value]);
      end;
      Result.Children := Result.Children + [Entry];
      if not Accept(',') and not Accept(';') then
      begin
        Need('}');
        Break;
      end;
    end;
  end
  else if Accept('(') then
  begin
    Result := Node('paren', [Expr]);
    Need(')');
  end
  else
  begin
    Result := Node('name', []);
    Result.Text := Name;
  end;
  while True do
  begin
    if Accept('.') then
    begin
      var Key := Node('string', []);
      Key.Text := Name;
      Result := Node('index', [Result, Key]);
    end
    else if Accept('[') then
    begin
      Result := Node('index', [Result, Expr]);
      Need(']');
    end
    else
    begin
      var Method := '';
      if Accept(':') then
        Method := Name;
      var Args: TScriptNode;
      if Accept('(') then
      begin
        if Accept(')') then
          Args := Node('list', [])
        else
        begin
          Args := List;
          Need(')');
        end;
      end
      else if (Token = '{') or (Kind = 'string') then
        Args := Node('list', [Atom])
      else
      begin
        if Method <> '' then
          raise EReadError.Create('MGW method call expected');

        Break;
      end;
      Result := Node('call', [Result, Args]);
      Result.Text := Method;
    end;
  end;
end;

function TParser.List: TScriptNode;
begin
  Result := Node('list', [Expr]);
  while Accept(',') do
    Result.Children := Result.Children + [Expr];
end;

function TParser.Block: TScriptNode;
begin
  Result := Node('block', []);
  while (Token <> 'end') and (Token <> 'else') and (Token <> 'elseif') and (Token <> 'until') and (Token <> '<eof>') do
    if not Accept(';') then
      Result.Children := Result.Children + [Statement];
end;

function TParser.Statement: TScriptNode;
begin
  if Accept('local') then
  begin
    Result := Node('local', []);
    if Accept('function') then
    begin
      Result.Op := 'localfunc';
      Result.Names := [Name];
      Result.Children := [Func];
    end
    else
    begin
      Result.Names := [Name];
      while Accept(',') do
        Result.Names := Result.Names + [Name];
      if Accept('=') then
        Result.Children := [List]
      else
        Result.Children := [Node('list', [])];
    end;
  end
  else if Accept('function') then
  begin
    var Target := Node('name', []);
    Target.Text := Name;
    while Accept('.') do
    begin
      var Key := Node('string', []);
      Key.Text := Name;
      Target := Node('index', [Target, Key]);
    end;
    var Method := Accept(':');
    if Method then
    begin
      var Key := Node('string', []);
      Key.Text := Name;
      Target := Node('index', [Target, Key]);
    end;
    var Value := Func;
    if Method then
      Value.Names := TArray<string>.Create('self') + Value.Names;
    Result := Node('assign', [Node('list', [Target]), Node('list', [Value])]);
  end
  else if Accept('if') then
  begin
    Result := Node('if', []);
    repeat
      var Condition := Expr;
      Need('then');
      Result.Children := Result.Children + [Condition, Block];
    until not Accept('elseif');
    if Accept('else') then
      Result.Children := Result.Children + [Node('true', []), Block];
    Need('end');
  end
  else if Accept('while') then
  begin
    var Condition := Expr;
    Need('do');
    Result := Node('while', [Condition, Block]);
    Need('end');
  end
  else if Accept('repeat') then
  begin
    var Body := Block;
    Need('until');
    Result := Node('repeat', [Body, Expr]);
  end
  else if Accept('do') then
  begin
    Result := Node('do', [Block]);
    Need('end');
  end
  else if Accept('for') then
  begin
    var FirstName := Name;
    if Accept('=') then
    begin
      var First := Expr;
      Need(',');
      var Last := Expr;
      var Delta: TScriptNode;
      if Accept(',') then
        Delta := Expr
      else
      begin
        Delta := Node('number', []);
        Delta.Number := 1;
      end;
      Need('do');
      Result := Node('for', [First, Last, Delta, Block]);
      Result.Names := [FirstName];
      Need('end');
    end
    else
    begin
      Result := Node('each', []);
      Result.Names := [FirstName];
      while Accept(',') do
        Result.Names := Result.Names + [Name];
      Need('in');
      var Values := List;
      Need('do');
      Result.Children := [Values, Block];
      Need('end');
    end;
  end
  else if Accept('return') then
  begin
    Result := Node('return', []);
    if (Token = 'end') or (Token = 'else') or (Token = 'elseif') or (Token = 'until') or (Token = '<eof>') or (Token = ';') then
      Result.Children := [Node('list', [])]
    else
      Result.Children := [List];
  end
  else if Accept('break') then
    Result := Node('break', [])
  else
  begin
    var Targets := List;
    if Accept('=') then
      Result := Node('assign', [Targets, List])
    else
    begin
      if (Length(Targets.Children) <> 1) or (Targets.Children[0].Op <> 'call') then
        raise EReadError.CreateFmt('MGW line %d: statement expected (%s)', [Line, Token]);

      Result := Node('eval', [Targets.Children[0]]);
    end;
  end;
end;

constructor TScriptEngine.Create;
begin
  inherited;
  FObjects := TObjectList<TScriptObject>.Create;
  FNodes := TObjectList<TScriptNode>.Create;
  FNatives := TList<TScriptNative>.Create;
  FGlobals := NewEnv(nil);
  BeginFrame;
end;

destructor TScriptEngine.Destroy;
begin
  FNodes.Free;
  FObjects.Free;
  FNatives.Free;
  inherited;
end;

function TScriptEngine.NewNode(const Op: string): TScriptNode;
begin
  if FNodes.Count >= 500000 then
    raise EReadError.Create('MGW syntax tree limit');

  Result := TScriptNode.Create;
  Result.Op := Op;
  FNodes.Add(Result);
end;

function TScriptEngine.NewTable: TScriptTable;
begin
  Result := TScriptTable.Create;
  FObjects.Add(Result);
end;

function TScriptEngine.NewEnv(Parent: TScriptEnv): TScriptEnv;
begin
  Result := TScriptEnv.Create(Parent);
  FObjects.Add(Result);
end;

function TScriptEngine.NewNative(const Callback: TScriptNative): TScriptValue;
begin
  var F := TScriptFunction.Create;
  F.Native := Callback;
  F.NativeId := FNatives.Count;
  FNatives.Add(Callback);
  FObjects.Add(F);
  Result := TScriptValue.ObjectValue(F);
end;

function TScriptEngine.IsAlive(Obj: TScriptObject): Boolean;
begin
  Result := FObjects.Contains(Obj);
end;

procedure TScriptEngine.BeginFrame;
begin
  FSteps := 0;
end;

procedure TScriptEngine.Step;
begin
  Inc(FSteps);
  if FSteps > 5000000 then
    raise EReadError.Create('MGW script execution limit exceeded');

  if FObjects.Count > 1000000 then
    raise EReadError.Create('MGW script object limit exceeded');
end;

function TScriptEngine.Get(const Target, Key: TScriptValue): TScriptValue;
begin
  Step;
  if Target.Kind = skString then
    Exit(Get(FGlobals.Get('string'), Key));

  if not (Target.Obj is TScriptTable) then
    raise EReadError.Create('MGW cannot index ' + Target.AsString + ' with ' + Key.AsString);

  var T := TScriptTable(Target.Obj);
  Result := T.RawGet(Key);
  if Result.Kind <> skNil then
    Exit;

  if T.Meta <> nil then
  begin
    var Index := T.Meta.RawGet(TScriptValue.Str('__index'));
    if Index.Obj is TScriptTable then
      Result := Get(Index, Key)
    else if Index.Kind <> skNil then
      Result := SV(Call(Index, [Target, Key]));
  end;
end;

procedure TScriptEngine.Put(const Target, Key, Value: TScriptValue);
begin
  Step;
  if not (Target.Obj is TScriptTable) then
    raise EReadError.Create('MGW cannot assign field ' + Key.AsString + ' of ' + Target.AsString);

  var T := TScriptTable(Target.Obj);
  if (T.RawGet(Key).Kind = skNil) and (T.Meta <> nil) then
  begin
    var Index := T.Meta.RawGet(TScriptValue.Str('__newindex'));
    if Index.Obj is TScriptTable then
    begin
      Put(Index, Key, Value);
      Exit;
    end
    else if Index.Kind <> skNil then
    begin
      Call(Index, [Target, Key, Value]);
      Exit;
    end;
  end;

  T.RawSet(Key, Value);
end;

function TScriptEngine.Call(const Func: TScriptValue; const Args: TScriptValues): TScriptValues;
begin
  Step;
  Inc(FDepth);
  try
    if FDepth > 256 then
      raise EReadError.Create('MGW call depth limit');

    if Func.Obj is TScriptTable then
    begin
      var T := TScriptTable(Func.Obj);
      if T.Meta <> nil then
        Exit(Call(T.Meta.RawGet(TScriptValue.Str('__call')), TScriptValues.Create(Func) + Args));
    end;

    if not (Func.Obj is TScriptFunction) then
      raise EReadError.Create('MGW attempt to call ' + Func.AsString);

    var F := TScriptFunction(Func.Obj);
    if Assigned(F.Native) then
      Exit(F.Native(Args));

    var Env := NewEnv(F.Env);
    for var i := 0 to High(F.Body.Names) do
      Env.Put(F.Body.Names[i], SV(Args, i), True);
    if F.Body.Text = 'vararg' then
      Env.Extra := Copy(Args, Length(F.Body.Names), Length(Args));
    Result := nil;
    Exec(F.Body.Children[0], Env, Result);
  finally
    Dec(FDepth);
  end;
end;

function TScriptEngine.Run(const Source: string): TScriptValues;
begin
  var Parser := TParser.Create(Self, Source);
  try
    var Body := Parser.Block;
    Parser.Need('<eof>');
    Result := nil;
    Exec(Body, NewEnv(FGlobals), Result);
  finally
    Parser.Free;
  end;
end;

function TScriptEngine.One(Node: TScriptNode; Env: TScriptEnv): TScriptValue;
begin
  Result := SV(Eval(Node, Env));
end;

function TScriptEngine.ExprList(Node: TScriptNode; Env: TScriptEnv): TScriptValues;
begin
  Result := nil;
  for var i := 0 to High(Node.Children) do
    if i = High(Node.Children) then
      Result := Result + Eval(Node.Children[i], Env)
    else
      Result := Result + [One(Node.Children[i], Env)];
end;

function Equal(const A, B: TScriptValue): Boolean;
begin
  Result := False;
  if A.Kind <> B.Kind then
    Exit;

  case A.Kind of
    skNil:
      Result := True;
    skBool, skNumber:
      Result := A.Number = B.Number;
    skString:
      Result := A.Text = B.Text;
    skObject:
      Result := A.Obj = B.Obj;
  end;
end;

function TScriptEngine.Eval(Node: TScriptNode; Env: TScriptEnv): TScriptValues;
begin
  Step;
  var Op := Node.Op;
  var V := TScriptValue.NilValue;
  if Op = 'nil' then
    V := TScriptValue.NilValue
  else if Op = 'number' then
    V := TScriptValue.Num(Node.Number)
  else if Op = 'string' then
    V := TScriptValue.Str(Node.Text)
  else if Op = 'true' then
    V := TScriptValue.Bool(True)
  else if Op = 'false' then
    V := TScriptValue.Bool(False)
  else if Op = 'name' then
    V := Env.Get(Node.Text)
  else if Op = 'vararg' then
    Exit(Env.Extra)
  else if Op = 'paren' then
    V := One(Node.Children[0], Env)
  else if Op = 'index' then
    V := Get(One(Node.Children[0], Env), One(Node.Children[1], Env))
  else if Op = 'function' then
  begin
    var F := TScriptFunction.Create;
    F.NativeId := -1;
    F.Body := Node;
    F.Env := Env;
    FObjects.Add(F);
    V := TScriptValue.ObjectValue(F);
  end
  else if Op = 'call' then
  begin
    var F := One(Node.Children[0], Env);
    var Args := ExprList(Node.Children[1], Env);
    if Node.Text <> '' then
    begin
      Args := TScriptValues.Create(F) + Args;
      F := Get(F, TScriptValue.Str(Node.Text));
    end;
    Exit(Call(F, Args));
  end
  else if Op = 'table' then
  begin
    var T := NewTable;
    var Index := 1;
    for var i := 0 to High(Node.Children) do
    begin
      var E := Node.Children[i];
      if E.Op = 'field' then
        T.RawSet(One(E.Children[0], Env), One(E.Children[1], Env))
      else
      begin
        var Values: TScriptValues;
        if i = High(Node.Children) then
          Values := Eval(E.Children[0], Env)
        else
          Values := [One(E.Children[0], Env)];
        for var Value in Values do
        begin
          T.RawSet(TScriptValue.Num(Index), Value);
          Inc(Index);
        end;
      end;
    end;
    V := TScriptValue.ObjectValue(T);
  end
  else if Op = 'unary' then
  begin
    var A := One(Node.Children[0], Env);
    if Node.Text = 'not' then
      V := TScriptValue.Bool(not A.Truth)
    else if Node.Text = '-' then
      V := TScriptValue.Num(-A.AsNumber)
    else if Node.Text = '~' then
      V := TScriptValue.Num(not Trunc(A.AsNumber))
    else if A.Kind = skString then
      V := TScriptValue.Num(Length(A.Text))
    else if A.Obj is TScriptTable then
      V := TScriptValue.Num(TScriptTable(A.Obj).Count)
    else
      raise EReadError.Create('MGW invalid length operand');
  end
  else if Op = 'binary' then
  begin
    var A := One(Node.Children[0], Env);
    Op := Node.Text;
    if Op = 'and' then
    begin
      if not A.Truth then
        Exit(TScriptValues.Create(A));

      Exit(TScriptValues.Create(One(Node.Children[1], Env)));
    end;
    if Op = 'or' then
    begin
      if A.Truth then
        Exit(TScriptValues.Create(A));

      Exit(TScriptValues.Create(One(Node.Children[1], Env)));
    end;
    var B := One(Node.Children[1], Env);
    if Op = '==' then
      V := TScriptValue.Bool(Equal(A, B))
    else if Op = '~=' then
      V := TScriptValue.Bool(not Equal(A, B))
    else if Op = '..' then
      V := TScriptValue.Str(A.AsString + B.AsString)
    else if (Op = '<') or (Op = '>') or (Op = '<=') or (Op = '>=') then
    begin
      var C: Integer;
      if (A.Kind = skString) and (B.Kind = skString) then
        C := CompareStr(A.Text, B.Text)
      else if A.AsNumber < B.AsNumber then
        C := -1
      else if A.AsNumber > B.AsNumber then
        C := 1
      else
        C := 0;
      V := TScriptValue.Bool(((Op = '<') and (C < 0)) or ((Op = '>') and (C > 0)) or ((Op = '<=') and (C <= 0)) or ((Op = '>=') and (C >= 0)));
    end
    else
    begin
      var X := A.AsNumber;
      var Y := B.AsNumber;
      var N: Double;
      if Op = '+' then
        N := X + Y
      else if Op = '-' then
        N := X - Y
      else if Op = '*' then
        N := X * Y
      else if Op = '/' then
        N := X / Y
      else if Op = '//' then
        N := Floor(X / Y)
      else if Op = '%' then
        N := X - Floor(X / Y) * Y
      else if Op = '^' then
        N := Power(X, Y)
      else if Op = '&' then
        N := Int64(Trunc(X)) and Int64(Trunc(Y))
      else if Op = '|' then
        N := Int64(Trunc(X)) or Int64(Trunc(Y))
      else if Op = '~' then
        N := Int64(Trunc(X)) xor Int64(Trunc(Y))
      else if Op = '<<' then
        N := Int64(UInt64(Trunc(X)) shl Integer(Trunc(Y)))
      else if Op = '>>' then
        N := UInt64(Trunc(X)) shr Integer(Trunc(Y))
      else
        raise EReadError.Create('MGW invalid operator ' + Op);

      V := TScriptValue.Num(N);
    end;
  end
  else
    raise EReadError.Create('MGW unknown expression ' + Op);

  Result := [V];
end;

procedure TScriptEngine.Assign(Node: TScriptNode; Env: TScriptEnv; const Value: TScriptValue);
begin
  if Node.Op = 'name' then
    Env.Put(Node.Text, Value, False)
  else if Node.Op = 'index' then
    Put(One(Node.Children[0], Env), One(Node.Children[1], Env), Value)
  else
    raise EReadError.Create('MGW invalid assignment target');
end;

function TScriptEngine.Exec(Node: TScriptNode; Env: TScriptEnv; out Returned: TScriptValues): Integer;
begin
  Step;
  Result := 0;
  Returned := nil;
  var Op := Node.Op;
  if Op = 'block' then
  begin
    for var C in Node.Children do
    begin
      Result := Exec(C, Env, Returned);
      if Result <> 0 then
        Exit;
    end;
  end
  else if Op = 'return' then
  begin
    Returned := ExprList(Node.Children[0], Env);
    Result := 1;
  end
  else if Op = 'break' then
    Result := 2
  else if Op = 'eval' then
    Eval(Node.Children[0], Env)
  else if (Op = 'local') or (Op = 'localfunc') then
  begin
    var Values: TScriptValues;
    if Op = 'localfunc' then
    begin
      Env.Put(Node.Names[0], TScriptValue.NilValue, True);
      Values := Eval(Node.Children[0], Env);
    end
    else
      Values := ExprList(Node.Children[0], Env);
    for var i := 0 to High(Node.Names) do
      Env.Put(Node.Names[i], SV(Values, i), True);
  end
  else if Op = 'assign' then
  begin
    var Values := ExprList(Node.Children[1], Env);

    // Evaluate indexed lvalues before changing any variable in a multiple assignment.
    var Targets, Keys: TScriptValues;
    for var C in Node.Children[0].Children do
      if C.Op = 'index' then
      begin
        Targets := Targets + [One(C.Children[0], Env)];
        Keys := Keys + [One(C.Children[1], Env)];
      end
      else
      begin
        Targets := Targets + [TScriptValue.NilValue];
        Keys := Keys + [TScriptValue.NilValue];
      end;
    for var i := 0 to High(Node.Children[0].Children) do
    begin
      var C := Node.Children[0].Children[i];
      if C.Op = 'index' then
        Put(Targets[i], Keys[i], SV(Values, i))
      else
        Assign(C, Env, SV(Values, i));
    end;
  end
  else if Op = 'do' then
    Result := Exec(Node.Children[0], NewEnv(Env), Returned)
  else if Op = 'if' then
  begin
    var i := 0;
    while i < Length(Node.Children) do
    begin
      if One(Node.Children[i], Env).Truth then
        Exit(Exec(Node.Children[i + 1], NewEnv(Env), Returned));
      Inc(i, 2);
    end;
  end
  else if Op = 'while' then
  begin
    while One(Node.Children[0], Env).Truth do
    begin
      Result := Exec(Node.Children[1], NewEnv(Env), Returned);
      if Result = 1 then
        Exit;

      if Result = 2 then
        Break;
    end;
    Result := 0;
  end
  else if Op = 'repeat' then
  begin
    repeat
      var Scope := NewEnv(Env);
      Result := Exec(Node.Children[0], Scope, Returned);
      if Result = 1 then
        Exit;

      if Result = 2 then
        Break;

      if One(Node.Children[1], Scope).Truth then
        Break;
    until False;
    Result := 0;
  end
  else if Op = 'for' then
  begin
    var V := One(Node.Children[0], Env).AsNumber;
    var Last := One(Node.Children[1], Env).AsNumber;
    var Delta := One(Node.Children[2], Env).AsNumber;
    if Delta = 0 then
      raise EReadError.Create('MGW zero loop step');

    while ((Delta > 0) and (V <= Last)) or ((Delta < 0) and (V >= Last)) do
    begin
      var Scope := NewEnv(Env);
      Scope.Put(Node.Names[0], TScriptValue.Num(V), True);
      Result := Exec(Node.Children[3], Scope, Returned);
      if Result = 1 then
        Exit;

      if Result = 2 then
        Break;
      V := V + Delta;
    end;
    Result := 0;
  end
  else if Op = 'each' then
  begin
    var Iter := ExprList(Node.Children[0], Env);
    var Control := SV(Iter, 2);
    repeat
      var Values := Call(SV(Iter), [SV(Iter, 1), Control]);
      Control := SV(Values);
      if Control.Kind = skNil then
        Break;

      var Scope := NewEnv(Env);
      for var i := 0 to High(Node.Names) do
        Scope.Put(Node.Names[i], SV(Values, i), True);
      Result := Exec(Node.Children[1], Scope, Returned);
      if Result = 1 then
        Exit;

      if Result = 2 then
        Break;
    until False;
    Result := 0;
  end
  else
    raise EReadError.Create('MGW unknown statement ' + Op);
end;

procedure TScriptEngine.Collect(const Roots: TScriptValues);
begin
  for var O in FObjects do
    O.Marked := False;
  FGlobals.Mark;
  for var V in Roots do
    if V.Obj <> nil then
      V.Obj.Mark;
  for var i := FObjects.Count - 1 downto 0 do
    if not FObjects[i].Marked then
      FObjects.Delete(i);
end;

procedure StateString(Archive: TStateArchive; var Text: string);
begin
  var Bytes: TBytes;
  if not Archive.Loading then
    Bytes := TEncoding.UTF8.GetBytes(Text);
  var Count := Length(Bytes);
  Archive.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 4 * 1024 * 1024) then
    raise EReadError.Create('MGW snapshot string limit');

  SetLength(Bytes, Count);
  if Count > 0 then
    Archive.Field(Bytes[0], Count);
  if Archive.Loading then
    Text := TEncoding.UTF8.GetString(Bytes);
end;

procedure TScriptEngine.TransferValue(Archive: TStateArchive; var Value: TScriptValue);
begin
  var Kind := Ord(Value.Kind);
  Archive.Field(Kind, SizeOf(Kind));
  if (Kind < 0) or (Kind > Ord(High(TScriptKind))) then
    raise EReadError.Create('MGW invalid snapshot value');

  if Archive.Loading then
  begin
    Value := TScriptValue.NilValue;
    Value.Kind := TScriptKind(Kind);
  end;
  case Value.Kind of
    skBool, skNumber:
      begin
        Archive.Field(Value.Number, SizeOf(Value.Number));
        if IsNan(Value.Number) or IsInfinite(Value.Number) then
          raise EReadError.Create('MGW invalid snapshot number');
      end;
    skString:
      StateString(Archive, Value.Text);
    skObject:
      begin
        var Index := -1;
        if not Archive.Loading then
          Index := FObjects.IndexOf(Value.Obj);
        Archive.Field(Index, SizeOf(Index));
        if (Index < 0) or (Index >= FObjects.Count) then
          raise EReadError.Create('MGW invalid object reference');
        if Archive.Loading then
          Value.Obj := FObjects[Index];
      end;
  end;
end;

procedure TScriptEngine.TransferTable(Archive: TStateArchive; var Value: TScriptTable);
begin
  var V := TScriptValue.ObjectValue(Value);
  TransferValue(Archive, V);
  if (V.Obj <> nil) and not (V.Obj is TScriptTable) then
    raise EReadError.Create('MGW invalid table reference');

  Value := TScriptTable(V.Obj);
end;

procedure TScriptEngine.SerializeState(Archive: TStateArchive);

  procedure Environment(var Env: TScriptEnv);
  begin
    var V := TScriptValue.ObjectValue(Env);
    TransferValue(Archive, V);
    if (V.Obj <> nil) and not (V.Obj is TScriptEnv) then
      raise EReadError.Create('MGW invalid environment');

    Env := TScriptEnv(V.Obj);
  end;

  procedure Values(var Items: TScriptValues);
  begin
    var Count := Length(Items);
    Archive.Field(Count, SizeOf(Count));
    if (Count < 0) or (Count > 65536) then
      raise EReadError.Create('MGW invalid tuple');

    SetLength(Items, Count);
    for var i := 0 to Count - 1 do
      TransferValue(Archive, Items[i]);
  end;

begin
  var Nodes := FNodes.Count;
  Archive.Field(Nodes, SizeOf(Nodes));
  if Nodes <> FNodes.Count then
    raise EReadError.Create('MGW incompatible script version');

  var Count := FObjects.Count;
  Archive.Field(Count, SizeOf(Count));
  if (Count < 1) or (Count > 1000000) then
    raise EReadError.Create('MGW snapshot object limit');

  if Archive.Loading then
    FObjects.Clear;
  for var i := 0 to Count - 1 do
  begin
    var Kind := 0;
    if not Archive.Loading then
    begin
      if FObjects[i] is TScriptEnv then
        Kind := 1
      else if FObjects[i] is TScriptFunction then
        Kind := 2;
    end;
    Archive.Field(Kind, SizeOf(Kind));
    if Archive.Loading then
      case Kind of
        0:
          FObjects.Add(TScriptTable.Create);
        1:
          FObjects.Add(TScriptEnv.Create(nil));
        2:
          FObjects.Add(TScriptFunction.Create);
      else
        raise EReadError.Create('MGW invalid snapshot object');
      end;
  end;

  for var Obj in FObjects do
  begin
    if Obj is TScriptTable then
    begin
      var T := TScriptTable(Obj);
      TransferTable(Archive, T.Meta);
      var Size := T.Entries.Count;
      Archive.Field(Size, SizeOf(Size));
      if (Size < 0) or (Size > 1000000) then
        raise EReadError.Create('MGW table limit');

      if Archive.Loading then
      begin
        for var i := 1 to Size do
        begin
          var K, V: TScriptValue;
          TransferValue(Archive, K);
          TransferValue(Archive, V);
          T.RawSet(K, V);
        end;
      end
      else
        for var E in T.Entries.Values do
        begin
          var K := E.Key;
          var V := E.Value;
          TransferValue(Archive, K);
          TransferValue(Archive, V);
        end;
    end
    else if Obj is TScriptEnv then
    begin
      var Env := TScriptEnv(Obj);
      Environment(Env.Parent);
      Values(Env.Extra);
      var Size := Env.Values.Count;
      Archive.Field(Size, SizeOf(Size));
      if (Size < 0) or (Size > 1000000) then
        raise EReadError.Create('MGW environment limit');

      if Archive.Loading then
      begin
        for var i := 1 to Size do
        begin
          var Name: string;
          var V: TScriptValue;
          StateString(Archive, Name);
          TransferValue(Archive, V);
          Env.Put(Name, V, True);
        end;
      end
      else
        for var E in Env.Values do
        begin
          var Name := E.Key;
          var V := E.Value;
          StateString(Archive, Name);
          TransferValue(Archive, V);
        end;
    end
    else
    begin
      var F := TScriptFunction(Obj);
      Archive.Field(F.NativeId, SizeOf(F.NativeId));
      if F.NativeId >= 0 then
      begin
        if F.NativeId >= FNatives.Count then
          raise EReadError.Create('MGW invalid native function reference');

        F.Native := FNatives[F.NativeId];
      end
      else
      begin
        var Index := -1;
        if not Archive.Loading then
          Index := FNodes.IndexOf(F.Body);
        Archive.Field(Index, SizeOf(Index));
        if (Index < 0) or (Index >= FNodes.Count) or (FNodes[Index].Op <> 'function') then
          raise EReadError.Create('MGW invalid function reference');

        F.Body := FNodes[Index];
        Environment(F.Env);
      end;
    end;
  end;
  Environment(FGlobals);

  if FGlobals = nil then
    raise EReadError.Create('MGW missing globals');
end;

end.

