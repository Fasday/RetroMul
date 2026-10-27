{ Decoder }

function DecodeVFPU4(Op: Cardinal): TPSPOpHandler;
begin
  var Sub := (Op shr 16) and 31;
  Result := OpReserved;
  case (Op shr 21) and 31 of
    0:
      case Sub of
        $00: Result := OpVMOV;
        $01: Result := OpVABS;
        $02: Result := OpVNEG;
        $03: Result := OpVIDT;
        $04: Result := OpVSAT0;
        $05: Result := OpVSAT1;
        $06: Result := OpVZERO;
        $07: Result := OpVONE;
        $10: Result := OpVRCP;
        $11: Result := OpVRSQ;
        $12: Result := OpVSIN;
        $13: Result := OpVCOS;
        $14: Result := OpVEXP2;
        $15: Result := OpVLOG2;
        $16: Result := OpVSQRT;
        $17: Result := OpVASIN;
        $18: Result := OpVNRCP;
        $1A: Result := OpVNSIN;
        $1C: Result := OpVREXP2;
      end;
    1:
      case Sub of
        $00: Result := OpVRNDS;
        $01: Result := OpVRNDI;
        $02: Result := OpVRNDF1;
        $03: Result := OpVRNDF2;
        $12: Result := OpVF2H;
        $13: Result := OpVH2F;
        $16: Result := OpVSBZ;
        $17: Result := OpVLGB;
        $18: Result := OpVUC2I;
        $19: Result := OpVC2I;
        $1A: Result := OpVUS2I;
        $1B: Result := OpVS2I;
        $1C: Result := OpVI2UC;
        $1D: Result := OpVI2C;
        $1E: Result := OpVI2US;
        $1F: Result := OpVI2S;
      end;
    2:
      case Sub of
        $00: Result := OpVSRT1;
        $01: Result := OpVSRT2;
        $02: Result := OpVBFY1;
        $03: Result := OpVBFY2;
        $04: Result := OpVOCP;
        $05: Result := OpVSOCP;
        $06: Result := OpVFAD;
        $07: Result := OpVAVG;
        $08: Result := OpVSRT3;
        $09: Result := OpVSRT4;
        $0A: Result := OpVSGN;
        $10: Result := OpVMFVC;
        $11: Result := OpVMTVC;
        $19: Result := OpVT4444;
        $1A: Result := OpVT5551;
        $1B: Result := OpVT5650;
      end;
    3: Result := OpVCST;
    $10: Result := OpVF2IN;
    $11: Result := OpVF2IZ;
    $12: Result := OpVF2IU;
    $13: Result := OpVF2ID;
    $14: Result := OpVI2F;
    $15: Result := OpVCMOV;
    $18..$1F: Result := OpVWBN;
  end;
end;

function DecodeVFPU6(Op: Cardinal): TPSPOpHandler;
begin
  case (Op shr 23) and 7 of
    0: Result := OpVMMUL;
    1, 2, 3: Result := OpVTFM;
    4: Result := OpVMSCL;
    5: Result := OpVCRSPQMUL;
    7:
      if ((Op shr 21) and 3) = 1 then
        Result := OpVROT
      else if ((Op shr 21) and 3) = 0 then
        case (Op shr 16) and 31 of
          0: Result := OpVMMOV;
          3: Result := OpVMIDT;
          6: Result := OpVMZERO;
          7: Result := OpVMONE;
        else
          Result := OpReserved;
        end
      else
        Result := OpReserved;
  else
    Result := OpReserved;
  end;
end;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;
begin
  Result := OpReserved;
  case Op shr 26 of
    $12:
      case (Op shr 21) and 31 of
        3: Result := OpMFV;
        7: Result := OpMTV;
        8: Result := OpBVC;
      end;
    $18:
      case (Op shr 23) and 7 of
        0: Result := OpVADD;
        1: Result := OpVSUB;
        2: Result := OpVSBN;
        7: Result := OpVDIV;
      end;
    $19:
      case (Op shr 23) and 7 of
        0: Result := OpVMUL;
        1: Result := OpVDOT;
        2: Result := OpVSCL;
        4: Result := OpVHDP;
        5: Result := OpVCRS;
        6: Result := OpVDET;
      end;
    $1B:
      case (Op shr 23) and 7 of
        0: Result := OpVCMP;
        2: Result := OpVMIN;
        3: Result := OpVMAX;
        5: Result := OpVSCMP;
        6: Result := OpVSGE;
        7: Result := OpVSLT;
      end;
    $32: Result := OpLVS;
    $34: Result := DecodeVFPU4(Op);
    $35: Result := OpLVLRQ;
    $36: Result := OpLVQ;
    $37:
      case (Op shr 23) and 7 of
        0, 1: Result := OpVPFXS;
        2, 3: Result := OpVPFXT;
        4, 5: Result := OpVPFXD;
        6: Result := OpVIIM;
        7: Result := OpVFIM;
      end;
    $3A: Result := OpSVS;
    $3C: Result := DecodeVFPU6(Op);
    $3D: Result := OpSVLRQ;
    $3E: Result := OpSVQ;
    $3F:
      if (Op shr 16) = $FFFF then
        Result := OpVNOP;
  end;
end;
