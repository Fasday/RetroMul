program PSPDirectGraphTest;

{$APPTYPE CONSOLE}
{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic, vcPublished])}

uses
  System.SysUtils, System.Classes, System.Generics.Collections, PSP.State.Graph, PSP.State.Action;

type
  TRoot = class;
  TNotify = procedure(N: Cardinal) of object;
  TLeaf = class
    Name: string;
    Parent: TRoot;
    Samples: TArray<SmallInt>;
    Callback: TNotify;
  end;
  TSlots = array[0..3] of TLeaf;
  TRoot = class
    Children: TObjectList<TLeaf>;
    Lookup: TDictionary<Cardinal, TLeaf>;
    Slots: TSlots;
    Current: TLeaf;
    Last: Cardinal;
    Pending: IPSPStateAction;
    HostOnly: Pointer;
    constructor Create;
    destructor Destroy; override;
    procedure Notify(N: Cardinal);
    procedure ActionNotify(Action: TPSPStateAction; N: Cardinal);
  end;

constructor TRoot.Create;
begin
  inherited;
  Children := TObjectList<TLeaf>.Create(True);
  Lookup := TDictionary<Cardinal, TLeaf>.Create;
  var L := TLeaf.Create;
  L.Name := 'constructor child'; L.Parent := Self;
  Children.Add(L); Lookup.Add(1, L); Slots[0] := L; Current := L;
end;

destructor TRoot.Destroy;
begin
  Lookup.Free; Children.Free;
  inherited;
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
      Source.HostOnly := Pointer(123); Dest.HostOnly := Pointer(456);
      Source.Current.Name := 'saved child';
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
      Stream.Size := Stream.Size - 1; Stream.Position := 0;
      Reader := TPSPGraph.Create(Schema, Roots);
      var Rejected := False;
      try
        Reader.Bind('root', Dest, ['*']);
        try Reader.Load(Stream); except on EReadError do Rejected := True; end;
      finally Reader.Free; end;
      if not Rejected or (Dest.Last <> 127) or (Dest.Current.Name <> 'saved child') then
        raise Exception.Create('Failed graph load changed its destination');
      Writeln('PASS truncated graph leaves destination unchanged');
    finally
      Stream.Free; Dest.Free; Source.Free; Schema.Free;
    end;
  except
    on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
  end;
end.
