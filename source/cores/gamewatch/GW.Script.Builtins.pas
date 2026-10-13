unit GW.Script.Builtins;

interface

uses
  GW.Script;

procedure InstallScriptLibrary(Engine: TScriptEngine);

implementation

uses
  System.SysUtils, System.Classes, System.Math;

procedure InstallScriptLibrary(Engine: TScriptEngine);
type
  TInvoke = reference to function(const Name: string; const A: TScriptValues): TScriptValues;
var
  Invoke: TInvoke;

  procedure Bind(const Name: string);
  begin
    var Func := Engine.NewNative(
      function(const A: TScriptValues): TScriptValues
      begin
        Result := Invoke(Name, A);
      end);

    var Parts := Name.Split(['.']);
    if Length(Parts) = 1 then
      Engine.Globals.Put(Name, Func, True)
    else
      TScriptTable(Engine.Globals.Get(Parts[0]).Obj).RawSet(TScriptValue.Str(Parts[1]), Func);
  end;

begin
  Invoke :=
    function(const Name: string; const A: TScriptValues): TScriptValues
    begin
      Result := nil;
      var V := SV(A);
      if Name = 'assert' then
      begin
        if not V.Truth then
          raise EReadError.Create('MGW assertion: ' + SV(A, 1).AsString);

        Exit(A);
      end;

      if Name = 'error' then
        raise EReadError.Create('MGW: ' + V.AsString);

      if Name = 'print' then
        Exit;

      if Name = 'type' then
      begin
        var S := 'nil';
        case V.Kind of
          skBool:
            S := 'boolean';
          skNumber:
            S := 'number';
          skString:
            S := 'string';
          skObject:
            if V.Obj is TScriptFunction then
              S := 'function'
            else
              S := 'table';
        end;
        Exit(TScriptValues.Create(TScriptValue.Str(S)));
      end;

      if Name = 'tostring' then
        Exit(TScriptValues.Create(TScriptValue.Str(V.AsString)));

      if Name = 'tonumber' then
      begin
        var N: Double;
        if (V.Kind = skNumber) or TryStrToFloat(V.AsString, N, TFormatSettings.Invariant) then
          Exit(TScriptValues.Create(TScriptValue.Num(V.AsNumber)));

        Exit(TScriptValues.Create(TScriptValue.NilValue));
      end;

      if Name = 'require' then
        Exit(TScriptValues.Create(Engine.Globals.Get(V.AsString)));

      if Name = 'setmetatable' then
      begin
        if not (V.Obj is TScriptTable) then
          raise EReadError.Create('MGW metatable target');

        TScriptTable(V.Obj).Meta := TScriptTable(SV(A, 1).Obj);
        Exit(TScriptValues.Create(V));
      end;

      if Name = 'getmetatable' then
        Exit(TScriptValues.Create(TScriptValue.ObjectValue(TScriptTable(V.Obj).Meta)));

      if Name = 'rawget' then
        Exit(TScriptValues.Create(TScriptTable(V.Obj).RawGet(SV(A, 1))));

      if Name = 'rawset' then
      begin
        TScriptTable(V.Obj).RawSet(SV(A, 1), SV(A, 2));
        Exit(TScriptValues.Create(V));
      end;

      if Name = 'select' then
      begin
        if (V.Kind = skString) and (V.Text = '#') then
          Exit(TScriptValues.Create(TScriptValue.Num(Length(A) - 1)));

        var i := Trunc(V.AsNumber);
        if i < 0 then
          i := Length(A) + i;
        Exit(Copy(A, i, Length(A)));
      end;

      if Name = 'next' then
      begin
        var Keys := TScriptTable(V.Obj).Entries.Values.ToArray;
        var Previous := SV(A, 1);
        var Found := Previous.Kind = skNil;
        for var Entry in Keys do
        begin
          if Found then
            Exit(TScriptValues.Create(Entry.Key, Entry.Value));

          if Entry.Key.Key = Previous.Key then
            Found := True;
        end;
        Exit(TScriptValues.Create(TScriptValue.NilValue));
      end;

      if Name = 'pairs' then
        Exit(TScriptValues.Create(Engine.Globals.Get('next'), V, TScriptValue.NilValue));

      if Name = 'ipairs' then
        Exit(TScriptValues.Create(Engine.Globals.Get('$ipairs'), V, TScriptValue.Num(0)));

      if Name = '$ipairs' then
      begin
        var Index := SV(A, 1).AsNumber + 1;
        var Value := Engine.Get(V, TScriptValue.Num(Index));
        if Value.Kind = skNil then
          Exit(TScriptValues.Create(Value));

        Exit(TScriptValues.Create(TScriptValue.Num(Index), Value));
      end;

      if Name = 'table.unpack' then
      begin
        var T := TScriptTable(V.Obj);
        var First := 1;
        var Last := T.Count;
        if Length(A) > 1 then
          First := Trunc(A[1].AsNumber);
        if Length(A) > 2 then
          Last := Trunc(A[2].AsNumber);
        if (Last - First > 10000) then
          raise EReadError.Create('MGW unpack limit');

        for var i := First to Last do
          Result := Result + [T.RawGet(TScriptValue.Num(i))];
        Exit;
      end;

      if Name = 'table.insert' then
      begin
        var T := TScriptTable(V.Obj);
        var Index := T.Count + 1;
        var Value := SV(A, 1);
        if Length(A) > 2 then
        begin
          Index := Trunc(A[1].AsNumber);
          Value := A[2];
        end;
        for var i := T.Count downto Index do
          T.RawSet(TScriptValue.Num(i + 1), T.RawGet(TScriptValue.Num(i)));
        T.RawSet(TScriptValue.Num(Index), Value);
        Exit;
      end;

      if Name = 'table.remove' then
      begin
        var T := TScriptTable(V.Obj);
        var Index := T.Count;
        if Length(A) > 1 then
          Index := Trunc(A[1].AsNumber);
        Result := [T.RawGet(TScriptValue.Num(Index))];
        for var i := Index to T.Count - 1 do
          T.RawSet(TScriptValue.Num(i), T.RawGet(TScriptValue.Num(i + 1)));
        T.RawSet(TScriptValue.Num(T.Count), TScriptValue.NilValue);
        Exit;
      end;

      if Name = 'table.concat' then
      begin
        var S := '';
        var T := TScriptTable(V.Obj);
        var Sep := '';
        if Length(A) > 1 then
          Sep := A[1].AsString;
        for var i := 1 to T.Count do
        begin
          if i > 1 then
            S := S + Sep;
          S := S + T.RawGet(TScriptValue.Num(i)).AsString;
        end;
        Exit(TScriptValues.Create(TScriptValue.Str(S)));
      end;

      if Name = 'math.floor' then
        Exit(TScriptValues.Create(TScriptValue.Num(Floor(V.AsNumber))));

      if Name = 'math.ceil' then
        Exit(TScriptValues.Create(TScriptValue.Num(Ceil(V.AsNumber))));

      if Name = 'math.abs' then
        Exit(TScriptValues.Create(TScriptValue.Num(Abs(V.AsNumber))));

      if (Name = 'math.min') or (Name = 'math.max') then
      begin
        var N := V.AsNumber;
        for var i := 1 to High(A) do
          if Name = 'math.min' then
            N := Min(N, A[i].AsNumber)
          else
            N := Max(N, A[i].AsNumber);
        Exit(TScriptValues.Create(TScriptValue.Num(N)));
      end;

      if Name = 'string.char' then
      begin
        var S := '';
        for var X in A do
          S := S + Char(Trunc(X.AsNumber));
        Exit(TScriptValues.Create(TScriptValue.Str(S)));
      end;

      if Name = 'string.sub' then
      begin
        var S := V.AsString;
        var First := Trunc(SV(A, 1).AsNumber);
        var Last := Length(S);
        if Length(A) > 2 then
          Last := Trunc(A[2].AsNumber);
        if First < 0 then
          First := Length(S) + First + 1;
        if Last < 0 then
          Last := Length(S) + Last + 1;
        First := Max(First, 1);
        Last := Min(Last, Length(S));
        Exit(TScriptValues.Create(TScriptValue.Str(Copy(S, First, Max(0, Last - First + 1)))));
      end;

      if Name = 'string.byte' then
      begin
        var i := 1;
        if Length(A) > 1 then
          i := Trunc(A[1].AsNumber);
        if (i >= 1) and (i <= Length(V.Text)) then
          Result := [TScriptValue.Num(Ord(V.Text[i]))];
        Exit;
      end;
      if Name = 'string.upper' then
        Exit(TScriptValues.Create(TScriptValue.Str(V.Text.ToUpper)));

      if Name = 'string.lower' then
        Exit(TScriptValues.Create(TScriptValue.Str(V.Text.ToLower)));

      if Name = 'string.format' then
      begin
        var S := '';
        var i := 1;
        var Arg := 1;
        while i <= Length(V.Text) do
        begin
          if V.Text[i] <> '%' then
          begin
            S := S + V.Text[i];
            Inc(i);
            Continue;
          end;

          Inc(i);
          if i > Length(V.Text) then
            raise EReadError.Create('MGW invalid format');

          if V.Text[i] = '%' then
          begin
            S := S + '%';
            Inc(i);
            Continue;
          end;

          var Pad := ' ';
          if V.Text[i] = '0' then
          begin
            Pad := '0';
            Inc(i);
          end;
          var Width := 0;
          while (i <= Length(V.Text)) and CharInSet(V.Text[i], ['0'..'9']) do
          begin
            Width := Width * 10 + Ord(V.Text[i]) - 48;
            Inc(i);
          end;
          if (i > Length(V.Text)) or (Width > 1024) then
            raise EReadError.Create('MGW invalid format');

          var Part: string;
          case V.Text[i] of
            's':
              Part := SV(A, Arg).AsString;
            'd', 'i', 'u':
              Part := IntToStr(Trunc(SV(A, Arg).AsNumber));
            'x', 'X':
              Part := IntToHex(Trunc(SV(A, Arg).AsNumber), 1);
          else
            raise EReadError.Create('MGW unsupported format ' + V.Text[i]);
          end;

          if V.Text[i] = 'x' then
            Part := Part.ToLower;
          S := S + StringOfChar(Pad, Max(0, Width - Length(Part))) + Part;
          Inc(Arg);
          Inc(i);
        end;
        Exit(TScriptValues.Create(TScriptValue.Str(S)));
      end;
      raise EReadError.Create('MGW missing builtin ' + Name);
    end;

  for var Name in ['math', 'string', 'table', '_G'] do
    Engine.Globals.Put(Name, TScriptValue.ObjectValue(Engine.NewTable), True);

  for var Name in ['assert', 'error', 'print', 'type', 'tostring', 'tonumber', 'require', 'setmetatable', 'getmetatable', 'rawget', 'rawset', 'select', 'next', 'pairs', 'ipairs', '$ipairs', 'table.unpack', 'table.insert', 'table.remove', 'table.concat', 'math.floor', 'math.ceil', 'math.abs', 'math.min', 'math.max', 'string.char', 'string.sub', 'string.byte', 'string.upper', 'string.lower', 'string.format'] do
    Bind(Name);
end;

end.

