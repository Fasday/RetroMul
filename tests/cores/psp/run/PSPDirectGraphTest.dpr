program PSPDirectGraphTest;

{$APPTYPE CONSOLE}
{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic, vcPublished])}

uses
  System.SysUtils, System.Classes, System.Generics.Collections, PSP.State.Graph, PSP.State.Action;

type
  TRoot = class;
  TNotify = procedure(N: Cardinal) of object;
  TProbe = class
    A, B: Cardinal;
  end;
  TLeaf = class
    Name: string;
    Parent: TRoot;
    Samples: TArray<SmallInt>;
    Callback: TNotify;
    class function NewInstance: TObject; override;
    procedure FreeInstance; override;
  end;
  TFactoryNode = class(TInterfacedObject)
    Child: TLeaf;
    Work: TList<Integer>;
    constructor Create;
    destructor Destroy; override;
  end;
  TSlots = array[0..3] of TLeaf;
  TRoot = class
    Children: TObjectList<TLeaf>;
    Lookup: TDictionary<Cardinal, TLeaf>;
    Slots: TSlots;
    Current: TLeaf;
    Last: Cardinal;
    Pending: IPSPStateAction;
    FactoryNode: TFactoryNode;
    HostOnly: Pointer;
    constructor Create;
    destructor Destroy; override;
    procedure Notify(N: Cardinal);
    procedure ActionNotify(Action: TPSPStateAction; N: Cardinal);
  end;

var
  LiveLeaves: Integer;

class function TLeaf.NewInstance: TObject;
begin
  Result := inherited NewInstance;
  Inc(LiveLeaves);
end;

procedure TLeaf.FreeInstance;
begin
  Dec(LiveLeaves);
  inherited;
end;

constructor TFactoryNode.Create;
begin
  inherited;
  Child := TLeaf.Create;
  Work := TList<Integer>.Create;
  Work.Add(42);
end;

destructor TFactoryNode.Destroy;
begin
  Work.Free; Child.Free;
  inherited;
end;

constructor TRoot.Create;
begin
  inherited;
  FactoryNode := TFactoryNode.Create;
  Children := TObjectList<TLeaf>.Create(True);
  Lookup := TDictionary<Cardinal, TLeaf>.Create;
  var L := TLeaf.Create;
  L.Name := 'constructor child'; L.Parent := Self;
  Children.Add(L); Lookup.Add(1, L); Slots[0] := L; Current := L;
end;

destructor TRoot.Destroy;
begin
  FactoryNode.Free; Lookup.Free; Children.Free;
  inherited;
end;

procedure FieldCompatibility;
var
  Source, Dest: TProbe;
  Schema: TPSPGraphSchema;
  Roots: TPSPGraphRoots;
  function Save(const Omit: string): TBytes;
  begin
    var Old := TPSPGraphSchema.Create;
    var Stream := TMemoryStream.Create;
    var Graph := TPSPGraph.Create(Old, Roots);
    try
      if Omit = '' then Old.AddClass(TProbe, []) else Old.AddClass(TProbe, [Omit]);
      Graph.Bind('probe', Source, ['*']); Graph.Save(Stream);
      SetLength(Result, Stream.Size);
      Move(Stream.Memory^, Result[0], Length(Result));
    finally Graph.Free; Stream.Free; Old.Free; end;
  end;
  procedure Load(const Data: TBytes; Reject: Boolean);
  begin
    Dest.A := 111; Dest.B := 222;
    var Stream := TBytesStream.Create(Data);
    var Graph := TPSPGraph.Create(Schema, Roots);
    var Rejected := False;
    try
      Graph.Bind('probe', Dest, ['*']);
      try Graph.Load(Stream); except on EReadError do Rejected := True; end;
    finally Graph.Free; Stream.Free; end;
    if (Rejected <> Reject) or (Reject and ((Dest.A <> 111) or (Dest.B <> 222))) then
      raise Exception.Create('Field compatibility rejection was not atomic');
    if not Reject and (Dest.A <> Source.A) then raise Exception.Create('Required field was lost');
  end;
  function RenameB(const Data: TBytes; Name: Byte): TBytes;
  begin
    Result := Copy(Data);
    var Pattern := TEncoding.UTF8.GetBytes('TProbe.B');
    for var I := 0 to Length(Result) - Length(Pattern) do
      if CompareMem(@Result[I], @Pattern[0], Length(Pattern)) then
      begin Result[I + High(Pattern)] := Name; Exit; end;
    raise Exception.Create('Field mutation fixture not found');
  end;
begin
  Roots := Default(TPSPGraphRoots);
  Source := TProbe.Create; Dest := TProbe.Create; Schema := TPSPGraphSchema.Create;
  try
    Source.A := 7; Source.B := 8;
    Schema.AddClass(TProbe, []); Schema.Optional(TProbe, ['B']);
    Load(Save('B'), False);
    Load(Save('A'), True);
    var Data := Save('');
    Load(RenameB(Data, Ord('A')), True);
    Load(RenameB(Data, Ord('X')), True);
    Writeln('PASS optional old fields, required/duplicate/unknown field rejection');
  finally Schema.Free; Dest.Free; Source.Free; end;
end;

procedure TRoot.Notify(N: Cardinal);
begin Last := N; end;

procedure TRoot.ActionNotify(Action: TPSPStateAction; N: Cardinal);
begin
  Last := Cardinal(Action.Arg(0)) + N;
  if Action.Next <> nil then Action.Next.Run(Last);
end;

begin
  try
    var Schema := TPSPGraphSchema.Create;
    var Source := TRoot.Create;
    var Dest := TRoot.Create;
    var Stream := TMemoryStream.Create;
    try
      Schema.AddClass(TRoot, ['HostOnly']); Schema.AddClass(TLeaf, []);
      Schema.AddClass(TPSPStateAction, []);
      Schema.AddClass(TFactoryNode, ['Work']);
      Schema.Factory(TFactoryNode, function: TObject begin Result := TFactoryNode.Create; end);
      Source.HostOnly := Pointer(123); Dest.HostOnly := Pointer(456);
      Source.Current.Name := 'saved child';
      Source.FactoryNode.Child.Name := 'saved factory child';
      Source.Current.Samples := [-32768, 12, 32767];
      Source.Current.Callback := Source.Notify;
      Source.Slots[3] := Source.Current;
      Source.Pending := TPSPStateAction.Create(Source.ActionNotify, [Source.Current], [7], '',
        TPSPStateAction.Create(Source.ActionNotify, [], [100]));
      var Roots: TPSPGraphRoots := Default(TPSPGraphRoots);
      var Writer := TPSPGraph.Create(Schema, Roots);
      try Writer.Bind('root', Source, ['*']); Writer.Save(Stream); finally Writer.Free; end;
      Writeln('Direct graph bytes: ', Stream.Size);
      Stream.Position := 0;
      var Reader := TPSPGraph.Create(Schema, Roots);
      try Reader.Bind('root', Dest, ['*']); Reader.Load(Stream); finally Reader.Free; end;
      if (Dest.Current.Name <> 'saved child') or (Dest.Children[0] <> Dest.Current) or
        (Dest.Lookup[1] <> Dest.Current) or (Dest.Slots[3] <> Dest.Current) or
        (Dest.Current.Parent <> Dest) or (Dest.Current.Samples[0] <> -32768) or
        (Dest.HostOnly <> Pointer(456)) then raise Exception.Create('Graph did not preserve aliases/data/bindings');
      Dest.Current.Callback(99);
      if Dest.Last <> 99 then raise Exception.Create('Symbolic callback was not rebound');
      Dest.Pending.Run(20);
      if Dest.Last <> 127 then raise Exception.Create('Explicit continuation chain was not restored');
      Writeln('PASS direct graph aliases, collections, cycles, data and symbolic callback');
      if (Dest.FactoryNode.Child.Name <> 'saved factory child') or
        (Dest.FactoryNode.Work.Count <> 1) or (Dest.FactoryNode.Work[0] <> 42) or
        (LiveLeaves <> 4) then raise Exception.Create('Constructor child ownership was not preserved');
      Writeln('PASS factory scratch reconstruction and overwritten constructor child cleanup');
      // Produce the old action layout with the current writer's explicit skips.
      Stream.Size := 0; Stream.Position := 0;
      Schema.AddClass(TPSPStateAction, ['Failure', 'Arrays', 'Buffers', 'Texts', 'Results', 'Owned']);
      Writer := TPSPGraph.Create(Schema, Roots);
      try Writer.Bind('root', Source, ['*']); Writer.Save(Stream); finally Writer.Free; end;
      Schema.AddClass(TPSPStateAction, []);
      Schema.Optional(TPSPStateAction, ['Failure', 'Arrays', 'Buffers', 'Texts', 'Results', 'Owned']);
      Stream.Position := 0;
      Reader := TPSPGraph.Create(Schema, Roots);
      try Reader.Bind('root', Dest, ['*']); Reader.Load(Stream); finally Reader.Free; end;
      var OldAction := TPSPStateAction(Dest.Pending as TObject);
      if (OldAction.Failure <> nil) or (OldAction.Owned <> nil) or (Length(OldAction.Arrays) <> 0) or
        (Length(OldAction.Buffers) <> 0) or (Length(OldAction.Texts) <> 0) or
        (Length(OldAction.Results) <> 0) then raise Exception.Create('Old action payload did not default to empty');
      Dest.Pending.Run(20);
      if (Dest.Last <> 127) or (LiveLeaves <> 4) then raise Exception.Create('Old action chain did not resume');
      Writeln('PASS older action layout defaults only the listed optional payloads');
      // Force failure after fields apply, while filling the incoming dictionary.
      var Key: UInt64 := $13579BDF;
      Source.Lookup.Add(Cardinal(Key), Source.Current);
      Stream.Size := 0; Stream.Position := 0;
      Writer := TPSPGraph.Create(Schema, Roots);
      try Writer.Bind('root', Source, ['*']); Writer.Save(Stream); finally Writer.Free; end;
      Source.Lookup.Remove(Cardinal(Key));
      var Mutated := False;
      for var I := 0 to Stream.Size - SizeOf(Key) do
        if CompareMem(PByte(Stream.Memory) + I, @Key, SizeOf(Key)) then
        begin
          var Duplicate: UInt64 := 1;
          Move(Duplicate, (PByte(Stream.Memory) + I)^, SizeOf(Duplicate));
          Mutated := True; Break;
        end;
      if not Mutated then raise Exception.Create('Duplicate-key fixture was not found');
      Stream.Position := 0;
      Reader := TPSPGraph.Create(Schema, Roots);
      var Rejected := False;
      try
        Reader.Bind('root', Dest, ['*']);
        try Reader.Load(Stream); except on EListError do Rejected := True; end;
      finally Reader.Free; end;
      if not Rejected or (LiveLeaves <> 4) or (Dest.Last <> 127) or
        (Dest.Lookup.Count <> 1) or (Dest.Lookup[1] <> Dest.Current) or
        (Dest.FactoryNode.Child.Name <> 'saved factory child') or (Dest.FactoryNode.Work[0] <> 42) then
        raise Exception.Create('Graph installation failure did not restore ownership/bindings');
      Dest.Pending.Run(20);
      Writeln('PASS installation failure restores bindings and frees staged/constructor children');
      Stream.Size := Stream.Size - 1; Stream.Position := 0;
      Reader := TPSPGraph.Create(Schema, Roots);
      Rejected := False;
      try
        Reader.Bind('root', Dest, ['*']);
        try Reader.Load(Stream); except on EReadError do Rejected := True; end;
      finally Reader.Free; end;
      if not Rejected or (Dest.Last <> 127) or (Dest.Current.Name <> 'saved child') or
        (LiveLeaves <> 4) then
        raise Exception.Create('Failed graph load changed its destination');
      Writeln('PASS truncated graph leaves destination unchanged');
    finally
      Stream.Free; Dest.Free; Source.Free; Schema.Free;
    end;
    if LiveLeaves <> 0 then raise Exception.Create('Graph children leaked after cleanup');
    FieldCompatibility;
  except
    on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
  end;
end.
