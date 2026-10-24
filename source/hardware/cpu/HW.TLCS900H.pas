unit HW.TLCS900H;

// TLCS-900/H instruction implementation

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TDivision = record
    quot, rem: Int64;
  end;

  TPair = packed record
    case Integer of
      0:
        (d: Cardinal);
      1:
        (sd: Integer);
      2:
        (b: packed record
  l, h, h2, h3: Byte;
end);
      3:
        (sb: packed record
  l, h, h2, h3: ShortInt;
end);
      4:
        (w: packed record
  l, h: Word;
end);
      5:
        (sw: packed record
  l, h: SmallInt;
end);
  end;

  PPair = ^TPair;

  TInstruction = record
    opfunc, operand1, operand2, cycles: Integer;
  end;

  PInstruction = ^TInstruction;

  TTLCSRead = function(Address: Cardinal): Byte of object;

  TTLCSWrite = procedure(Address: Cardinal; Value: Byte) of object;

  TTLCS900H = class
  private
    FRead: TTLCSRead;
    FWrite: TTLCSWrite;
    m_pc, m_sr, m_f2, m_dummy, m_ea1, m_ea2, m_imm1, m_imm2: TPair;
    m_xwa, m_xbc, m_xde, m_xhl, m_dmas, m_dmad, m_dmac, m_dmam: array[0..3] of TPair;
    m_xix, m_xiy, m_xiz, m_xnsp, m_xssp: TPair;
    m_intnest: Word;
    m_op: Byte;
    m_cycles, m_halted, m_regbank, m_check_irqs: Integer;
    m_prefetch_clear, m_irq_inhibit: Boolean;
    m_p1_reg8, m_p2_reg8: PByte;
    m_p1_reg16, m_p2_reg16: PWord;
    m_p1_reg32, m_p2_reg32: PCardinal;
    function RDOP: Byte;
    function RDMEM(Address: Cardinal): Byte;
    function RDMEMW(Address: Cardinal): Word;
    function RDMEML(Address: Cardinal): Cardinal;
    procedure WRMEM(Address: Cardinal; Value: Byte);
    procedure WRMEMW(Address: Cardinal; Value: Word);
    procedure WRMEML(Address, Value: Cardinal);
    procedure ExecuteOpcode(Op: Integer);
    procedure IllegalInstruction;
    function condition_true(cond: Byte): Integer;
    function get_reg8_current(reg: Byte): PByte;
    function get_reg16_current(reg: Byte): PWord;
    function get_reg32_current(reg: Byte): PCardinal;
    function get_reg(reg: Byte): PPair;
    function get_reg8(reg: Byte): PByte;
    function get_reg16(reg: Byte): PWord;
    function get_reg32(reg: Byte): PCardinal;
    procedure parity8(a: Byte);
    procedure parity16(a: Word);
    procedure parity32(a: Cardinal);
    function adc8(a: Byte; b: Byte): Byte;
    function adc16(a: Word; b: Word): Word;
    function adc32(a: Cardinal; b: Cardinal): Cardinal;
    function add8(a: Byte; b: Byte): Byte;
    function add16(a: Word; b: Word): Word;
    function add32(a: Cardinal; b: Cardinal): Cardinal;
    function sbc8(a: Byte; b: Byte): Byte;
    function sbc16(a: Word; b: Word): Word;
    function sbc32(a: Cardinal; b: Cardinal): Cardinal;
    function sub8(a: Byte; b: Byte): Byte;
    function sub16(a: Word; b: Word): Word;
    function sub32(a: Cardinal; b: Cardinal): Cardinal;
    function and8(a: Byte; b: Byte): Byte;
    function and16(a: Word; b: Word): Word;
    function and32(a: Cardinal; b: Cardinal): Cardinal;
    function or8(a: Byte; b: Byte): Byte;
    function or16(a: Word; b: Word): Word;
    function or32(a: Cardinal; b: Cardinal): Cardinal;
    function xor8(a: Byte; b: Byte): Byte;
    function xor16(a: Word; b: Word): Word;
    function xor32(a: Cardinal; b: Cardinal): Cardinal;
    procedure ldcf8(a: Byte; b: Byte);
    procedure ldcf16(a: Byte; b: Word);
    procedure andcf8(a: Byte; b: Byte);
    procedure andcf16(a: Byte; b: Word);
    procedure orcf8(a: Byte; b: Byte);
    procedure orcf16(a: Byte; b: Word);
    procedure xorcf8(a: Byte; b: Byte);
    procedure xorcf16(a: Byte; b: Word);
    function rl8(a: Byte; s: Byte): Byte;
    function rl16(a: Word; s: Byte): Word;
    function rl32(a: Cardinal; s: Byte): Cardinal;
    function rlc8(a: Byte; s: Byte): Byte;
    function rlc16(a: Word; s: Byte): Word;
    function rlc32(a: Cardinal; s: Byte): Cardinal;
    function rr8(a: Byte; s: Byte): Byte;
    function rr16(a: Word; s: Byte): Word;
    function rr32(a: Cardinal; s: Byte): Cardinal;
    function rrc8(a: Byte; s: Byte): Byte;
    function rrc16(a: Word; s: Byte): Word;
    function rrc32(a: Cardinal; s: Byte): Cardinal;
    function sla8(a: Byte; s: Byte): Byte;
    function sla16(a: Word; s: Byte): Word;
    function sla32(a: Cardinal; s: Byte): Cardinal;
    function sra8(a: Byte; s: Byte): Byte;
    function sra16(a: Word; s: Byte): Word;
    function sra32(a: Cardinal; s: Byte): Cardinal;
    function srl8(a: Byte; s: Byte): Byte;
    function srl16(a: Word; s: Byte): Word;
    function srl32(a: Cardinal; s: Byte): Cardinal;
    function div8(a: Word; b: Byte): Word;
    function div16(a: Cardinal; b: Word): Cardinal;
    function divs8(a: SmallInt; b: ShortInt): Word;
    function divs16(a: Integer; b: SmallInt): Cardinal;
    procedure op_ADCBMI;
    procedure op_ADCBMR;
    procedure op_ADCBRI;
    procedure op_ADCBRM;
    procedure op_ADCBRR;
    procedure op_ADCWMI;
    procedure op_ADCWMR;
    procedure op_ADCWRI;
    procedure op_ADCWRM;
    procedure op_ADCWRR;
    procedure op_ADCLMR;
    procedure op_ADCLRI;
    procedure op_ADCLRM;
    procedure op_ADCLRR;
    procedure op_ADDBMI;
    procedure op_ADDBMR;
    procedure op_ADDBRI;
    procedure op_ADDBRM;
    procedure op_ADDBRR;
    procedure op_ADDWMI;
    procedure op_ADDWMR;
    procedure op_ADDWRI;
    procedure op_ADDWRM;
    procedure op_ADDWRR;
    procedure op_ADDLMR;
    procedure op_ADDLRI;
    procedure op_ADDLRM;
    procedure op_ADDLRR;
    procedure op_ANDBMI;
    procedure op_ANDBMR;
    procedure op_ANDBRI;
    procedure op_ANDBRM;
    procedure op_ANDBRR;
    procedure op_ANDWMI;
    procedure op_ANDWMR;
    procedure op_ANDWRI;
    procedure op_ANDWRM;
    procedure op_ANDWRR;
    procedure op_ANDLMR;
    procedure op_ANDLRI;
    procedure op_ANDLRM;
    procedure op_ANDLRR;
    procedure op_ANDCFBIM;
    procedure op_ANDCFBIR;
    procedure op_ANDCFBRM;
    procedure op_ANDCFBRR;
    procedure op_ANDCFWIR;
    procedure op_ANDCFWRR;
    procedure op_BITBIM;
    procedure op_BITBIR;
    procedure op_BITWIR;
    procedure op_BS1BRR;
    procedure op_BS1FRR;
    procedure op_CALLI;
    procedure op_CALLM;
    procedure op_CALR;
    procedure op_CCF;
    procedure op_CHGBIM;
    procedure op_CHGBIR;
    procedure op_CHGWIR;
    procedure op_CPBMI;
    procedure op_CPBMR;
    procedure op_CPBRI;
    procedure op_CPBRM;
    procedure op_CPBRR;
    procedure op_CPWMI;
    procedure op_CPWMR;
    procedure op_CPWRI;
    procedure op_CPWRM;
    procedure op_CPWRR;
    procedure op_CPLMR;
    procedure op_CPLRI;
    procedure op_CPLRM;
    procedure op_CPLRR;
    procedure op_CPD;
    procedure op_CPDR;
    procedure op_CPDW;
    procedure op_CPDRW;
    procedure op_CPI;
    procedure op_CPIR;
    procedure op_CPIW;
    procedure op_CPIRW;
    procedure op_CPLBR;
    procedure op_CPLWR;
    procedure op_DAABR;
    procedure op_DB;
    procedure op_DECBIM;
    procedure op_DECBIR;
    procedure op_DECWIM;
    procedure op_DECWIR;
    procedure op_DECLIR;
    procedure op_DECF;
    procedure op_DIVBRI;
    procedure op_DIVBRM;
    procedure op_DIVBRR;
    procedure op_DIVWRI;
    procedure op_DIVWRM;
    procedure op_DIVWRR;
    procedure op_DIVSBRI;
    procedure op_DIVSBRM;
    procedure op_DIVSBRR;
    procedure op_DIVSWRI;
    procedure op_DIVSWRM;
    procedure op_DIVSWRR;
    procedure op_DJNZB;
    procedure op_DJNZW;
    procedure op_EI;
    procedure op_EXBMR;
    procedure op_EXBRR;
    procedure op_EXWMR;
    procedure op_EXWRR;
    procedure op_EXTSWR;
    procedure op_EXTSLR;
    procedure op_EXTZWR;
    procedure op_EXTZLR;
    procedure op_HALT;
    procedure op_INCBIM;
    procedure op_INCBIR;
    procedure op_INCWIM;
    procedure op_INCWIR;
    procedure op_INCLIR;
    procedure op_INCF;
    procedure op_JPI;
    procedure op_JPM;
    procedure op_JR;
    procedure op_JRL;
    procedure op_LDBMI;
    procedure op_LDBMM;
    procedure op_LDBMR;
    procedure op_LDBRI;
    procedure op_LDBRM;
    procedure op_LDBRR;
    procedure op_LDWMI;
    procedure op_LDWMM;
    procedure op_LDWMR;
    procedure op_LDWRI;
    procedure op_LDWRM;
    procedure op_LDWRR;
    procedure op_LDLRI;
    procedure op_LDLRM;
    procedure op_LDLRR;
    procedure op_LDLMR;
    procedure op_LDAW;
    procedure op_LDAL;
    procedure op_LDCBRR;
    procedure op_LDCWRR;
    procedure op_LDCLRR;
    procedure op_LDCFBIM;
    procedure op_LDCFBIR;
    procedure op_LDCFBRM;
    procedure op_LDCFBRR;
    procedure op_LDCFWIR;
    procedure op_LDCFWRR;
    procedure op_LDD;
    procedure op_LDDR;
    procedure op_LDDRW;
    procedure op_LDDW;
    procedure op_LDF;
    procedure op_LDI;
    procedure op_LDIR;
    procedure op_LDIRW;
    procedure op_LDIW;
    procedure op_LDX;
    procedure op_LINK;
    procedure op_MAX;
    procedure op_MDEC1;
    procedure op_MDEC2;
    procedure op_MDEC4;
    procedure op_MINC1;
    procedure op_MINC2;
    procedure op_MINC4;
    procedure op_MIRRW;
    procedure op_MULBRI;
    procedure op_MULBRM;
    procedure op_MULBRR;
    procedure op_MULWRI;
    procedure op_MULWRM;
    procedure op_MULWRR;
    procedure op_MULAR;
    procedure op_MULSBRI;
    procedure op_MULSBRM;
    procedure op_MULSBRR;
    procedure op_MULSWRI;
    procedure op_MULSWRM;
    procedure op_MULSWRR;
    procedure op_NEGBR;
    procedure op_NEGWR;
    procedure op_NOP;
    procedure op_NORMAL;
    procedure op_ORBMI;
    procedure op_ORBMR;
    procedure op_ORBRI;
    procedure op_ORBRM;
    procedure op_ORBRR;
    procedure op_ORWMI;
    procedure op_ORWMR;
    procedure op_ORWRI;
    procedure op_ORWRM;
    procedure op_ORWRR;
    procedure op_ORLMR;
    procedure op_ORLRI;
    procedure op_ORLRM;
    procedure op_ORLRR;
    procedure op_ORCFBIM;
    procedure op_ORCFBIR;
    procedure op_ORCFBRM;
    procedure op_ORCFBRR;
    procedure op_ORCFWIR;
    procedure op_ORCFWRR;
    procedure op_PAAWR;
    procedure op_PAALR;
    procedure op_POPBM;
    procedure op_POPBR;
    procedure op_POPWM;
    procedure op_POPWR;
    procedure op_POPWSR;
    procedure op_POPLR;
    procedure op_PUSHBI;
    procedure op_PUSHBM;
    procedure op_PUSHBR;
    procedure op_PUSHWI;
    procedure op_PUSHWM;
    procedure op_PUSHWR;
    procedure op_PUSHLR;
    procedure op_RCF;
    procedure op_RESBIM;
    procedure op_RESBIR;
    procedure op_RESWIR;
    procedure op_RET;
    procedure op_RETCC;
    procedure op_RETD;
    procedure op_RETI;
    procedure op_RLBM;
    procedure op_RLWM;
    procedure op_RLBIR;
    procedure op_RLBRR;
    procedure op_RLWIR;
    procedure op_RLWRR;
    procedure op_RLLIR;
    procedure op_RLLRR;
    procedure op_RLCBM;
    procedure op_RLCWM;
    procedure op_RLCBIR;
    procedure op_RLCBRR;
    procedure op_RLCWIR;
    procedure op_RLCWRR;
    procedure op_RLCLIR;
    procedure op_RLCLRR;
    procedure op_RLDRM;
    procedure op_RRBM;
    procedure op_RRWM;
    procedure op_RRBIR;
    procedure op_RRBRR;
    procedure op_RRWIR;
    procedure op_RRWRR;
    procedure op_RRLIR;
    procedure op_RRLRR;
    procedure op_RRCBM;
    procedure op_RRCWM;
    procedure op_RRCBIR;
    procedure op_RRCBRR;
    procedure op_RRCWIR;
    procedure op_RRCWRR;
    procedure op_RRCLIR;
    procedure op_RRCLRR;
    procedure op_RRDRM;
    procedure op_SBCBMI;
    procedure op_SBCBMR;
    procedure op_SBCBRI;
    procedure op_SBCBRM;
    procedure op_SBCBRR;
    procedure op_SBCWMI;
    procedure op_SBCWMR;
    procedure op_SBCWRI;
    procedure op_SBCWRM;
    procedure op_SBCWRR;
    procedure op_SBCLMR;
    procedure op_SBCLRI;
    procedure op_SBCLRM;
    procedure op_SBCLRR;
    procedure op_SCCBR;
    procedure op_SCCWR;
    procedure op_SCF;
    procedure op_SETBIM;
    procedure op_SETBIR;
    procedure op_SETWIR;
    procedure op_SLABM;
    procedure op_SLAWM;
    procedure op_SLABIR;
    procedure op_SLABRR;
    procedure op_SLAWIR;
    procedure op_SLAWRR;
    procedure op_SLALIR;
    procedure op_SLALRR;
    procedure op_SLLBM;
    procedure op_SLLWM;
    procedure op_SLLBIR;
    procedure op_SLLBRR;
    procedure op_SLLWIR;
    procedure op_SLLWRR;
    procedure op_SLLLIR;
    procedure op_SLLLRR;
    procedure op_SRABM;
    procedure op_SRAWM;
    procedure op_SRABIR;
    procedure op_SRABRR;
    procedure op_SRAWIR;
    procedure op_SRAWRR;
    procedure op_SRALIR;
    procedure op_SRALRR;
    procedure op_SRLBM;
    procedure op_SRLWM;
    procedure op_SRLBIR;
    procedure op_SRLBRR;
    procedure op_SRLWIR;
    procedure op_SRLWRR;
    procedure op_SRLLIR;
    procedure op_SRLLRR;
    procedure op_STCFBIM;
    procedure op_STCFBIR;
    procedure op_STCFBRM;
    procedure op_STCFBRR;
    procedure op_STCFWIR;
    procedure op_STCFWRR;
    procedure op_SUBBMI;
    procedure op_SUBBMR;
    procedure op_SUBBRI;
    procedure op_SUBBRM;
    procedure op_SUBBRR;
    procedure op_SUBWMI;
    procedure op_SUBWMR;
    procedure op_SUBWRI;
    procedure op_SUBWRM;
    procedure op_SUBWRR;
    procedure op_SUBLMR;
    procedure op_SUBLRI;
    procedure op_SUBLRM;
    procedure op_SUBLRR;
    procedure op_SWI;
    procedure op_SWI900;
    procedure op_TSETBIM;
    procedure op_TSETBIR;
    procedure op_TSETWIR;
    procedure op_UNLK;
    procedure op_XORBMI;
    procedure op_XORBMR;
    procedure op_XORBRI;
    procedure op_XORBRM;
    procedure op_XORBRR;
    procedure op_XORWMI;
    procedure op_XORWMR;
    procedure op_XORWRI;
    procedure op_XORWRM;
    procedure op_XORWRR;
    procedure op_XORLMR;
    procedure op_XORLRI;
    procedure op_XORLRM;
    procedure op_XORLRR;
    procedure op_XORCFBIM;
    procedure op_XORCFBIR;
    procedure op_XORCFBRM;
    procedure op_XORCFBRR;
    procedure op_XORCFWIR;
    procedure op_XORCFWRR;
    procedure op_ZCF;
    procedure prepare_operands(inst: PInstruction);
    procedure op_80;
    procedure op_88;
    procedure op_90;
    procedure op_98;
    procedure op_A0;
    procedure op_A8;
    procedure op_B0;
    procedure op_B8;
    procedure op_C0;
    procedure oC8;
    procedure op_D0;
    procedure oD8;
    procedure op_E0;
    procedure op_E8;
    procedure op_F0;
  public
    constructor Create(ReadByte: TTLCSRead; WriteByte: TTLCSWrite);
    procedure Reset;
    function Step: Integer;
    function Interrupt(Vector: Byte; Level: Integer): Boolean;
    procedure NonMaskableInterrupt;
    function MicroDMA(Channel: Integer; out Finished: Boolean): Integer;
    procedure SerializeState(State: TStateArchive);
    property PC: Cardinal read m_pc.d write m_pc.d;
    property SR: Word read m_sr.w.l write m_sr.w.l;
    property SP: Cardinal read m_xssp.d write m_xssp.d;
    function RegisterValue(Index: Integer): Cardinal;
    procedure SetRegisterValue(Index: Integer; Value: Cardinal);
  end;

implementation

const
  FLAG_CF = $01;
  FLAG_NF = $02;
  FLAG_VF = $04;
  FLAG_HF = $10;
  FLAG_ZF = $40;
  FLAG_SF = $80;
  p_A = 1;
  p_C8 = 2;
  p_C16 = 3;
  p_C32 = 4;
  p_MC16 = 5;
  p_CC = 6;
  p_CR8 = 7;
  p_CR16 = 8;
  p_CR32 = 9;
  p_D8 = 10;
  p_D16 = 11;
  p_F = 12;
  p_I3 = 13;
  p_I8 = 14;
  p_I16 = 15;
  p_I24 = 16;
  p_I32 = 17;
  p_M = 18;
  p_M8 = 19;
  p_M16 = 20;
  p_R = 21;
  p_SR = 22;
  m_mnemonic_80: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 218; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 248; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 265; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 158; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 159; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 153; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 154; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 78; operand1: 0; operand2: 0; cycles: 6),
    (opfunc: 79; operand1: 0; operand2: 0; cycles: 7),
    (opfunc: 74; operand1: 0; operand2: 0; cycles: 6),
    (opfunc: 75; operand1: 0; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 14; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 0; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 324; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 266; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 28; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 344; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 189; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 60; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 240; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 257; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 232; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 249; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 286; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 302; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 294; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 310; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4)
  );
  m_mnemonic_88: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 218; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 248; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 265; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 14; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 0; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 324; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 266; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 28; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 344; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 189; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 60; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 240; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 257; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 232; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 249; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 286; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 302; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 294; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 310; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4)
  );
  m_mnemonic_90: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 221; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 161; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 160; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 156; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 155; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 80; operand1: 0; operand2: 0; cycles: 6),
    (opfunc: 81; operand1: 0; operand2: 0; cycles: 7),
    (opfunc: 76; operand1: 0; operand2: 0; cycles: 6),
    (opfunc: 77; operand1: 0; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 19; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 5; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 329; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 271; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 33; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 349; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 194; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 65; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 241; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 258; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 233; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 250; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 287; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 303; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 295; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 311; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4)
  );
  m_mnemonic_98: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 221; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 19; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 5; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 329; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 271; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 33; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 349; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 194; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 65; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 241; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 258; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 233; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 250; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 287; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 303; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 295; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 311; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4)
  );
  m_mnemonic_a0: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6)
  );
  m_mnemonic_b0: array[0..255] of TInstruction = (
    (opfunc: 126; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 132; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 211; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 213; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 44; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 205; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 360; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 149; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 320; operand1: p_A; operand2: p_M; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4),
    (opfunc: 229; operand1: p_CC; operand2: 0; cycles: 4)
  );
  m_mnemonic_b8: array[0..255] of TInstruction = (
    (opfunc: 126; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 132; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 211; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 213; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 44; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 205; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 360; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 149; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 320; operand1: p_A; operand2: p_M; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1)
  );
  m_mnemonic_c0: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 218; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 248; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 265; operand1: p_A; operand2: p_M; cycles: 14),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 130; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 107; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 14; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 0; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 324; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 266; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 28; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 344; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 189; operand1: p_M; operand2: p_I8; cycles: 7),
    (opfunc: 60; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 173; operand1: p_MC16; operand2: p_M; cycles: 13),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 180; operand1: p_MC16; operand2: p_M; cycles: 11),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 93; operand1: p_MC16; operand2: p_M; cycles: 16),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 19),
    (opfunc: 99; operand1: p_MC16; operand2: p_M; cycles: 24),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 116; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 86; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 240; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 257; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 232; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 249; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 286; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 302; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 294; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 310; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 17; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 15; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 3; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 1; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 327; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 325; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 269; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 267; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 31; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 29; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 347; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 345; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 192; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 190; operand1: p_M; operand2: p_C8; cycles: 6),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 63; operand1: p_C8; operand2: p_M; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 61; operand1: p_M; operand2: p_C8; cycles: 4)
  );
  m_mnemonic_c8: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 129; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 219; operand1: p_R; operand2: 0; cycles: 4),
    (opfunc: 212; operand1: p_R; operand2: 0; cycles: 5),
    (opfunc: 82; operand1: p_R; operand2: 0; cycles: 2),
    (opfunc: 185; operand1: p_R; operand2: 0; cycles: 2),
    (opfunc: 172; operand1: p_R; operand2: p_I8; cycles: 12),
    (opfunc: 179; operand1: p_R; operand2: p_I8; cycles: 10),
    (opfunc: 92; operand1: p_R; operand2: p_I8; cycles: 15),
    (opfunc: 98; operand1: p_R; operand2: p_I8; cycles: 18),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 84; operand1: p_R; operand2: 0; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 104; operand1: p_R; operand2: p_D8; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 43; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 204; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 359; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 148; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 319; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 45; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 206; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 361; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 150; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 321; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 144; operand1: p_CR8; operand2: p_R; cycles: 3),
    (opfunc: 144; operand1: p_R; operand2: p_CR8; cycles: 3),
    (opfunc: 226; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 284; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 58; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 49; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 341; operand1: p_I8; operand2: p_R; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 174; operand1: p_MC16; operand2: p_R; cycles: 11),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 181; operand1: p_MC16; operand2: p_R; cycles: 9),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 94; operand1: p_MC16; operand2: p_R; cycles: 15),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 24),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 18),
    (opfunc: 100; operand1: p_MC16; operand2: p_R; cycles: 24),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 117; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 87; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 280; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 18; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 4; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 131; operand1: p_R; operand2: p_C8; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 328; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 129; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 270; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 108; operand1: p_C8; operand2: p_R; cycles: 3),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 32; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 16; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 2; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 326; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 268; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 30; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 346; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 191; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 62; operand1: p_R; operand2: p_I8; cycles: 3),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 348; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 62; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 193; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 242; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 259; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 234; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 251; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 288; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 304; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 296; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 312; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 64; operand1: p_C8; operand2: p_R; cycles: 2),
    (opfunc: 243; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 260; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 235; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 252; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 289; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 305; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 297; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 313; operand1: p_A; operand2: p_R; cycles: 3)
  );
  m_mnemonic_d0: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 221; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M16; operand2: p_M; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 136; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 109; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 19; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 5; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 329; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 271; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 33; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 349; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 194; operand1: p_M; operand2: p_I16; cycles: 8),
    (opfunc: 65; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 176; operand1: p_C32; operand2: p_M; cycles: 16),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 183; operand1: p_C32; operand2: p_M; cycles: 14),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 96; operand1: p_C32; operand2: p_M; cycles: 24),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 102; operand1: p_C32; operand2: p_M; cycles: 27),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 118; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 88; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 241; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 258; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 233; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 250; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 287; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 303; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 295; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 311; operand1: p_M; operand2: 0; cycles: 6),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 22; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 20; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 8; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 6; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 332; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 330; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 274; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 272; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 36; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 34; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 352; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 350; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 197; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 195; operand1: p_M; operand2: p_C16; cycles: 6),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 68; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 66; operand1: p_M; operand2: p_C16; cycles: 4)
  );
  m_mnemonic_d8: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 135; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 222; operand1: p_R; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_R; operand2: 0; cycles: 5),
    (opfunc: 83; operand1: p_R; operand2: 0; cycles: 2),
    (opfunc: 186; operand1: p_R; operand2: 0; cycles: 2),
    (opfunc: 175; operand1: p_R; operand2: p_I16; cycles: 15),
    (opfunc: 182; operand1: p_R; operand2: p_I16; cycles: 13),
    (opfunc: 95; operand1: p_R; operand2: p_I16; cycles: 23),
    (opfunc: 101; operand1: p_R; operand2: p_I16; cycles: 26),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 52; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 51; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 113; operand1: p_R; operand2: 0; cycles: 3),
    (opfunc: 111; operand1: p_R; operand2: 0; cycles: 3),
    (opfunc: 209; operand1: p_R; operand2: 0; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 171; operand1: p_R; operand2: 0; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 178; operand1: p_R; operand2: 0; cycles: 19),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 105; operand1: p_R; operand2: p_D8; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 46; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 207; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 362; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 151; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 322; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 47; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 208; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 363; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 152; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 323; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 145; operand1: p_CR16; operand2: p_R; cycles: 3),
    (opfunc: 145; operand1: p_R; operand2: p_CR16; cycles: 3),
    (opfunc: 227; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 285; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 59; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 50; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 342; operand1: p_I8; operand2: p_R; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 168; operand1: p_I16; operand2: p_R; cycles: 5),
    (opfunc: 169; operand1: p_I16; operand2: p_R; cycles: 5),
    (opfunc: 170; operand1: p_I16; operand2: p_R; cycles: 5),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 165; operand1: p_I16; operand2: p_R; cycles: 4),
    (opfunc: 166; operand1: p_I16; operand2: p_R; cycles: 4),
    (opfunc: 167; operand1: p_I16; operand2: p_R; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 177; operand1: p_C32; operand2: p_R; cycles: 14),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 184; operand1: p_C32; operand2: p_R; cycles: 12),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 97; operand1: p_C32; operand2: p_R; cycles: 23),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 103; operand1: p_C32; operand2: p_R; cycles: 26),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 119; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 89; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 281; operand1: p_CC; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 23; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 9; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 137; operand1: p_R; operand2: p_C16; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 333; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 135; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 275; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 110; operand1: p_C16; operand2: p_R; cycles: 3),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 37; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 21; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 7; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 331; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 273; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 35; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 351; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 196; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 67; operand1: p_R; operand2: p_I16; cycles: 4),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 353; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 67; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 198; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 244; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 261; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 236; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 253; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 290; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 306; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 298; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 314; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 69; operand1: p_C16; operand2: p_R; cycles: 2),
    (opfunc: 245; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 262; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 237; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 254; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 291; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 307; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 299; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 315; operand1: p_A; operand2: p_R; cycles: 3)
  );
  m_mnemonic_e0: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 139; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 26; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 24; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 12; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 10; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 336; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 334; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 278; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 276; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 40; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 38; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 356; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 354; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 201; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 199; operand1: p_M; operand2: p_C32; cycles: 10),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 72; operand1: p_C32; operand2: p_M; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 70; operand1: p_M; operand2: p_C32; cycles: 6)
  );
  m_mnemonic_e8: array[0..255] of TInstruction = (
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 138; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 223; operand1: p_R; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_R; operand2: 0; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 163; operand1: p_R; operand2: p_I16; cycles: 8),
    (opfunc: 343; operand1: p_R; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 114; operand1: p_R; operand2: 0; cycles: 3),
    (opfunc: 112; operand1: p_R; operand2: 0; cycles: 3),
    (opfunc: 210; operand1: p_R; operand2: 0; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 146; operand1: p_CR32; operand2: p_R; cycles: 3),
    (opfunc: 146; operand1: p_R; operand2: p_CR32; cycles: 3),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 120; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 90; operand1: p_I3; operand2: p_R; cycles: 2),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 27; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 13; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 140; operand1: p_R; operand2: p_C32; cycles: 2),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 337; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 138; operand1: p_R; operand2: p_I3; cycles: 4),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 279; operand1: p_C32; operand2: p_R; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 41; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 25; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 11; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 335; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 277; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 39; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 355; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 200; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 71; operand1: p_R; operand2: p_I32; cycles: 6),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 357; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 71; operand1: p_R; operand2: p_I3; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 202; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 246; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 263; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 238; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 255; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 292; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 308; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 300; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 316; operand1: p_I8; operand2: p_R; cycles: 3),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 73; operand1: p_C32; operand2: p_R; cycles: 2),
    (opfunc: 247; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 264; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 239; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 256; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 293; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 309; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 301; operand1: p_A; operand2: p_R; cycles: 3),
    (opfunc: 317; operand1: p_A; operand2: p_R; cycles: 3)
  );
  m_mnemonic_f0: array[0..255] of TInstruction = (
    (opfunc: 126; operand1: p_M; operand2: p_I8; cycles: 5),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 132; operand1: p_M; operand2: p_I16; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 211; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 213; operand1: p_M; operand2: 0; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 127; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 133; operand1: p_M; operand2: p_M16; cycles: 8),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 142; operand1: p_C16; operand2: p_M; cycles: 4),
    (opfunc: 44; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 205; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 360; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 149; operand1: p_A; operand2: p_M; cycles: 6),
    (opfunc: 320; operand1: p_A; operand2: p_M; cycles: 7),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 143; operand1: p_C32; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 128; operand1: p_M; operand2: p_C8; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 134; operand1: p_M; operand2: p_C16; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 141; operand1: p_M; operand2: p_C32; cycles: 6),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 42; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 203; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 358; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 147; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 318; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 340; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 225; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 283; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 57; operand1: p_I3; operand2: p_M; cycles: 7),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 48; operand1: p_I3; operand2: p_M; cycles: 6),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 123; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 54; operand1: p_CC; operand2: p_M; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1)
  );
  m_mnemonic: array[0..255] of TInstruction = (
    (opfunc: 187; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 222; operand1: p_SR; operand2: 0; cycles: 3),
    (opfunc: 215; operand1: p_SR; operand2: 0; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 115; operand1: 0; operand2: 0; cycles: 6),
    (opfunc: 106; operand1: p_I8; operand2: 0; cycles: 3),
    (opfunc: 231; operand1: 0; operand2: 0; cycles: 12),
    (opfunc: 126; operand1: p_M8; operand2: p_I8; cycles: 5),
    (opfunc: 217; operand1: p_I8; operand2: 0; cycles: 4),
    (opfunc: 132; operand1: p_M8; operand2: p_I16; cycles: 6),
    (opfunc: 220; operand1: p_I16; operand2: 0; cycles: 5),
    (opfunc: 121; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 91; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 228; operand1: 0; operand2: 0; cycles: 9),
    (opfunc: 230; operand1: p_I16; operand2: 0; cycles: 11),
    (opfunc: 224; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 282; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 56; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 364; operand1: 0; operand2: 0; cycles: 2),
    (opfunc: 219; operand1: p_A; operand2: 0; cycles: 3),
    (opfunc: 212; operand1: p_A; operand2: 0; cycles: 4),
    (opfunc: 108; operand1: p_F; operand2: p_F; cycles: 2),
    (opfunc: 157; operand1: p_I8; operand2: 0; cycles: 2),
    (opfunc: 219; operand1: p_F; operand2: 0; cycles: 3),
    (opfunc: 212; operand1: p_F; operand2: 0; cycles: 4),
    (opfunc: 122; operand1: p_I16; operand2: 0; cycles: 5),
    (opfunc: 122; operand1: p_I24; operand2: 0; cycles: 6),
    (opfunc: 53; operand1: p_I16; operand2: 0; cycles: 9),
    (opfunc: 53; operand1: p_I24; operand2: 0; cycles: 10),
    (opfunc: 55; operand1: p_D16; operand2: 0; cycles: 10),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 129; operand1: p_C8; operand2: p_I8; cycles: 2),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 222; operand1: p_C16; operand2: 0; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 135; operand1: p_C16; operand2: p_I16; cycles: 3),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 223; operand1: p_C32; operand2: 0; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 138; operand1: p_C32; operand2: p_I32; cycles: 5),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 214; operand1: p_C16; operand2: 0; cycles: 4),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 1),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 216; operand1: p_C32; operand2: 0; cycles: 6),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 124; operand1: p_CC; operand2: p_D8; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 125; operand1: p_CC; operand2: p_D16; cycles: 2),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 365; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 366; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 367; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 368; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 369; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 370; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 371; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 372; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 373; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 374; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 375; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 376; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 377; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 378; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 379; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 85; operand1: 0; operand2: 0; cycles: 0),
    (opfunc: 162; operand1: 0; operand2: 0; cycles: 8),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19),
    (opfunc: 338; operand1: p_I3; operand2: 0; cycles: 19)
  );

function Choose(Condition: Boolean; A, B: Cardinal): Cardinal; overload; inline;
begin
  if Condition then
    Result := A
  else
    Result := B;
end;

function Choose(Condition: Boolean; A, B: PWord): PWord; overload; inline;
begin
  if Condition then
    Result := A
  else
    Result := B;
end;

// Address arithmetic wraps at 32 bits after sign-extending the displacement.
function AddDisplacement(Address: Cardinal; Displacement: Integer): Cardinal; inline;
begin
  Result := Cardinal(((Int64(Address) + Displacement) and $FFFFFFFF));
end;

function ldiv(A, B: Int64): TDivision;
begin
  Result.quot := (A div B);
  Result.rem := (A mod B);
end;

function Sar(Value: Int64; Shift: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := (not ((not Value) shr Shift))
  else
    Result := (Value shr Shift);
end;

constructor TTLCS900H.Create(ReadByte: TTLCSRead; WriteByte: TTLCSWrite);
begin
  inherited Create;
  FRead := ReadByte;
  FWrite := WriteByte;
end;

function TTLCS900H.RDMEM(Address: Cardinal): Byte;
begin
  Result := FRead((Address and $FFFFFF));
end;

function TTLCS900H.RDMEMW(Address: Cardinal): Word;
begin
  Result := Word(((RDMEM(Address) or (Word(RDMEM(Cardinal((Int64(Address) + 1)))) shl 8)) and $FFFF));
end;

function TTLCS900H.RDMEML(Address: Cardinal): Cardinal;
begin
  Result := Cardinal(((RDMEMW(Address) or (Cardinal(RDMEMW(Cardinal((Int64(Address) + 2)))) shl 16)) and $FFFFFFFF));
end;

procedure TTLCS900H.WRMEM(Address: Cardinal; Value: Byte);
begin
  FWrite(Address and $FFFFFF, Value);
end;

procedure TTLCS900H.WRMEMW(Address: Cardinal; Value: Word);
begin
  WRMEM(Address, Byte(Value));
  WRMEM(Cardinal((Int64(Address) + 1)), Byte((Value shr 8)));
end;

procedure TTLCS900H.WRMEML(Address, Value: Cardinal);
begin
  WRMEMW(Address, Word(Value));
  WRMEMW(Cardinal((Int64(Address) + 2)), Word((Value shr 16)));
end;

function TTLCS900H.RDOP: Byte;
begin
  Result := RDMEM(m_pc.d);
  m_pc.d := Cardinal((((Int64(m_pc.d) + 1) and $FFFFFF) and $FFFFFFFF));
end;

procedure TTLCS900H.Reset;
begin
  m_dummy.d := 0;
  m_ea1.d := 0;
  m_ea2.d := 0;
  m_imm1.d := 0;
  m_imm2.d := 0;
  m_p1_reg8 := nil;
  m_p2_reg8 := nil;
  m_p1_reg16 := nil;
  m_p2_reg16 := nil;
  m_p1_reg32 := nil;
  m_p2_reg32 := nil;
  FillChar(m_xwa, SizeOf(m_xwa), 0);
  FillChar(m_xbc, SizeOf(m_xbc), 0);
  FillChar(m_xde, SizeOf(m_xde), 0);
  FillChar(m_xhl, SizeOf(m_xhl), 0);
  FillChar(m_dmas, SizeOf(m_dmas), 0);
  FillChar(m_dmad, SizeOf(m_dmad), 0);
  FillChar(m_dmac, SizeOf(m_dmac), 0);
  FillChar(m_dmam, SizeOf(m_dmam), 0);
  m_xix.d := 0;
  m_xiy.d := 0;
  m_xiz.d := 0;
  m_xnsp.d := 0;
  m_xssp.d := $100;
  m_sr.d := $F800;
  m_f2.d := 0;
  m_regbank := 0;
  m_halted := 0;
  m_intnest := 0;
  m_irq_inhibit := False;
  m_check_irqs := 0;
  m_pc.d := Cardinal(((RDMEML(Cardinal($FFFF00)) and $FFFFFF) and $FFFFFFFF));
end;

procedure TTLCS900H.IllegalInstruction;
begin
  raise EInvalidOpException.CreateFmt('TLCS-900/H illegal opcode at %.6x', [(Int64(m_pc.d) - 1) and $FFFFFF]);
end;

function TTLCS900H.Step: Integer;
var
  Inst: PInstruction;
begin
  m_cycles := 0;
  m_irq_inhibit := False;
  if m_halted <> 0 then
    Exit(8);
  m_op := RDOP;
  Inst := (@m_mnemonic[m_op]);
  prepare_operands(Inst);
  ExecuteOpcode(Inst^.opfunc);
  Result := Integer((Int64(m_cycles) + (Inst)^.cycles));
end;

function TTLCS900H.Interrupt(Vector: Byte; Level: Integer): Boolean;
begin
  Result := not m_irq_inhibit and (Level > 0) and (Level < 7) and
    (Level >= ((m_sr.w.l shr 12) and 7));
  if not Result then
    Exit;
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, m_sr.w.l);
  m_sr.w.l := Word((((m_sr.w.l and $8FFF) or ((Int64(Level) + 1) shl 12)) and $FFFF));
  m_intnest := Word(((Int64(m_intnest) + 1) and $FFFF));
  m_halted := 0;
  m_pc.d := Cardinal(((RDMEML(Cardinal((Int64($FFFF00) + Cardinal(Vector)))) and $FFFFFF) and $FFFFFFFF));
end;

function TTLCS900H.RegisterValue(Index: Integer): Cardinal;
begin
  Result := (get_reg32_current(Byte((Index and 7))))^;
end;

procedure TTLCS900H.SetRegisterValue(Index: Integer; Value: Cardinal);
begin
  get_reg32_current(Index and 7)^ := Value;
end;

procedure TTLCS900H.NonMaskableInterrupt;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, m_sr.w.l);
  m_intnest := Word(((Int64(m_intnest) + 1) and $FFFF));
  m_halted := 0;
  m_pc.d := Cardinal(((RDMEML(Cardinal($FFFF20)) and $FFFFFF) and $FFFFFFFF));
end;

function TTLCS900H.MicroDMA(Channel: Integer; out Finished: Boolean): Integer;
var
  Mode, Width, Kind: Integer;
  Value: Cardinal;
begin
  Result := 0;
  Finished := False;
  if (Channel < 0) or (Channel > 3) then
    Exit;
  Mode := (m_dmam[Channel].B.l and $1F);
  if (Mode and 3 = 3) or (Mode > $14) then
    Exit;
  Width := (1 shl (Mode and 3));
  Kind := (Mode and $1C);
  if Kind <> $14 then
  begin
    case Width of
      1:
        Value := RDMEM(m_dmas[Channel].d);
      2:
        Value := RDMEMW(m_dmas[Channel].d);
    else
      Value := RDMEML(m_dmas[Channel].d);
    end;
    case Width of
      1:
        WRMEM(m_dmad[Channel].d, Byte(Value));
      2:
        WRMEMW(m_dmad[Channel].d, Word(Value));
    else
      WRMEML(m_dmad[Channel].d, Value);
    end;
  end;
  case Kind of
    $00:
      m_dmad[Channel].d := Cardinal(((Int64(m_dmad[Channel].d) + Width) and $FFFFFFFF));
    $04:
      m_dmad[Channel].d := Cardinal(((Int64(m_dmad[Channel].d) - Width) and $FFFFFFFF));
    $08, $14:
      m_dmas[Channel].d := Cardinal(((Int64(m_dmas[Channel].d) + Width) and $FFFFFFFF));
    $0C:
      m_dmas[Channel].d := Cardinal(((Int64(m_dmas[Channel].d) - Width) and $FFFFFFFF));
  end;
  m_dmac[Channel].w.l := Word(((Int64(m_dmac[Channel].w.l) - 1) and $FFFF));
  Finished := (m_dmac[Channel].w.l = 0);
  if Kind = $14 then
    Result := 5
  else if Width = 4 then
    Result := 12
  else
    Result := 8;
end;

procedure TTLCS900H.SerializeState(State: TStateArchive);
begin
  State.Field(m_pc, SizeOf(m_pc));
  State.Field(m_sr, SizeOf(m_sr));
  State.Field(m_f2, SizeOf(m_f2));
  State.Field(m_xwa, SizeOf(m_xwa));
  State.Field(m_xbc, SizeOf(m_xbc));
  State.Field(m_xde, SizeOf(m_xde));
  State.Field(m_xhl, SizeOf(m_xhl));
  State.Field(m_xix, SizeOf(m_xix));
  State.Field(m_xiy, SizeOf(m_xiy));
  State.Field(m_xiz, SizeOf(m_xiz));
  State.Field(m_xssp, SizeOf(m_xssp));
  State.Field(m_xnsp, SizeOf(m_xnsp));
  State.Field(m_dmas, SizeOf(m_dmas));
  State.Field(m_dmad, SizeOf(m_dmad));
  State.Field(m_dmac, SizeOf(m_dmac));
  State.Field(m_dmam, SizeOf(m_dmam));
  State.Field(m_intnest, SizeOf(m_intnest));
  State.Field(m_halted, SizeOf(m_halted));
  State.Field(m_irq_inhibit, SizeOf(m_irq_inhibit));
  m_regbank := (m_sr.b.h and 3);
end;

procedure TTLCS900H.ExecuteOpcode(Op: Integer);
begin
  case Op of
    0:
      op_ADCBMI;
    1:
      op_ADCBMR;
    2:
      op_ADCBRI;
    3:
      op_ADCBRM;
    4:
      op_ADCBRR;
    5:
      op_ADCWMI;
    6:
      op_ADCWMR;
    7:
      op_ADCWRI;
    8:
      op_ADCWRM;
    9:
      op_ADCWRR;
    10:
      op_ADCLMR;
    11:
      op_ADCLRI;
    12:
      op_ADCLRM;
    13:
      op_ADCLRR;
    14:
      op_ADDBMI;
    15:
      op_ADDBMR;
    16:
      op_ADDBRI;
    17:
      op_ADDBRM;
    18:
      op_ADDBRR;
    19:
      op_ADDWMI;
    20:
      op_ADDWMR;
    21:
      op_ADDWRI;
    22:
      op_ADDWRM;
    23:
      op_ADDWRR;
    24:
      op_ADDLMR;
    25:
      op_ADDLRI;
    26:
      op_ADDLRM;
    27:
      op_ADDLRR;
    28:
      op_ANDBMI;
    29:
      op_ANDBMR;
    30:
      op_ANDBRI;
    31:
      op_ANDBRM;
    32:
      op_ANDBRR;
    33:
      op_ANDWMI;
    34:
      op_ANDWMR;
    35:
      op_ANDWRI;
    36:
      op_ANDWRM;
    37:
      op_ANDWRR;
    38:
      op_ANDLMR;
    39:
      op_ANDLRI;
    40:
      op_ANDLRM;
    41:
      op_ANDLRR;
    42:
      op_ANDCFBIM;
    43:
      op_ANDCFBIR;
    44:
      op_ANDCFBRM;
    45:
      op_ANDCFBRR;
    46:
      op_ANDCFWIR;
    47:
      op_ANDCFWRR;
    48:
      op_BITBIM;
    49:
      op_BITBIR;
    50:
      op_BITWIR;
    51:
      op_BS1BRR;
    52:
      op_BS1FRR;
    53:
      op_CALLI;
    54:
      op_CALLM;
    55:
      op_CALR;
    56:
      op_CCF;
    57:
      op_CHGBIM;
    58:
      op_CHGBIR;
    59:
      op_CHGWIR;
    60:
      op_CPBMI;
    61:
      op_CPBMR;
    62:
      op_CPBRI;
    63:
      op_CPBRM;
    64:
      op_CPBRR;
    65:
      op_CPWMI;
    66:
      op_CPWMR;
    67:
      op_CPWRI;
    68:
      op_CPWRM;
    69:
      op_CPWRR;
    70:
      op_CPLMR;
    71:
      op_CPLRI;
    72:
      op_CPLRM;
    73:
      op_CPLRR;
    74:
      op_CPD;
    75:
      op_CPDR;
    76:
      op_CPDW;
    77:
      op_CPDRW;
    78:
      op_CPI;
    79:
      op_CPIR;
    80:
      op_CPIW;
    81:
      op_CPIRW;
    82:
      op_CPLBR;
    83:
      op_CPLWR;
    84:
      op_DAABR;
    85:
      op_DB;
    86:
      op_DECBIM;
    87:
      op_DECBIR;
    88:
      op_DECWIM;
    89:
      op_DECWIR;
    90:
      op_DECLIR;
    91:
      op_DECF;
    92:
      op_DIVBRI;
    93:
      op_DIVBRM;
    94:
      op_DIVBRR;
    95:
      op_DIVWRI;
    96:
      op_DIVWRM;
    97:
      op_DIVWRR;
    98:
      op_DIVSBRI;
    99:
      op_DIVSBRM;
    100:
      op_DIVSBRR;
    101:
      op_DIVSWRI;
    102:
      op_DIVSWRM;
    103:
      op_DIVSWRR;
    104:
      op_DJNZB;
    105:
      op_DJNZW;
    106:
      op_EI;
    107:
      op_EXBMR;
    108:
      op_EXBRR;
    109:
      op_EXWMR;
    110:
      op_EXWRR;
    111:
      op_EXTSWR;
    112:
      op_EXTSLR;
    113:
      op_EXTZWR;
    114:
      op_EXTZLR;
    115:
      op_HALT;
    116:
      op_INCBIM;
    117:
      op_INCBIR;
    118:
      op_INCWIM;
    119:
      op_INCWIR;
    120:
      op_INCLIR;
    121:
      op_INCF;
    122:
      op_JPI;
    123:
      op_JPM;
    124:
      op_JR;
    125:
      op_JRL;
    126:
      op_LDBMI;
    127:
      op_LDBMM;
    128:
      op_LDBMR;
    129:
      op_LDBRI;
    130:
      op_LDBRM;
    131:
      op_LDBRR;
    132:
      op_LDWMI;
    133:
      op_LDWMM;
    134:
      op_LDWMR;
    135:
      op_LDWRI;
    136:
      op_LDWRM;
    137:
      op_LDWRR;
    138:
      op_LDLRI;
    139:
      op_LDLRM;
    140:
      op_LDLRR;
    141:
      op_LDLMR;
    142:
      op_LDAW;
    143:
      op_LDAL;
    144:
      op_LDCBRR;
    145:
      op_LDCWRR;
    146:
      op_LDCLRR;
    147:
      op_LDCFBIM;
    148:
      op_LDCFBIR;
    149:
      op_LDCFBRM;
    150:
      op_LDCFBRR;
    151:
      op_LDCFWIR;
    152:
      op_LDCFWRR;
    153:
      op_LDD;
    154:
      op_LDDR;
    155:
      op_LDDRW;
    156:
      op_LDDW;
    157:
      op_LDF;
    158:
      op_LDI;
    159:
      op_LDIR;
    160:
      op_LDIRW;
    161:
      op_LDIW;
    162:
      op_LDX;
    163:
      op_LINK;
    164:
      op_MAX;
    165:
      op_MDEC1;
    166:
      op_MDEC2;
    167:
      op_MDEC4;
    168:
      op_MINC1;
    169:
      op_MINC2;
    170:
      op_MINC4;
    171:
      op_MIRRW;
    172:
      op_MULBRI;
    173:
      op_MULBRM;
    174:
      op_MULBRR;
    175:
      op_MULWRI;
    176:
      op_MULWRM;
    177:
      op_MULWRR;
    178:
      op_MULAR;
    179:
      op_MULSBRI;
    180:
      op_MULSBRM;
    181:
      op_MULSBRR;
    182:
      op_MULSWRI;
    183:
      op_MULSWRM;
    184:
      op_MULSWRR;
    185:
      op_NEGBR;
    186:
      op_NEGWR;
    187:
      op_NOP;
    188:
      op_NORMAL;
    189:
      op_ORBMI;
    190:
      op_ORBMR;
    191:
      op_ORBRI;
    192:
      op_ORBRM;
    193:
      op_ORBRR;
    194:
      op_ORWMI;
    195:
      op_ORWMR;
    196:
      op_ORWRI;
    197:
      op_ORWRM;
    198:
      op_ORWRR;
    199:
      op_ORLMR;
    200:
      op_ORLRI;
    201:
      op_ORLRM;
    202:
      op_ORLRR;
    203:
      op_ORCFBIM;
    204:
      op_ORCFBIR;
    205:
      op_ORCFBRM;
    206:
      op_ORCFBRR;
    207:
      op_ORCFWIR;
    208:
      op_ORCFWRR;
    209:
      op_PAAWR;
    210:
      op_PAALR;
    211:
      op_POPBM;
    212:
      op_POPBR;
    213:
      op_POPWM;
    214:
      op_POPWR;
    215:
      op_POPWSR;
    216:
      op_POPLR;
    217:
      op_PUSHBI;
    218:
      op_PUSHBM;
    219:
      op_PUSHBR;
    220:
      op_PUSHWI;
    221:
      op_PUSHWM;
    222:
      op_PUSHWR;
    223:
      op_PUSHLR;
    224:
      op_RCF;
    225:
      op_RESBIM;
    226:
      op_RESBIR;
    227:
      op_RESWIR;
    228:
      op_RET;
    229:
      op_RETCC;
    230:
      op_RETD;
    231:
      op_RETI;
    232:
      op_RLBM;
    233:
      op_RLWM;
    234:
      op_RLBIR;
    235:
      op_RLBRR;
    236:
      op_RLWIR;
    237:
      op_RLWRR;
    238:
      op_RLLIR;
    239:
      op_RLLRR;
    240:
      op_RLCBM;
    241:
      op_RLCWM;
    242:
      op_RLCBIR;
    243:
      op_RLCBRR;
    244:
      op_RLCWIR;
    245:
      op_RLCWRR;
    246:
      op_RLCLIR;
    247:
      op_RLCLRR;
    248:
      op_RLDRM;
    249:
      op_RRBM;
    250:
      op_RRWM;
    251:
      op_RRBIR;
    252:
      op_RRBRR;
    253:
      op_RRWIR;
    254:
      op_RRWRR;
    255:
      op_RRLIR;
    256:
      op_RRLRR;
    257:
      op_RRCBM;
    258:
      op_RRCWM;
    259:
      op_RRCBIR;
    260:
      op_RRCBRR;
    261:
      op_RRCWIR;
    262:
      op_RRCWRR;
    263:
      op_RRCLIR;
    264:
      op_RRCLRR;
    265:
      op_RRDRM;
    266:
      op_SBCBMI;
    267:
      op_SBCBMR;
    268:
      op_SBCBRI;
    269:
      op_SBCBRM;
    270:
      op_SBCBRR;
    271:
      op_SBCWMI;
    272:
      op_SBCWMR;
    273:
      op_SBCWRI;
    274:
      op_SBCWRM;
    275:
      op_SBCWRR;
    276:
      op_SBCLMR;
    277:
      op_SBCLRI;
    278:
      op_SBCLRM;
    279:
      op_SBCLRR;
    280:
      op_SCCBR;
    281:
      op_SCCWR;
    282:
      op_SCF;
    283:
      op_SETBIM;
    284:
      op_SETBIR;
    285:
      op_SETWIR;
    286:
      op_SLABM;
    287:
      op_SLAWM;
    288:
      op_SLABIR;
    289:
      op_SLABRR;
    290:
      op_SLAWIR;
    291:
      op_SLAWRR;
    292:
      op_SLALIR;
    293:
      op_SLALRR;
    294:
      op_SLLBM;
    295:
      op_SLLWM;
    296:
      op_SLLBIR;
    297:
      op_SLLBRR;
    298:
      op_SLLWIR;
    299:
      op_SLLWRR;
    300:
      op_SLLLIR;
    301:
      op_SLLLRR;
    302:
      op_SRABM;
    303:
      op_SRAWM;
    304:
      op_SRABIR;
    305:
      op_SRABRR;
    306:
      op_SRAWIR;
    307:
      op_SRAWRR;
    308:
      op_SRALIR;
    309:
      op_SRALRR;
    310:
      op_SRLBM;
    311:
      op_SRLWM;
    312:
      op_SRLBIR;
    313:
      op_SRLBRR;
    314:
      op_SRLWIR;
    315:
      op_SRLWRR;
    316:
      op_SRLLIR;
    317:
      op_SRLLRR;
    318:
      op_STCFBIM;
    319:
      op_STCFBIR;
    320:
      op_STCFBRM;
    321:
      op_STCFBRR;
    322:
      op_STCFWIR;
    323:
      op_STCFWRR;
    324:
      op_SUBBMI;
    325:
      op_SUBBMR;
    326:
      op_SUBBRI;
    327:
      op_SUBBRM;
    328:
      op_SUBBRR;
    329:
      op_SUBWMI;
    330:
      op_SUBWMR;
    331:
      op_SUBWRI;
    332:
      op_SUBWRM;
    333:
      op_SUBWRR;
    334:
      op_SUBLMR;
    335:
      op_SUBLRI;
    336:
      op_SUBLRM;
    337:
      op_SUBLRR;
    338:
      op_SWI;
    339:
      op_SWI900;
    340:
      op_TSETBIM;
    341:
      op_TSETBIR;
    342:
      op_TSETWIR;
    343:
      op_UNLK;
    344:
      op_XORBMI;
    345:
      op_XORBMR;
    346:
      op_XORBRI;
    347:
      op_XORBRM;
    348:
      op_XORBRR;
    349:
      op_XORWMI;
    350:
      op_XORWMR;
    351:
      op_XORWRI;
    352:
      op_XORWRM;
    353:
      op_XORWRR;
    354:
      op_XORLMR;
    355:
      op_XORLRI;
    356:
      op_XORLRM;
    357:
      op_XORLRR;
    358:
      op_XORCFBIM;
    359:
      op_XORCFBIR;
    360:
      op_XORCFBRM;
    361:
      op_XORCFBRR;
    362:
      op_XORCFWIR;
    363:
      op_XORCFWRR;
    364:
      op_ZCF;
    365:
      op_80;
    366:
      op_88;
    367:
      op_90;
    368:
      op_98;
    369:
      op_A0;
    370:
      op_A8;
    371:
      op_B0;
    372:
      op_B8;
    373:
      op_C0;
    374:
      oC8;
    375:
      op_D0;
    376:
      oD8;
    377:
      op_E0;
    378:
      op_E8;
    379:
      op_F0;
  else
    IllegalInstruction;
  end;
end;

function TTLCS900H.condition_true(cond: Byte): Integer;
begin
  case (cond and $0f) of
    $00:
      begin
        Exit(0);
      end;
    $01:
      begin
        Exit(Ord((((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_SF) or ((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_VF))));
      end;
    $02:
      begin
        Exit(Ord(((((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_SF) or ((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_VF)) or ((m_sr.b.l and FLAG_ZF) <> 0))));
      end;
    $03:
      begin
        Exit((m_sr.b.l and (FLAG_ZF or FLAG_CF)));
      end;
    $04:
      begin
        Exit((m_sr.b.l and FLAG_VF));
      end;
    $05:
      begin
        Exit((m_sr.b.l and FLAG_SF));
      end;
    $06:
      begin
        Exit((m_sr.b.l and FLAG_ZF));
      end;
    $07:
      begin
        Exit((m_sr.b.l and FLAG_CF));
      end;
    $08:
      begin
        Exit(1);
      end;
    $09:
      begin
        Exit(Ord((not (((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_SF) or ((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_VF)))));
      end;
    $0A:
      begin
        Exit(Ord((not ((((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_SF) or ((m_sr.b.l and (FLAG_SF or FLAG_VF)) = FLAG_VF)) or ((m_sr.b.l and FLAG_ZF) <> 0)))));
      end;
    $0B:
      begin
        Exit(Ord((not ((m_sr.b.l and (FLAG_ZF or FLAG_CF)) <> 0))));
      end;
    $0C:
      begin
        Exit(Ord((not ((m_sr.b.l and FLAG_VF) <> 0))));
      end;
    $0D:
      begin
        Exit(Ord((not ((m_sr.b.l and FLAG_SF) <> 0))));
      end;
    $0E:
      begin
        Exit(Ord((not ((m_sr.b.l and FLAG_ZF) <> 0))));
      end;
    $0F:
      begin
        Exit(Ord((not ((m_sr.b.l and FLAG_CF) <> 0))));
      end;
  end;
  Exit(0);
end;

function TTLCS900H.get_reg8_current(reg: Byte): PByte;
begin
  case (reg and 7) of
    0:
      begin
        Exit((@m_xwa[m_regbank].B.h));
      end;
    1:
      begin
        Exit((@m_xwa[m_regbank].B.l));
      end;
    2:
      begin
        Exit((@m_xbc[m_regbank].B.h));
      end;
    3:
      begin
        Exit((@m_xbc[m_regbank].B.l));
      end;
    4:
      begin
        Exit((@m_xde[m_regbank].B.h));
      end;
    5:
      begin
        Exit((@m_xde[m_regbank].B.l));
      end;
    6:
      begin
        Exit((@m_xhl[m_regbank].B.h));
      end;
    7:
      begin
        Exit((@m_xhl[m_regbank].B.l));
      end;
  end;
  Exit((@m_dummy.b.l));
end;

function TTLCS900H.get_reg16_current(reg: Byte): PWord;
begin
  case (reg and 7) of
    0:
      begin
        Exit((@m_xwa[m_regbank].w.l));
      end;
    1:
      begin
        Exit((@m_xbc[m_regbank].w.l));
      end;
    2:
      begin
        Exit((@m_xde[m_regbank].w.l));
      end;
    3:
      begin
        Exit((@m_xhl[m_regbank].w.l));
      end;
    4:
      begin
        Exit((@m_xix.w.l));
      end;
    5:
      begin
        Exit((@m_xiy.w.l));
      end;
    6:
      begin
        Exit((@m_xiz.w.l));
      end;
    7:
      begin
        Exit((@m_xssp.w.l));
      end;
  end;
  Exit((@m_dummy.w.l));
end;

function TTLCS900H.get_reg32_current(reg: Byte): PCardinal;
begin
  case (reg and 7) of
    0:
      begin
        Exit((@m_xwa[m_regbank].d));
      end;
    1:
      begin
        Exit((@m_xbc[m_regbank].d));
      end;
    2:
      begin
        Exit((@m_xde[m_regbank].d));
      end;
    3:
      begin
        Exit((@m_xhl[m_regbank].d));
      end;
    4:
      begin
        Exit((@m_xix.d));
      end;
    5:
      begin
        Exit((@m_xiy.d));
      end;
    6:
      begin
        Exit((@m_xiz.d));
      end;
    7:
      begin
        Exit((@m_xssp.d));
      end;
  end;
  Exit((@m_dummy.d));
end;

function TTLCS900H.get_reg(reg: Byte): PPair;
var
  regbank: Byte;
begin
  case (reg and $f0) of
    $00, $10, $20, $30, $d0, $e0:
      begin
        regbank := Byte((((reg and $f0) shr 4) and $FF));
        if (regbank = $0d) then
          regbank := Byte((((Int64(m_regbank) - 1) and $03) and $FF));
        if (regbank = $0e) then
          regbank := m_regbank;
        case (reg and $0c) of
          $00:
            begin
              Exit((@m_xwa[regbank]));
            end;
          $04:
            begin
              Exit((@m_xbc[regbank]));
            end;
          $08:
            begin
              Exit((@m_xde[regbank]));
            end;
          $0c:
            begin
              Exit((@m_xhl[regbank]));
            end;
        end;
      end;
    $f0:
      begin
        case (reg and $0c) of
          $00:
            begin
              Exit((@m_xix));
            end;
          $04:
            begin
              Exit((@m_xiy));
            end;
          $08:
            begin
              Exit((@m_xiz));
            end;
          $0c:
            begin
              Exit((@m_xssp));
            end;
        end;
      end;
  end;
  Exit((@m_dummy));
end;

function TTLCS900H.get_reg8(reg: Byte): PByte;
var
  r: PPair;
begin
  r := get_reg(reg);
  case (reg and $03) of
    $00:
      begin
        Exit((@(r)^.B.l));
      end;
    $01:
      begin
        Exit((@(r)^.B.h));
      end;
    $02:
      begin
        Exit((@(r)^.B.h2));
      end;
    $03:
      begin
        Exit((@(r)^.B.h3));
      end;
  end;
  Exit((@(r)^.B.l));
end;

function TTLCS900H.get_reg16(reg: Byte): PWord;
var
  r: PPair;
begin
  r := get_reg(reg);
  Exit(Choose(((reg and $02) <> 0), (@(r)^.w.h), (@(r)^.w.l)));
end;

function TTLCS900H.get_reg32(reg: Byte): PCardinal;
var
  r: PPair;
begin
  r := get_reg(reg);
  Exit((@(r)^.d));
end;

procedure TTLCS900H.parity8(a: Byte);
var
  i: Integer;
  j: Integer;
begin
  j := 0;
  i := 0;
  while (i < 8) do
  begin
    begin
      if ((a and 1) <> 0) then
        Inc(j);
      a := Byte(((a shr 1) and $FF));
    end;
    Inc(i);
  end;
  m_sr.b.l := Byte(((m_sr.b.l or Choose(((j and 1) <> 0), 0, FLAG_VF)) and $FF));
end;

procedure TTLCS900H.parity16(a: Word);
var
  i: Integer;
  j: Integer;
begin
  j := 0;
  i := 0;
  while (i < 16) do
  begin
    begin
      if ((a and 1) <> 0) then
        Inc(j);
      a := Word(((a shr 1) and $FFFF));
    end;
    Inc(i);
  end;
  m_sr.b.l := Byte(((m_sr.b.l or Choose(((j and 1) <> 0), 0, FLAG_VF)) and $FF));
end;

procedure TTLCS900H.parity32(a: Cardinal);
var
  i: Integer;
  j: Integer;
begin
  j := 0;
  i := 0;
  while (i < 32) do
  begin
    begin
      if ((a and 1) <> 0) then
        Inc(j);
      a := Cardinal(((a shr 1) and $FFFFFFFF));
    end;
    Inc(i);
  end;
  m_sr.b.l := Byte(((m_sr.b.l or Choose(((j and 1) <> 0), 0, FLAG_VF)) and $FF));
end;

function TTLCS900H.adc8(a: Byte; b: Byte): Byte;
var
  cy: Byte;
  vresult: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Byte((((Int64(a) + b) + cy) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (vresult xor b)) and $80) <> 0), FLAG_VF, 0)) or Choose(((vresult < a) or ((vresult = a) and (cy <> 0))), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.adc16(a: Word; b: Word): Word;
var
  cy: Byte;
  vresult: Word;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Word((((Int64(a) + b) + cy) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (vresult xor b)) and $8000) <> 0), FLAG_VF, 0)) or Choose(((vresult < a) or ((vresult = a) and (cy <> 0))), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.adc32(a: Cardinal; b: Cardinal): Cardinal;
var
  cy: Byte;
  vresult: Cardinal;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Cardinal((((Int64(a) + b) + cy) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or Choose(((((vresult xor a) and (vresult xor b)) and $80000000) <> 0), FLAG_VF, 0)) or Choose(((vresult < a) or ((vresult = a) and (cy <> 0))), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.add8(a: Byte; b: Byte): Byte;
var
  vresult: Byte;
begin
  vresult := Byte(((Int64(a) + b) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (vresult xor b)) and $80) <> 0), FLAG_VF, 0)) or Choose((vresult < a), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.add16(a: Word; b: Word): Word;
var
  vresult: Word;
begin
  vresult := Word(((Int64(a) + b) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (vresult xor b)) and $8000) <> 0), FLAG_VF, 0)) or Choose((vresult < a), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.add32(a: Cardinal; b: Cardinal): Cardinal;
var
  vresult: Cardinal;
begin
  vresult := Cardinal(((Int64(a) + b) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or Choose(((((vresult xor a) and (vresult xor b)) and $80000000) <> 0), FLAG_VF, 0)) or Choose((vresult < a), FLAG_CF, 0))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sbc8(a: Byte; b: Byte): Byte;
var
  cy: Byte;
  vresult: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Byte((((Int64(a) - b) - cy) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (a xor b)) and $80) <> 0), FLAG_VF, 0)) or Choose(((vresult > a) or ((cy <> 0) and (b = $FF))), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sbc16(a: Word; b: Word): Word;
var
  cy: Byte;
  vresult: Word;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Word((((Int64(a) - b) - cy) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (a xor b)) and $8000) <> 0), FLAG_VF, 0)) or Choose(((vresult > a) or ((cy <> 0) and (b = $FFFF))), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sbc32(a: Cardinal; b: Cardinal): Cardinal;
var
  cy: Byte;
  vresult: Cardinal;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  vresult := Cardinal((((Int64(a) - b) - cy) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or Choose(((((vresult xor a) and (a xor b)) and $80000000) <> 0), FLAG_VF, 0)) or Choose(((vresult > a) or ((cy <> 0) and (b = $FFFFFFFF))), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sub8(a: Byte; b: Byte): Byte;
var
  vresult: Byte;
begin
  vresult := Byte(((Int64(a) - b) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (a xor b)) and $80) <> 0), FLAG_VF, 0)) or Choose((vresult > a), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sub16(a: Word; b: Word): Word;
var
  vresult: Word;
begin
  vresult := Word(((Int64(a) - b) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or (((a xor b) xor vresult) and FLAG_HF)) or Choose(((((vresult xor a) and (a xor b)) and $8000) <> 0), FLAG_VF, 0)) or Choose((vresult > a), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.sub32(a: Cardinal; b: Cardinal): Cardinal;
var
  vresult: Cardinal;
begin
  vresult := Cardinal(((Int64(a) - b) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or Choose(((((vresult xor a) and (a xor b)) and $80000000) <> 0), FLAG_VF, 0)) or Choose((vresult > a), FLAG_CF, 0)) or FLAG_NF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.and8(a: Byte; b: Byte): Byte;
var
  vresult: Byte;
begin
  vresult := Byte(((a and b) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or FLAG_HF)) and $FF));
  parity8(vresult);
  Exit(vresult);
end;

function TTLCS900H.and16(a: Word; b: Word): Word;
var
  vresult: Word;
begin
  vresult := Word(((a and b) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or FLAG_HF)) and $FF));
  parity16(vresult);
  Exit(vresult);
end;

function TTLCS900H.and32(a: Cardinal; b: Cardinal): Cardinal;
var
  vresult: Cardinal;
begin
  vresult := Cardinal(((a and b) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF)) or FLAG_HF)) and $FF));
  Exit(vresult);
end;

function TTLCS900H.or8(a: Byte; b: Byte): Byte;
var
  vresult: Byte;
begin
  vresult := Byte(((a or b) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  parity8(vresult);
  Exit(vresult);
end;

function TTLCS900H.or16(a: Word; b: Word): Word;
var
  vresult: Word;
begin
  vresult := Word(((a or b) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  parity16(vresult);
  Exit(vresult);
end;

function TTLCS900H.or32(a: Cardinal; b: Cardinal): Cardinal;
var
  vresult: Cardinal;
begin
  vresult := Cardinal(((a or b) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  Exit(vresult);
end;

function TTLCS900H.xor8(a: Byte; b: Byte): Byte;
var
  vresult: Byte;
begin
  vresult := Byte(((a xor b) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((vresult and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  parity8(vresult);
  Exit(vresult);
end;

function TTLCS900H.xor16(a: Word; b: Word): Word;
var
  vresult: Word;
begin
  vresult := Word(((a xor b) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  parity16(vresult);
  Exit(vresult);
end;

function TTLCS900H.xor32(a: Cardinal; b: Cardinal): Cardinal;
var
  vresult: Cardinal;
begin
  vresult := Cardinal(((a xor b) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult shr 24) and FLAG_SF) or Choose((vresult <> 0), 0, FLAG_ZF))) and $FF));
  Exit(vresult);
end;

procedure TTLCS900H.ldcf8(a: Byte; b: Byte);
begin
  if ((b and (1 shl (a and $07))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
end;

procedure TTLCS900H.ldcf16(a: Byte; b: Word);
begin
  if ((b and (1 shl (a and $0f))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
end;

procedure TTLCS900H.andcf8(a: Byte; b: Byte);
begin
  if (((b and (1 shl (a and $07))) <> 0) and ((m_sr.b.l and FLAG_CF) <> 0)) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
end;

procedure TTLCS900H.andcf16(a: Byte; b: Word);
begin
  if (((b and (1 shl (a and $0f))) <> 0) and ((m_sr.b.l and FLAG_CF) <> 0)) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
end;

procedure TTLCS900H.orcf8(a: Byte; b: Byte);
begin
  if ((b and (1 shl (a and $07))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
end;

procedure TTLCS900H.orcf16(a: Byte; b: Word);
begin
  if ((b and (1 shl (a and $0f))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
end;

procedure TTLCS900H.xorcf8(a: Byte; b: Byte);
begin
  if ((b and (1 shl (a and $07))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l xor FLAG_CF) and $FF));
end;

procedure TTLCS900H.xorcf16(a: Byte; b: Word);
begin
  if ((b and (1 shl (a and $0f))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l xor FLAG_CF) and $FF));
end;

function TTLCS900H.rl8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((a and $80) <> 0) then
      begin
        a := Byte((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FF));
        m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
      end
      else
      begin
        a := Byte((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FF));
        m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.rl16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((a and $8000) <> 0) then
      begin
        a := Word((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FFFF));
        m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
      end
      else
      begin
        a := Word((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FFFF));
        m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.rl32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((a and $80000000) <> 0) then
      begin
        a := Cardinal((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FFFFFFFF));
        m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
      end
      else
      begin
        a := Cardinal((((a shl 1) or (m_sr.b.l and FLAG_CF)) and $FFFFFFFF));
        m_sr.b.l := Byte(((m_sr.b.l and Byte((not FLAG_CF))) and $FF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.rlc8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Byte((((a shl 1) or Choose(((a and $80) <> 0), 1, 0)) and $FF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF)) or (a and FLAG_CF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.rlc16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Word((((a shl 1) or Choose(((a and $8000) <> 0), 1, 0)) and $FFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF)) or (a and FLAG_CF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.rlc32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Cardinal((((a shl 1) or Choose(((a and $80000000) <> 0), 1, 0)) and $FFFFFFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF)) or (a and FLAG_CF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.rr8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((m_sr.b.l and FLAG_CF) <> 0) then
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Byte((((a shr 1) or $80) and $FF));
      end
      else
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Byte(((a shr 1) and $FF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.rr16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((m_sr.b.l and FLAG_CF) <> 0) then
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Word((((a shr 1) or $8000) and $FFFF));
      end
      else
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Word(((a shr 1) and $FFFF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.rr32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      if ((m_sr.b.l and FLAG_CF) <> 0) then
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Cardinal((((a shr 1) or $80000000) and $FFFFFFFF));
      end
      else
      begin
        m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
        a := Cardinal(((a shr 1) and $FFFFFFFF));
      end;
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.rrc8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Byte((((a shr 1) or Choose(((a and $01) <> 0), $80, 0)) and $FF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose(((a and FLAG_SF) <> 0), (FLAG_CF or FLAG_SF), 0) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.rrc16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Word((((a shr 1) or Choose(((a and $0001) <> 0), $8000, 0)) and $FFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose((((a shr 8) and FLAG_SF) <> 0), (FLAG_CF or FLAG_SF), 0) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.rrc32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      a := Cardinal((((a shr 1) or Choose(((a and $00000001) <> 0), $80000000, 0)) and $FFFFFFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose((((a shr 24) and FLAG_SF) <> 0), (FLAG_CF or FLAG_SF), 0) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.sla8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or Choose(((a and $80) <> 0), FLAG_CF, 0)) and $FF));
      a := Byte(((a shl 1) and $FF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.sla16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or Choose(((a and $8000) <> 0), FLAG_CF, 0)) and $FF));
      a := Word(((a shl 1) and $FFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.sla32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or Choose(((a and $80000000) <> 0), FLAG_CF, 0)) and $FF));
      a := Cardinal(((a shl 1) and $FFFFFFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.sra8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Byte((((a and $80) or (a shr 1)) and $FF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.sra16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Word((((a and $8000) or (a shr 1)) and $FFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.sra32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Cardinal((((a and $80000000) or (a shr 1)) and $FFFFFFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.srl8(a: Byte; s: Byte): Byte;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Byte(((a shr 1) and $FF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((a and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity8(a);
  Exit(a);
end;

function TTLCS900H.srl16(a: Word; s: Byte): Word;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Word(((a shr 1) and $FFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 8) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity16(a);
  Exit(a);
end;

function TTLCS900H.srl32(a: Cardinal; s: Byte): Cardinal;
var
  count: Byte;
  n: Byte;
begin
  count := Choose(((s and $0f) <> 0), (s and $0f), 16);
  n := count;
  while (n > 0) do
  begin
    begin
      m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or (a and FLAG_CF)) and $FF));
      a := Cardinal(((a shr 1) and $FFFFFFFF));
    end;
    n := Byte(((Int64(n) - 1) and $FF));
  end;
  m_cycles := Integer((Int64(m_cycles) + (count div 4)));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((a shr 24) and FLAG_SF) or Choose((a <> 0), 0, FLAG_ZF))) and $FF));
  parity32(a);
  Exit(a);
end;

function TTLCS900H.div8(a: Word; b: Byte): Word;
var
  vresult: TDivision;
  diff: Word;
  range: Word;
begin
  if (not (b <> 0)) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    Exit(Word((((a shl 8) or ((a shr 8) xor $ff)) and $FFFF)));
  end;
  if (a >= ($0200 * b)) then
  begin
    diff := Word(((Int64(a) - (Int64($0200) * b)) and $FFFF));
    range := Word(((Int64($100) - b) and $FFFF));
    vresult := ldiv(diff, range);
    vresult.quot := ($1ff - vresult.quot);
    vresult.rem := (vresult.rem + b);
  end
  else
  begin
    vresult := ldiv(a, b);
  end;
  if (vresult.quot > $ff) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
  Exit(Word((((vresult.quot and $ff) or ((vresult.rem and $ff) shl 8)) and $FFFF)));
end;

function TTLCS900H.div16(a: Cardinal; b: Word): Cardinal;
var
  vresult: TDivision;
begin
  if (not (b <> 0)) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    Exit(Cardinal((((a shl 16) or ((a shr 16) xor $ffff)) and $FFFFFFFF)));
  end;
  vresult := ldiv(a, b);
  if (vresult.quot > $ffff) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
  Exit(Cardinal((((vresult.quot and $ffff) or ((vresult.rem and $ffff) shl 16)) and $FFFFFFFF)));
end;

function TTLCS900H.divs8(a: SmallInt; b: ShortInt): Word;
var
  vresult: TDivision;
begin
  if (not (b <> 0)) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    Exit(Word((((a shl 8) or (Sar(a, 8) xor $ff)) and $FFFF)));
  end;
  vresult := ldiv(a, b);
  if (vresult.quot > $ff) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
  Exit(Word((((vresult.quot and $ff) or ((vresult.rem and $ff) shl 8)) and $FFFF)));
end;

function TTLCS900H.divs16(a: Integer; b: SmallInt): Cardinal;
var
  vresult: TDivision;
begin
  if (not (b <> 0)) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    Exit(Cardinal((((a shl 16) or (Sar(a, 16) xor $ffff)) and $FFFFFFFF)));
  end;
  vresult := ldiv(a, b);
  if (vresult.quot > $ffff) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
  Exit(Cardinal((((vresult.quot and $ffff) or ((vresult.rem and $ffff) shl 16)) and $FFFFFFFF)));
end;

procedure TTLCS900H.op_ADCBMI;
begin
  WRMEM(m_ea1.d, adc8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_ADCBMR;
begin
  WRMEM(m_ea1.d, adc8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_ADCBRI;
begin
  (m_p1_reg8)^ := adc8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_ADCBRM;
begin
  (m_p1_reg8)^ := adc8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ADCBRR;
begin
  (m_p1_reg8)^ := adc8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ADCWMI;
begin
  WRMEMW(m_ea1.d, adc16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_ADCWMR;
begin
  WRMEMW(m_ea1.d, adc16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_ADCWRI;
begin
  (m_p1_reg16)^ := adc16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_ADCWRM;
begin
  (m_p1_reg16)^ := adc16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_ADCWRR;
begin
  (m_p1_reg16)^ := adc16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ADCLMR;
begin
  WRMEML(m_ea1.d, adc32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_ADCLRI;
begin
  (m_p1_reg32)^ := adc32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_ADCLRM;
begin
  (m_p1_reg32)^ := adc32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_ADCLRR;
begin
  (m_p1_reg32)^ := adc32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_ADDBMI;
begin
  WRMEM(m_ea1.d, add8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_ADDBMR;
begin
  WRMEM(m_ea1.d, add8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_ADDBRI;
begin
  (m_p1_reg8)^ := add8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_ADDBRM;
begin
  (m_p1_reg8)^ := add8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ADDBRR;
begin
  (m_p1_reg8)^ := add8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ADDWMI;
begin
  WRMEMW(m_ea1.d, add16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_ADDWMR;
begin
  WRMEMW(m_ea1.d, add16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_ADDWRI;
begin
  (m_p1_reg16)^ := add16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_ADDWRM;
begin
  (m_p1_reg16)^ := add16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_ADDWRR;
begin
  (m_p1_reg16)^ := add16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ADDLMR;
begin
  WRMEML(m_ea1.d, add32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_ADDLRI;
begin
  (m_p1_reg32)^ := add32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_ADDLRM;
begin
  (m_p1_reg32)^ := add32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_ADDLRR;
begin
  (m_p1_reg32)^ := add32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_ANDBMI;
begin
  WRMEM(m_ea1.d, and8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_ANDBMR;
begin
  WRMEM(m_ea1.d, and8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_ANDBRI;
begin
  (m_p1_reg8)^ := and8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_ANDBRM;
begin
  (m_p1_reg8)^ := and8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ANDBRR;
begin
  (m_p1_reg8)^ := and8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ANDWMI;
begin
  WRMEMW(m_ea1.d, and16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_ANDWMR;
begin
  WRMEMW(m_ea1.d, and16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_ANDWRI;
begin
  (m_p1_reg16)^ := and16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_ANDWRM;
begin
  (m_p1_reg16)^ := and16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_ANDWRR;
begin
  (m_p1_reg16)^ := and16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ANDLMR;
begin
  WRMEML(m_ea1.d, and32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_ANDLRI;
begin
  (m_p1_reg32)^ := and32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_ANDLRM;
begin
  (m_p1_reg32)^ := and32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_ANDLRR;
begin
  (m_p1_reg32)^ := and32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_ANDCFBIM;
begin
  andcf8(m_imm1.b.l, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ANDCFBIR;
begin
  andcf8(m_imm1.b.l, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ANDCFBRM;
begin
  andcf8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ANDCFBRR;
begin
  andcf8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ANDCFWIR;
begin
  andcf16(m_imm1.b.l, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ANDCFWRR;
begin
  andcf16((m_p1_reg8)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_BITBIM;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  if ((RDMEM(m_ea2.d) and (1 shl (m_imm1.b.l and $07))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_HF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l or (FLAG_HF or FLAG_ZF)) and $FF));
end;

procedure TTLCS900H.op_BITBIR;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  if (((m_p2_reg8)^ and (1 shl (m_imm1.b.l and $0f))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_HF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l or (FLAG_HF or FLAG_ZF)) and $FF));
end;

procedure TTLCS900H.op_BITWIR;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  if (((m_p2_reg16)^ and (1 shl (m_imm1.b.l and $0f))) <> 0) then
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_HF) and $FF))
  else
    m_sr.b.l := Byte(((m_sr.b.l or (FLAG_HF or FLAG_ZF)) and $FF));
end;

procedure TTLCS900H.op_BS1BRR;
var
  r: Word;
begin
  r := (m_p2_reg16)^;
  if (r <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
    (m_p1_reg8)^ := 15;
    while (r < $8000) do
    begin
      r := Word(((r shl 1) and $FFFF));
      (m_p1_reg8)^ := Byte(((Int64((m_p1_reg8)^) - 1) and $FF));
    end;
  end
  else
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
end;

procedure TTLCS900H.op_BS1FRR;
var
  r: Word;
begin
  r := (m_p2_reg16)^;
  if (r <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_VF)) and $FF));
    (m_p1_reg8)^ := 0;
    while (not ((r and $0001) <> 0)) do
    begin
      r := Word(((r shr 1) and $FFFF));
      (m_p1_reg8)^ := Byte(((Int64((m_p1_reg8)^) + 1) and $FF));
    end;
  end
  else
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
end;

procedure TTLCS900H.op_CALLI;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_pc.d := m_imm1.d;
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_CALLM;
begin
  if (condition_true(m_op) <> 0) then
  begin
    m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
    WRMEML(m_xssp.d, m_pc.d);
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 8));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_CALR;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_pc.d := m_ea1.d;
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_CCF;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not FLAG_NF)) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l xor FLAG_CF) and $FF));
end;

procedure TTLCS900H.op_CHGBIM;
begin
  WRMEM(m_ea2.d, Byte((RDMEM(m_ea2.d) xor (1 shl (m_imm1.b.l and $07)))));
end;

procedure TTLCS900H.op_CHGBIR;
begin
  (m_p2_reg8)^ := Byte((((m_p2_reg8)^ xor (1 shl (m_imm1.b.l and $07))) and $FF));
end;

procedure TTLCS900H.op_CHGWIR;
begin
  (m_p2_reg16)^ := Word((((m_p2_reg16)^ xor (1 shl (m_imm1.b.l and $0f))) and $FFFF));
end;

procedure TTLCS900H.op_CPBMI;
begin
  sub8(RDMEM(m_ea1.d), m_imm2.b.l);
end;

procedure TTLCS900H.op_CPBMR;
begin
  sub8(RDMEM(m_ea1.d), (m_p2_reg8)^);
end;

procedure TTLCS900H.op_CPBRI;
begin
  sub8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_CPBRM;
begin
  sub8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_CPBRR;
begin
  sub8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_CPWMI;
begin
  sub16(RDMEMW(m_ea1.d), m_imm2.w.l);
end;

procedure TTLCS900H.op_CPWMR;
begin
  sub16(RDMEMW(m_ea1.d), (m_p2_reg16)^);
end;

procedure TTLCS900H.op_CPWRI;
begin
  sub16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_CPWRM;
begin
  sub16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_CPWRR;
begin
  sub16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_CPLMR;
begin
  sub32(RDMEML(m_ea1.d), (m_p2_reg32)^);
end;

procedure TTLCS900H.op_CPLRI;
begin
  sub32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_CPLRM;
begin
  sub32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_CPLRR;
begin
  sub32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_CPD;
var
  vresult: Byte;
  bc: PWord;
begin
  vresult := Byte(((Int64((get_reg8_current(Byte(1)))^) - RDMEM((m_p2_reg32)^)) and $FF));
  bc := get_reg16_current(1);
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult and FLAG_SF) or Choose((vresult <> 0), FLAG_NF, (FLAG_NF or FLAG_ZF))) or Choose(((bc)^ <> 0), FLAG_VF, 0))) and $FF));
end;

procedure TTLCS900H.op_CPDR;
begin
  op_CPD;
  if ((m_sr.b.l and (FLAG_ZF or FLAG_VF)) = FLAG_VF) then
  begin
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_CPDW;
var
  vresult: Word;
  bc: PWord;
begin
  vresult := Word(((Int64((get_reg16_current(Byte(0)))^) - RDMEMW((m_p2_reg32)^)) and $FFFF));
  bc := get_reg16_current(1);
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), FLAG_NF, (FLAG_NF or FLAG_ZF))) or Choose(((bc)^ <> 0), FLAG_VF, 0))) and $FF));
end;

procedure TTLCS900H.op_CPDRW;
begin
  op_CPDW;
  if ((m_sr.b.l and (FLAG_ZF or FLAG_VF)) = FLAG_VF) then
  begin
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_CPI;
var
  vresult: Byte;
  bc: PWord;
begin
  vresult := Byte(((Int64((get_reg8_current(Byte(1)))^) - RDMEM((m_p2_reg32)^)) and $FF));
  bc := get_reg16_current(1);
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((vresult and FLAG_SF) or Choose((vresult <> 0), FLAG_NF, (FLAG_NF or FLAG_ZF))) or Choose(((bc)^ <> 0), FLAG_VF, 0))) and $FF));
end;

procedure TTLCS900H.op_CPIR;
begin
  op_CPI;
  if ((m_sr.b.l and (FLAG_ZF or FLAG_VF)) = FLAG_VF) then
  begin
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_CPIW;
var
  vresult: Word;
  bc: PWord;
begin
  vresult := Word(((Int64((get_reg16_current(Byte(0)))^) - RDMEMW((m_p2_reg32)^)) and $FFFF));
  bc := get_reg16_current(1);
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((vresult shr 8) and FLAG_SF) or Choose((vresult <> 0), FLAG_NF, (FLAG_NF or FLAG_ZF))) or Choose(((bc)^ <> 0), FLAG_VF, 0))) and $FF));
end;

procedure TTLCS900H.op_CPIRW;
begin
  op_CPIW;
  if ((m_sr.b.l and (FLAG_ZF or FLAG_VF)) = FLAG_VF) then
  begin
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_CPLBR;
begin
  (m_p1_reg8)^ := Byte(((not (m_p1_reg8)^) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (FLAG_HF or FLAG_NF)) and $FF));
end;

procedure TTLCS900H.op_CPLWR;
begin
  (m_p1_reg16)^ := Word(((not (m_p1_reg16)^) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l or (FLAG_HF or FLAG_NF)) and $FF));
end;

procedure TTLCS900H.op_DAABR;
var
  oldval: Byte;
  fixval: Byte;
  carry: Byte;
  high: Byte;
  low: Byte;
begin
  oldval := (m_p1_reg8)^;
  fixval := 0;
  carry := 0;
  high := Byte((((m_p1_reg8)^ and $f0) and $FF));
  low := Byte((((m_p1_reg8)^ and $0f) and $FF));
  if ((m_sr.b.l and FLAG_CF) <> 0) then
  begin
    if ((m_sr.b.l and FLAG_HF) <> 0) then
    begin
      fixval := $66;
    end
    else
    begin
      if (low < $0a) then
        fixval := $60
      else
        fixval := $66;
    end;
    carry := 1;
  end
  else
  begin
    if ((m_sr.b.l and FLAG_HF) <> 0) then
    begin
      if ((m_p1_reg8)^ < $9a) then
        fixval := $06
      else
        fixval := $66;
    end
    else
    begin
      if ((high < $90) and (low > $09)) then
        fixval := $06
      else if ((high > $80) and (low > $09)) then
        fixval := $66
      else if ((high > $90) and (low < $0a)) then
        fixval := $60;
    end;
  end;
  m_sr.b.l := Byte(((m_sr.b.l and (not ((((FLAG_VF or FLAG_SF) or FLAG_ZF) or FLAG_HF) or FLAG_CF))) and $FF));
  if ((m_sr.b.l and FLAG_NF) <> 0) then
  begin
    (m_p1_reg8)^ := Byte(((Int64((m_p1_reg8)^) - fixval) and $FF));
    m_sr.b.l := Byte(((m_sr.b.l or Choose((((m_p1_reg8)^ > oldval) or (carry <> 0)), FLAG_CF, 0)) and $FF));
  end
  else
  begin
    (m_p1_reg8)^ := Byte(((Int64((m_p1_reg8)^) + fixval) and $FF));
    m_sr.b.l := Byte(((m_sr.b.l or Choose((((m_p1_reg8)^ < oldval) or (carry <> 0)), FLAG_CF, 0)) and $FF));
  end;
  m_sr.b.l := Byte(((m_sr.b.l or ((((m_p1_reg8)^ and FLAG_SF) or Choose(((m_p1_reg8)^ <> 0), 0, FLAG_ZF)) or (((oldval xor fixval) xor (m_p1_reg8)^) and FLAG_HF))) and $FF));
  parity8((m_p1_reg8)^);
end;

procedure TTLCS900H.op_DB;
begin
  IllegalInstruction;
end;

procedure TTLCS900H.op_DECBIM;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  WRMEM(m_ea2.d, sub8(RDMEM(m_ea2.d), Byte(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8))));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_DECBIR;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  (m_p2_reg8)^ := sub8((m_p2_reg8)^, Byte(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_DECWIM;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  WRMEMW(m_ea2.d, sub16(RDMEMW(m_ea2.d), Word(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8))));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_DECWIR;
begin
  (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)) and $FFFF));
end;

procedure TTLCS900H.op_DECLIR;
begin
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)) and $FFFFFFFF));
end;

procedure TTLCS900H.op_DECF;
begin
  m_sr.b.h := Byte((((m_sr.b.h and $f8) or ((Int64(m_sr.b.h) - 1) and $07)) and $FF));
  m_regbank := (m_sr.b.h and $03);
end;

procedure TTLCS900H.op_DIVBRI;
begin
  (m_p1_reg16)^ := div8((m_p1_reg16)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_DIVBRM;
begin
  (m_p1_reg16)^ := div8((m_p1_reg16)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_DIVBRR;
begin
  (m_p1_reg16)^ := div8((m_p1_reg16)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_DIVWRI;
begin
  (m_p1_reg32)^ := div16((m_p1_reg32)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_DIVWRM;
begin
  (m_p1_reg32)^ := div16((m_p1_reg32)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_DIVWRR;
begin
  (m_p1_reg32)^ := div16((m_p1_reg32)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_DIVSBRI;
begin
  (m_p1_reg16)^ := divs8(Smallint((m_p1_reg16)^), Shortint(m_imm2.b.l));
end;

procedure TTLCS900H.op_DIVSBRM;
begin
  (m_p1_reg16)^ := divs8(Smallint((m_p1_reg16)^), Shortint(RDMEM(m_ea2.d)));
end;

procedure TTLCS900H.op_DIVSBRR;
begin
  (m_p1_reg16)^ := divs8(Smallint((m_p1_reg16)^), Shortint((m_p2_reg8)^));
end;

procedure TTLCS900H.op_DIVSWRI;
begin
  (m_p1_reg32)^ := divs16(Integer((m_p1_reg32)^), Smallint(m_imm2.w.l));
end;

procedure TTLCS900H.op_DIVSWRM;
begin
  (m_p1_reg32)^ := divs16(Integer((m_p1_reg32)^), Smallint(RDMEMW(m_ea2.d)));
end;

procedure TTLCS900H.op_DIVSWRR;
begin
  (m_p1_reg32)^ := divs16(Integer((m_p1_reg32)^), Smallint((m_p2_reg16)^));
end;

procedure TTLCS900H.op_DJNZB;
begin
  (m_p1_reg8)^ := Byte(((Int64((m_p1_reg8)^) - 1) and $FF));
  if ((m_p1_reg8)^ <> 0) then
  begin
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 2));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_DJNZW;
begin
  (m_p1_reg16)^ := Word(((Int64((m_p1_reg16)^) - 1) and $FFFF));
  if ((m_p1_reg16)^ <> 0) then
  begin
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 2));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_EI;
begin
  m_sr.b.h := Byte((((m_sr.b.h and $8f) or ((m_imm1.b.l and $07) shl 4)) and $FF));
  m_check_irqs := 1;
  m_irq_inhibit := true;
end;

procedure TTLCS900H.op_EXBMR;
var
  i: Byte;
begin
  i := RDMEM(m_ea1.d);
  WRMEM(m_ea1.d, (m_p2_reg8)^);
  (m_p2_reg8)^ := i;
end;

procedure TTLCS900H.op_EXBRR;
var
  i: Byte;
begin
  i := (m_p2_reg8)^;
  (m_p2_reg8)^ := (m_p1_reg8)^;
  (m_p1_reg8)^ := i;
end;

procedure TTLCS900H.op_EXWMR;
var
  i: Word;
begin
  i := RDMEMW(m_ea1.d);
  WRMEMW(m_ea1.d, (m_p2_reg16)^);
  (m_p2_reg16)^ := i;
end;

procedure TTLCS900H.op_EXWRR;
var
  i: Word;
begin
  i := (m_p2_reg16)^;
  (m_p2_reg16)^ := (m_p1_reg16)^;
  (m_p1_reg16)^ := i;
end;

procedure TTLCS900H.op_EXTSWR;
begin
  if (((m_p1_reg16)^ and $0080) <> 0) then
    (m_p1_reg16)^ := Word((((m_p1_reg16)^ or $ff00) and $FFFF))
  else
    (m_p1_reg16)^ := Word((((m_p1_reg16)^ and $00ff) and $FFFF));
end;

procedure TTLCS900H.op_EXTSLR;
begin
  if (((m_p1_reg32)^ and $00008000) <> 0) then
    (m_p1_reg32)^ := Cardinal((((m_p1_reg32)^ or $ffff0000) and $FFFFFFFF))
  else
    (m_p1_reg32)^ := Cardinal((((m_p1_reg32)^ and $0000ffff) and $FFFFFFFF));
end;

procedure TTLCS900H.op_EXTZWR;
begin
  (m_p1_reg16)^ := Word((((m_p1_reg16)^ and $00ff) and $FFFF));
end;

procedure TTLCS900H.op_EXTZLR;
begin
  (m_p1_reg32)^ := Cardinal((((m_p1_reg32)^ and $0000ffff) and $FFFFFFFF));
end;

procedure TTLCS900H.op_HALT;
begin
  m_halted := 1;
end;

procedure TTLCS900H.op_INCBIM;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  WRMEM(m_ea2.d, add8(RDMEM(m_ea2.d), Byte(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8))));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_INCBIR;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  (m_p2_reg8)^ := add8((m_p2_reg8)^, Byte(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_INCWIM;
var
  cy: Byte;
begin
  cy := Byte(((m_sr.b.l and FLAG_CF) and $FF));
  WRMEMW(m_ea2.d, add16(RDMEMW(m_ea2.d), Word(Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8))));
  m_sr.b.l := Byte((((m_sr.b.l and Byte((not FLAG_CF))) or cy) and $FF));
end;

procedure TTLCS900H.op_INCWIR;
begin
  (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)) and $FFFF));
end;

procedure TTLCS900H.op_INCLIR;
begin
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + Choose((m_imm1.b.l <> 0), m_imm1.b.l, 8)) and $FFFFFFFF));
end;

procedure TTLCS900H.op_INCF;
begin
  m_sr.b.h := Byte((((m_sr.b.h and $f8) or ((Int64(m_sr.b.h) + 1) and $07)) and $FF));
  m_regbank := (m_sr.b.h and $03);
end;

procedure TTLCS900H.op_JPI;
begin
  m_pc.d := m_imm1.d;
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_JPM;
begin
  if (condition_true(m_op) <> 0) then
  begin
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 3));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_JR;
begin
  if (condition_true(m_op) <> 0) then
  begin
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 3));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_JRL;
begin
  if (condition_true(m_op) <> 0) then
  begin
    m_pc.d := m_ea2.d;
    m_cycles := Integer((Int64(m_cycles) + 3));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_LDBMI;
begin
  WRMEM(m_ea1.d, m_imm2.b.l);
end;

procedure TTLCS900H.op_LDBMM;
begin
  WRMEM(m_ea1.d, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_LDBMR;
begin
  WRMEM(m_ea1.d, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_LDBRI;
begin
  (m_p1_reg8)^ := m_imm2.b.l;
end;

procedure TTLCS900H.op_LDBRM;
begin
  (m_p1_reg8)^ := RDMEM(m_ea2.d);
end;

procedure TTLCS900H.op_LDBRR;
begin
  (m_p1_reg8)^ := (m_p2_reg8)^;
end;

procedure TTLCS900H.op_LDWMI;
begin
  WRMEMW(m_ea1.d, m_imm2.w.l);
end;

procedure TTLCS900H.op_LDWMM;
begin
  WRMEMW(m_ea1.d, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_LDWMR;
begin
  WRMEMW(m_ea1.d, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_LDWRI;
begin
  (m_p1_reg16)^ := m_imm2.w.l;
end;

procedure TTLCS900H.op_LDWRM;
begin
  (m_p1_reg16)^ := RDMEMW(m_ea2.d);
end;

procedure TTLCS900H.op_LDWRR;
begin
  (m_p1_reg16)^ := (m_p2_reg16)^;
end;

procedure TTLCS900H.op_LDLRI;
begin
  (m_p1_reg32)^ := m_imm2.d;
end;

procedure TTLCS900H.op_LDLRM;
begin
  (m_p1_reg32)^ := RDMEML(m_ea2.d);
end;

procedure TTLCS900H.op_LDLRR;
begin
  (m_p1_reg32)^ := (m_p2_reg32)^;
end;

procedure TTLCS900H.op_LDLMR;
begin
  WRMEML(m_ea1.d, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_LDAW;
begin
  (m_p1_reg16)^ := m_ea2.w.l;
end;

procedure TTLCS900H.op_LDAL;
begin
  (m_p1_reg32)^ := m_ea2.d;
end;

procedure TTLCS900H.op_LDCBRR;
begin
  (m_p1_reg8)^ := (m_p2_reg8)^;
end;

procedure TTLCS900H.op_LDCWRR;
begin
  (m_p1_reg16)^ := (m_p2_reg16)^;
end;

procedure TTLCS900H.op_LDCLRR;
begin
  (m_p1_reg32)^ := (m_p2_reg32)^;
end;

procedure TTLCS900H.op_LDCFBIM;
begin
  ldcf8(m_imm1.b.l, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_LDCFBIR;
begin
  ldcf8(m_imm1.b.l, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_LDCFBRM;
begin
  ldcf8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_LDCFBRR;
begin
  ldcf8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_LDCFWIR;
begin
  ldcf16(m_imm1.b.l, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_LDCFWRR;
begin
  ldcf16((m_p1_reg8)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_LDD;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEM((m_p1_reg32)^, RDMEM((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) - 1) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
  end;
end;

procedure TTLCS900H.op_LDDR;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEM((m_p1_reg32)^, RDMEM((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) - 1) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_LDDRW;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEMW((m_p1_reg32)^, RDMEMW((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) - 2) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_LDDW;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEMW((m_p1_reg32)^, RDMEMW((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) - 2) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) - 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
  end;
end;

procedure TTLCS900H.op_LDF;
begin
  m_sr.b.h := Byte((((m_sr.b.h and $f8) or (m_imm1.b.l and $07)) and $FF));
  m_regbank := (m_imm1.b.l and $03);
end;

procedure TTLCS900H.op_LDI;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEM((m_p1_reg32)^, RDMEM((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + 1) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
  end;
end;

procedure TTLCS900H.op_LDIR;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEM((m_p1_reg32)^, RDMEM((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + 1) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 1) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_LDIRW;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEMW((m_p1_reg32)^, RDMEMW((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + 2) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
    m_pc.d := Cardinal(((Int64(m_pc.d) - 2) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + (-1)));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_LDIW;
var
  bc: PWord;
begin
  bc := get_reg16_current(1);
  WRMEMW((m_p1_reg32)^, RDMEMW((m_p2_reg32)^));
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + 2) and $FFFFFFFF));
  (m_p2_reg32)^ := Cardinal(((Int64((m_p2_reg32)^) + 2) and $FFFFFFFF));
  (bc)^ := Word(((Int64((bc)^) - 1) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_VF) or FLAG_NF))) and $FF));
  if ((bc)^ <> 0) then
  begin
    m_sr.b.l := Byte(((m_sr.b.l or FLAG_VF) and $FF));
  end;
end;

procedure TTLCS900H.op_LDX;
var
  a: Byte;
  b: Byte;
begin
  RDOP;
  a := RDOP;
  RDOP;
  b := RDOP;
  RDOP;
  WRMEM(Cardinal(a), b);
end;

procedure TTLCS900H.op_LINK;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, (m_p1_reg32)^);
  (m_p1_reg32)^ := m_xssp.d;
  m_xssp.d := AddDisplacement(m_xssp.d, Integer(m_imm2.sw.l));
end;

procedure TTLCS900H.op_MAX;
begin
  m_sr.b.h := Byte(((m_sr.b.h or $08) and $FF));
end;

procedure TTLCS900H.op_MDEC1;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - 1) and $FFFF));
end;

procedure TTLCS900H.op_MDEC2;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - 2) and $FFFF));
end;

procedure TTLCS900H.op_MDEC4;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - 4) and $FFFF));
end;

procedure TTLCS900H.op_MINC1;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + 1) and $FFFF));
end;

procedure TTLCS900H.op_MINC2;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + 2) and $FFFF));
end;

procedure TTLCS900H.op_MINC4;
begin
  if (((m_p2_reg16)^ and m_imm1.w.l) = m_imm1.w.l) then
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) - m_imm1.w.l) and $FFFF))
  else
    (m_p2_reg16)^ := Word(((Int64((m_p2_reg16)^) + 4) and $FFFF));
end;

procedure TTLCS900H.op_MIRRW;
var
  r: Word;
  s: Word;
  i: Integer;
begin
  r := (m_p1_reg16)^;
  s := Word(((r and $01) and $FFFF));
  i := 0;
  while (i < 15) do
  begin
    begin
      r := Word(((r shr 1) and $FFFF));
      s := Word(((s shl 1) and $FFFF));
      s := Word(((s or (r and $01)) and $FFFF));
    end;
    Inc(i);
  end;
  (m_p1_reg16)^ := s;
end;

procedure TTLCS900H.op_MULBRI;
begin
  (m_p1_reg16)^ := Word(((Int64(((m_p1_reg16)^ and $ff)) * m_imm2.b.l) and $FFFF));
end;

procedure TTLCS900H.op_MULBRM;
begin
  (m_p1_reg16)^ := Word(((Int64(((m_p1_reg16)^ and $ff)) * RDMEM(m_ea2.d)) and $FFFF));
end;

procedure TTLCS900H.op_MULBRR;
begin
  (m_p1_reg16)^ := Word(((Int64(((m_p1_reg16)^ and $ff)) * (m_p2_reg8)^) and $FFFF));
end;

procedure TTLCS900H.op_MULWRI;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(((m_p1_reg32)^ and $ffff)) * m_imm2.w.l) and $FFFFFFFF));
end;

procedure TTLCS900H.op_MULWRM;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(((m_p1_reg32)^ and $ffff)) * RDMEMW(m_ea2.d)) and $FFFFFFFF));
end;

procedure TTLCS900H.op_MULWRR;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(((m_p1_reg32)^ and $ffff)) * (m_p2_reg16)^) and $FFFFFFFF));
end;

procedure TTLCS900H.op_MULAR;
var
  xde: PCardinal;
  xhl: PCardinal;
begin
  xde := get_reg32_current(2);
  xhl := get_reg32_current(3);
  (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + Cardinal((Int64(SmallInt(RDMEMW((xde)^))) * SmallInt(RDMEMW((xhl)^))))) and $FFFFFFFF));
  (xhl)^ := Cardinal(((Int64((xhl)^) - 2) and $FFFFFFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_SF or FLAG_ZF) or FLAG_VF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or ((((m_p1_reg32)^ shr 24) and FLAG_SF) or Choose(((m_p1_reg32)^ <> 0), 0, FLAG_ZF))) and $FF));
end;

procedure TTLCS900H.op_MULSBRI;
begin
  (m_p1_reg16)^ := Word(((Int64(ShortInt(((m_p1_reg16)^ and $ff))) * m_imm2.sb.l) and $FFFF));
end;

procedure TTLCS900H.op_MULSBRM;
begin
  (m_p1_reg16)^ := Word(((Int64(ShortInt(((m_p1_reg16)^ and $ff))) * ShortInt(RDMEM(m_ea2.d))) and $FFFF));
end;

procedure TTLCS900H.op_MULSBRR;
begin
  (m_p1_reg16)^ := Word(((Int64(ShortInt(((m_p1_reg16)^ and $ff))) * ShortInt((m_p2_reg8)^)) and $FFFF));
end;

procedure TTLCS900H.op_MULSWRI;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(SmallInt(((m_p1_reg32)^ and $ffff))) * m_imm2.sw.l) and $FFFFFFFF));
end;

procedure TTLCS900H.op_MULSWRM;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(SmallInt(((m_p1_reg32)^ and $ffff))) * SmallInt(RDMEMW(m_ea2.d))) and $FFFFFFFF));
end;

procedure TTLCS900H.op_MULSWRR;
begin
  (m_p1_reg32)^ := Cardinal(((Int64(SmallInt(((m_p1_reg32)^ and $ffff))) * SmallInt((m_p2_reg16)^)) and $FFFFFFFF));
end;

procedure TTLCS900H.op_NEGBR;
begin
  (m_p1_reg8)^ := sub8(Byte(0), (m_p1_reg8)^);
end;

procedure TTLCS900H.op_NEGWR;
begin
  (m_p1_reg16)^ := sub16(Word(0), (m_p1_reg16)^);
end;

procedure TTLCS900H.op_NOP;
begin
end;

procedure TTLCS900H.op_NORMAL;
begin
  m_sr.b.h := Byte(((m_sr.b.h and $7F) and $FF));
end;

procedure TTLCS900H.op_ORBMI;
begin
  WRMEM(m_ea1.d, or8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_ORBMR;
begin
  WRMEM(m_ea1.d, or8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_ORBRI;
begin
  (m_p1_reg8)^ := or8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_ORBRM;
begin
  (m_p1_reg8)^ := or8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ORBRR;
begin
  (m_p1_reg8)^ := or8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ORWMI;
begin
  WRMEMW(m_ea1.d, or16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_ORWMR;
begin
  WRMEMW(m_ea1.d, or16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_ORWRI;
begin
  (m_p1_reg16)^ := or16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_ORWRM;
begin
  (m_p1_reg16)^ := or16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_ORWRR;
begin
  (m_p1_reg16)^ := or16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ORLMR;
begin
  WRMEML(m_ea1.d, or32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_ORLRI;
begin
  (m_p1_reg32)^ := or32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_ORLRM;
begin
  (m_p1_reg32)^ := or32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_ORLRR;
begin
  (m_p1_reg32)^ := or32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_ORCFBIM;
begin
  orcf8(m_imm1.b.l, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ORCFBIR;
begin
  orcf8(m_imm1.b.l, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ORCFBRM;
begin
  orcf8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_ORCFBRR;
begin
  orcf8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_ORCFWIR;
begin
  orcf16(m_imm1.b.l, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ORCFWRR;
begin
  orcf16((m_p1_reg8)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_PAAWR;
begin
  if (((m_p1_reg16)^ and 1) <> 0) then
    (m_p1_reg16)^ := Word(((Int64((m_p1_reg16)^) + 1) and $FFFF));
end;

procedure TTLCS900H.op_PAALR;
begin
  if (((m_p1_reg32)^ and 1) <> 0) then
    (m_p1_reg32)^ := Cardinal(((Int64((m_p1_reg32)^) + 1) and $FFFFFFFF));
end;

procedure TTLCS900H.op_POPBM;
begin
  WRMEM(m_ea1.d, RDMEM(m_xssp.d));
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 1) and $FFFFFFFF));
end;

procedure TTLCS900H.op_POPBR;
begin
  (m_p1_reg8)^ := RDMEM(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 1) and $FFFFFFFF));
end;

procedure TTLCS900H.op_POPWM;
begin
  WRMEMW(m_ea1.d, RDMEMW(m_xssp.d));
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 2) and $FFFFFFFF));
end;

procedure TTLCS900H.op_POPWR;
begin
  (m_p1_reg16)^ := RDMEMW(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 2) and $FFFFFFFF));
end;

procedure TTLCS900H.op_POPWSR;
begin
  op_POPWR;
  m_regbank := (m_sr.b.h and $03);
  m_check_irqs := 1;
end;

procedure TTLCS900H.op_POPLR;
begin
  (m_p1_reg32)^ := RDMEML(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 4) and $FFFFFFFF));
end;

procedure TTLCS900H.op_PUSHBI;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 1) and $FFFFFFFF));
  WRMEM(m_xssp.d, m_imm1.b.l);
end;

procedure TTLCS900H.op_PUSHBM;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 1) and $FFFFFFFF));
  WRMEM(m_xssp.d, RDMEM(m_ea1.d));
end;

procedure TTLCS900H.op_PUSHBR;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 1) and $FFFFFFFF));
  WRMEM(m_xssp.d, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_PUSHWI;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, m_imm1.w.l);
end;

procedure TTLCS900H.op_PUSHWM;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, RDMEMW(m_ea1.d));
end;

procedure TTLCS900H.op_PUSHWR;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, (m_p1_reg16)^);
end;

procedure TTLCS900H.op_PUSHLR;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, (m_p1_reg32)^);
end;

procedure TTLCS900H.op_RCF;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not ((FLAG_HF or FLAG_NF) or FLAG_CF))) and $FF));
end;

procedure TTLCS900H.op_RESBIM;
begin
  WRMEM(m_ea2.d, Byte((RDMEM(m_ea2.d) and (not (1 shl (m_imm1.d and $07))))));
end;

procedure TTLCS900H.op_RESBIR;
begin
  (m_p2_reg8)^ := Byte((((m_p2_reg8)^ and (not (1 shl (m_imm1.d and $07)))) and $FF));
end;

procedure TTLCS900H.op_RESWIR;
begin
  (m_p2_reg16)^ := Word((((m_p2_reg16)^ and (not (1 shl (m_imm1.d and $0f)))) and $FFFF));
end;

procedure TTLCS900H.op_RET;
begin
  m_pc.d := RDMEML(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 4) and $FFFFFFFF));
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_RETCC;
begin
  if (condition_true(m_op) <> 0) then
  begin
    m_pc.d := RDMEML(m_xssp.d);
    m_xssp.d := Cardinal(((Int64(m_xssp.d) + 4) and $FFFFFFFF));
    m_cycles := Integer((Int64(m_cycles) + 8));
    m_prefetch_clear := true;
  end;
end;

procedure TTLCS900H.op_RETD;
begin
  m_pc.d := RDMEML(m_xssp.d);
  m_xssp.d := Cardinal((AddDisplacement(m_xssp.d, Integer((Int64(4) + m_imm1.sw.l))) and $FFFFFFFF));
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_RETI;
begin
  if (m_intnest <> 0) then
    m_intnest := Word(((Int64(m_intnest) - 1) and $FFFF));
  m_sr.w.l := RDMEMW(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 2) and $FFFFFFFF));
  m_pc.d := RDMEML(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 4) and $FFFFFFFF));
  m_regbank := (m_sr.b.h and $03);
  m_check_irqs := 1;
  m_irq_inhibit := true;
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_RLBM;
begin
  WRMEM(m_ea2.d, rl8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RLWM;
begin
  WRMEMW(m_ea2.d, rl16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RLBIR;
begin
  (m_p2_reg8)^ := rl8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLBRR;
begin
  (m_p2_reg8)^ := rl8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLWIR;
begin
  (m_p2_reg16)^ := rl16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLWRR;
begin
  (m_p2_reg16)^ := rl16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLLIR;
begin
  (m_p2_reg32)^ := rl32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLLRR;
begin
  (m_p2_reg32)^ := rl32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLCBM;
begin
  WRMEM(m_ea2.d, rlc8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RLCWM;
begin
  WRMEMW(m_ea2.d, rlc16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RLCBIR;
begin
  (m_p2_reg8)^ := rlc8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLCBRR;
begin
  (m_p2_reg8)^ := rlc8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLCWIR;
begin
  (m_p2_reg16)^ := rlc16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLCWRR;
begin
  (m_p2_reg16)^ := rlc16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLCLIR;
begin
  (m_p2_reg32)^ := rlc32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RLCLRR;
begin
  (m_p2_reg32)^ := rlc32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RLDRM;
var
  a: Byte;
  b: Byte;
begin
  a := Byte((((m_p1_reg8)^ and $0f) and $FF));
  b := RDMEM(m_ea2.d);
  (m_p1_reg8)^ := Byte(((((m_p1_reg8)^ and $f0) or ((b and $f0) shr 4)) and $FF));
  WRMEM(m_ea2.d, Byte((((b and $0f) shl 4) or a)));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((m_p1_reg8)^ and FLAG_SF) or Choose(((m_p1_reg8)^ <> 0), 0, FLAG_ZF))) and $FF));
  parity8((m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRBM;
begin
  WRMEM(m_ea2.d, rr8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RRWM;
begin
  WRMEMW(m_ea2.d, rr16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RRBIR;
begin
  (m_p2_reg8)^ := rr8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRBRR;
begin
  (m_p2_reg8)^ := rr8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRWIR;
begin
  (m_p2_reg16)^ := rr16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRWRR;
begin
  (m_p2_reg16)^ := rr16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRLIR;
begin
  (m_p2_reg32)^ := rr32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRLRR;
begin
  (m_p2_reg32)^ := rr32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRCBM;
begin
  WRMEM(m_ea2.d, rrc8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RRCWM;
begin
  WRMEMW(m_ea2.d, rrc16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_RRCBIR;
begin
  (m_p2_reg8)^ := rrc8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRCBRR;
begin
  (m_p2_reg8)^ := rrc8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRCWIR;
begin
  (m_p2_reg16)^ := rrc16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRCWRR;
begin
  (m_p2_reg16)^ := rrc16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRCLIR;
begin
  (m_p2_reg32)^ := rrc32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_RRCLRR;
begin
  (m_p2_reg32)^ := rrc32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_RRDRM;
var
  a: Byte;
  b: Byte;
begin
  a := Byte((((m_p1_reg8)^ and $0f) and $FF));
  b := RDMEM(m_ea2.d);
  (m_p1_reg8)^ := Byte(((((m_p1_reg8)^ and $f0) or (b and $0f)) and $FF));
  WRMEM(m_ea2.d, Byte((((b and $f0) shr 4) or (a shl 4))));
  m_sr.b.l := Byte(((m_sr.b.l and (not (((((FLAG_SF or FLAG_ZF) or FLAG_HF) or FLAG_VF) or FLAG_NF) or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (((m_p1_reg8)^ and FLAG_SF) or Choose(((m_p1_reg8)^ <> 0), 0, FLAG_ZF))) and $FF));
  parity8((m_p1_reg8)^);
end;

procedure TTLCS900H.op_SBCBMI;
begin
  WRMEM(m_ea1.d, sbc8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_SBCBMR;
begin
  WRMEM(m_ea1.d, sbc8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_SBCBRI;
begin
  (m_p1_reg8)^ := sbc8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_SBCBRM;
begin
  (m_p1_reg8)^ := sbc8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_SBCBRR;
begin
  (m_p1_reg8)^ := sbc8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_SBCWMI;
begin
  WRMEMW(m_ea1.d, sbc16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_SBCWMR;
begin
  WRMEMW(m_ea1.d, sbc16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_SBCWRI;
begin
  (m_p1_reg16)^ := sbc16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_SBCWRM;
begin
  (m_p1_reg16)^ := sbc16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_SBCWRR;
begin
  (m_p1_reg16)^ := sbc16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_SBCLMR;
begin
  WRMEML(m_ea1.d, sbc32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_SBCLRI;
begin
  (m_p1_reg32)^ := sbc32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_SBCLRM;
begin
  (m_p1_reg32)^ := sbc32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_SBCLRR;
begin
  (m_p1_reg32)^ := sbc32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_SCCBR;
begin
  (m_p2_reg8)^ := Choose((condition_true(m_op) <> 0), 1, 0);
end;

procedure TTLCS900H.op_SCCWR;
begin
  (m_p2_reg16)^ := Choose((condition_true(m_op) <> 0), 1, 0);
end;

procedure TTLCS900H.op_SCF;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_HF or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or FLAG_CF) and $FF));
end;

procedure TTLCS900H.op_SETBIM;
begin
  WRMEM(m_ea2.d, Byte((RDMEM(m_ea2.d) or (1 shl (m_imm1.d and $07)))));
end;

procedure TTLCS900H.op_SETBIR;
begin
  (m_p2_reg8)^ := Byte((((m_p2_reg8)^ or (1 shl (m_imm1.d and $07))) and $FF));
end;

procedure TTLCS900H.op_SETWIR;
begin
  (m_p2_reg16)^ := Word((((m_p2_reg16)^ or (1 shl (m_imm1.d and $0f))) and $FFFF));
end;

procedure TTLCS900H.op_SLABM;
begin
  WRMEM(m_ea2.d, sla8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SLAWM;
begin
  WRMEMW(m_ea2.d, sla16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SLABIR;
begin
  (m_p2_reg8)^ := sla8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLABRR;
begin
  (m_p2_reg8)^ := sla8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SLAWIR;
begin
  (m_p2_reg16)^ := sla16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLAWRR;
begin
  (m_p2_reg16)^ := sla16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SLALIR;
begin
  (m_p2_reg32)^ := sla32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLALRR;
begin
  (m_p2_reg32)^ := sla32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SLLBM;
begin
  WRMEM(m_ea2.d, sla8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SLLWM;
begin
  WRMEMW(m_ea2.d, sla16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SLLBIR;
begin
  (m_p2_reg8)^ := sla8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLLBRR;
begin
  (m_p2_reg8)^ := sla8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SLLWIR;
begin
  (m_p2_reg16)^ := sla16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLLWRR;
begin
  (m_p2_reg16)^ := sla16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SLLLIR;
begin
  (m_p2_reg32)^ := sla32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SLLLRR;
begin
  (m_p2_reg32)^ := sla32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRABM;
begin
  WRMEM(m_ea2.d, sra8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SRAWM;
begin
  WRMEMW(m_ea2.d, sra16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SRABIR;
begin
  (m_p2_reg8)^ := sra8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRABRR;
begin
  (m_p2_reg8)^ := sra8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRAWIR;
begin
  (m_p2_reg16)^ := sra16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRAWRR;
begin
  (m_p2_reg16)^ := sra16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRALIR;
begin
  (m_p2_reg32)^ := sra32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRALRR;
begin
  (m_p2_reg32)^ := sra32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRLBM;
begin
  WRMEM(m_ea2.d, srl8(RDMEM(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SRLWM;
begin
  WRMEMW(m_ea2.d, srl16(RDMEMW(m_ea2.d), Byte(1)));
end;

procedure TTLCS900H.op_SRLBIR;
begin
  (m_p2_reg8)^ := srl8((m_p2_reg8)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRLBRR;
begin
  (m_p2_reg8)^ := srl8((m_p2_reg8)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRLWIR;
begin
  (m_p2_reg16)^ := srl16((m_p2_reg16)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRLWRR;
begin
  (m_p2_reg16)^ := srl16((m_p2_reg16)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_SRLLIR;
begin
  (m_p2_reg32)^ := srl32((m_p2_reg32)^, m_imm1.b.l);
end;

procedure TTLCS900H.op_SRLLRR;
begin
  (m_p2_reg32)^ := srl32((m_p2_reg32)^, (m_p1_reg8)^);
end;

procedure TTLCS900H.op_STCFBIM;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    WRMEM(m_ea2.d, (RDMEM(m_ea2.d) or (1 shl (m_imm1.b.l and $07))))
  else
    WRMEM(m_ea2.d, Byte((RDMEM(m_ea2.d) and (not (1 shl (m_imm1.b.l and $07))))));
end;

procedure TTLCS900H.op_STCFBIR;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    (m_p2_reg8)^ := Byte((((m_p2_reg8)^ or (1 shl (m_imm1.b.l and $07))) and $FF))
  else
    (m_p2_reg8)^ := Byte((((m_p2_reg8)^ and (not (1 shl (m_imm1.b.l and $07)))) and $FF));
end;

procedure TTLCS900H.op_STCFBRM;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    WRMEM(m_ea2.d, (RDMEM(m_ea2.d) or (1 shl ((m_p1_reg8)^ and $07))))
  else
    WRMEM(m_ea2.d, Byte((RDMEM(m_ea2.d) and (not (1 shl ((m_p1_reg8)^ and $07))))));
end;

procedure TTLCS900H.op_STCFBRR;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    (m_p2_reg8)^ := Byte((((m_p2_reg8)^ or (1 shl ((m_p1_reg8)^ and $07))) and $FF))
  else
    (m_p2_reg8)^ := Byte((((m_p2_reg8)^ and (not (1 shl ((m_p1_reg8)^ and $07)))) and $FF));
end;

procedure TTLCS900H.op_STCFWIR;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    (m_p2_reg16)^ := Word((((m_p2_reg16)^ or (1 shl (m_imm1.b.l and $0f))) and $FFFF))
  else
    (m_p2_reg16)^ := Word((((m_p2_reg16)^ and (not (1 shl (m_imm1.b.l and $0f)))) and $FFFF));
end;

procedure TTLCS900H.op_STCFWRR;
begin
  if ((m_sr.b.l and FLAG_CF) <> 0) then
    (m_p2_reg16)^ := Word((((m_p2_reg16)^ or (1 shl ((m_p1_reg8)^ and $0f))) and $FFFF))
  else
    (m_p2_reg16)^ := Word((((m_p2_reg16)^ and (not (1 shl ((m_p1_reg8)^ and $0f)))) and $FFFF));
end;

procedure TTLCS900H.op_SUBBMI;
begin
  WRMEM(m_ea1.d, sub8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_SUBBMR;
begin
  WRMEM(m_ea1.d, sub8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_SUBBRI;
begin
  (m_p1_reg8)^ := sub8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_SUBBRM;
begin
  (m_p1_reg8)^ := sub8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_SUBBRR;
begin
  (m_p1_reg8)^ := sub8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_SUBWMI;
begin
  WRMEMW(m_ea1.d, sub16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_SUBWMR;
begin
  WRMEMW(m_ea1.d, sub16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_SUBWRI;
begin
  (m_p1_reg16)^ := sub16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_SUBWRM;
begin
  (m_p1_reg16)^ := sub16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_SUBWRR;
begin
  (m_p1_reg16)^ := sub16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_SUBLMR;
begin
  WRMEML(m_ea1.d, sub32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_SUBLRI;
begin
  (m_p1_reg32)^ := sub32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_SUBLRM;
begin
  (m_p1_reg32)^ := sub32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_SUBLRR;
begin
  (m_p1_reg32)^ := sub32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_SWI;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, m_sr.w.l);
  m_pc.d := Cardinal((RDMEML(Cardinal((Int64($00ffff00) + (Int64(4) * m_imm1.b.l)))) and $FFFFFFFF));
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_SWI900;
begin
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 4) and $FFFFFFFF));
  WRMEML(m_xssp.d, m_pc.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) - 2) and $FFFFFFFF));
  WRMEMW(m_xssp.d, m_sr.w.l);
  m_pc.d := Cardinal(((Int64($00008000) + (Int64($10) * m_imm1.b.l)) and $FFFFFFFF));
  m_prefetch_clear := true;
end;

procedure TTLCS900H.op_TSETBIM;
var
  b: Byte;
  a: Byte;
begin
  b := Byte(((1 shl (m_imm1.b.l and $07)) and $FF));
  a := RDMEM(m_ea2.d);
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose(((a and b) <> 0), 0, FLAG_ZF) or FLAG_HF)) and $FF));
  WRMEM(m_ea2.d, Byte((a or b)));
end;

procedure TTLCS900H.op_TSETBIR;
var
  b: Byte;
begin
  b := Byte(((1 shl (m_imm1.b.l and $07)) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose((((m_p2_reg8)^ and b) <> 0), 0, FLAG_ZF) or FLAG_HF)) and $FF));
  (m_p2_reg8)^ := Byte((((m_p2_reg8)^ or b) and $FF));
end;

procedure TTLCS900H.op_TSETWIR;
var
  b: Word;
begin
  b := Word(((1 shl (m_imm1.b.l and $0f)) and $FFFF));
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_ZF or FLAG_NF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or (Choose((((m_p2_reg16)^ and b) <> 0), 0, FLAG_ZF) or FLAG_HF)) and $FF));
  (m_p2_reg16)^ := Word((((m_p2_reg16)^ or b) and $FFFF));
end;

procedure TTLCS900H.op_UNLK;
begin
  m_xssp.d := (m_p1_reg32)^;
  (m_p1_reg32)^ := RDMEML(m_xssp.d);
  m_xssp.d := Cardinal(((Int64(m_xssp.d) + 4) and $FFFFFFFF));
end;

procedure TTLCS900H.op_XORBMI;
begin
  WRMEM(m_ea1.d, xor8(RDMEM(m_ea1.d), m_imm2.b.l));
end;

procedure TTLCS900H.op_XORBMR;
begin
  WRMEM(m_ea1.d, xor8(RDMEM(m_ea1.d), (m_p2_reg8)^));
end;

procedure TTLCS900H.op_XORBRI;
begin
  (m_p1_reg8)^ := xor8((m_p1_reg8)^, m_imm2.b.l);
end;

procedure TTLCS900H.op_XORBRM;
begin
  (m_p1_reg8)^ := xor8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_XORBRR;
begin
  (m_p1_reg8)^ := xor8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_XORWMI;
begin
  WRMEMW(m_ea1.d, xor16(RDMEMW(m_ea1.d), m_imm2.w.l));
end;

procedure TTLCS900H.op_XORWMR;
begin
  WRMEMW(m_ea1.d, xor16(RDMEMW(m_ea1.d), (m_p2_reg16)^));
end;

procedure TTLCS900H.op_XORWRI;
begin
  (m_p1_reg16)^ := xor16((m_p1_reg16)^, m_imm2.w.l);
end;

procedure TTLCS900H.op_XORWRM;
begin
  (m_p1_reg16)^ := xor16((m_p1_reg16)^, RDMEMW(m_ea2.d));
end;

procedure TTLCS900H.op_XORWRR;
begin
  (m_p1_reg16)^ := xor16((m_p1_reg16)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_XORLMR;
begin
  WRMEML(m_ea1.d, xor32(RDMEML(m_ea1.d), (m_p2_reg32)^));
end;

procedure TTLCS900H.op_XORLRI;
begin
  (m_p1_reg32)^ := xor32((m_p1_reg32)^, m_imm2.d);
end;

procedure TTLCS900H.op_XORLRM;
begin
  (m_p1_reg32)^ := xor32((m_p1_reg32)^, RDMEML(m_ea2.d));
end;

procedure TTLCS900H.op_XORLRR;
begin
  (m_p1_reg32)^ := xor32((m_p1_reg32)^, (m_p2_reg32)^);
end;

procedure TTLCS900H.op_XORCFBIM;
begin
  xorcf8(m_imm1.b.l, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_XORCFBIR;
begin
  xorcf8(m_imm1.b.l, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_XORCFBRM;
begin
  xorcf8((m_p1_reg8)^, RDMEM(m_ea2.d));
end;

procedure TTLCS900H.op_XORCFBRR;
begin
  xorcf8((m_p1_reg8)^, (m_p2_reg8)^);
end;

procedure TTLCS900H.op_XORCFWIR;
begin
  xorcf16(m_imm1.b.l, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_XORCFWRR;
begin
  xorcf16((m_p1_reg8)^, (m_p2_reg16)^);
end;

procedure TTLCS900H.op_ZCF;
begin
  m_sr.b.l := Byte(((m_sr.b.l and (not (FLAG_NF or FLAG_CF))) and $FF));
  m_sr.b.l := Byte(((m_sr.b.l or Choose(((m_sr.b.l and FLAG_ZF) <> 0), 0, FLAG_CF)) and $FF));
end;

procedure TTLCS900H.prepare_operands(inst: PInstruction);
begin
  case inst^.operand1 of
    p_A:
      begin
        m_p1_reg8 := (@m_xwa[m_regbank].B.l);
      end;
    p_F:
      begin
        m_p1_reg8 := (@m_sr.b.l);
      end;
    p_SR:
      begin
        m_p1_reg16 := (@m_sr.w.l);
      end;
    p_C8:
      begin
        m_p1_reg8 := get_reg8_current(m_op);
      end;
    p_C16:
      begin
        m_p1_reg16 := get_reg16_current(m_op);
      end;
    p_MC16:
      begin
        m_p1_reg16 := get_reg16_current(((m_op shr 1) and $03));
      end;
    p_C32:
      begin
        m_p1_reg32 := get_reg32_current(m_op);
      end;
    p_CR8:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $22:
            begin
              m_p1_reg8 := (@m_dmam[0].B.l);
            end;
          $26:
            begin
              m_p1_reg8 := (@m_dmam[1].B.l);
            end;
          $2a:
            begin
              m_p1_reg8 := (@m_dmam[2].B.l);
            end;
          $2e:
            begin
              m_p1_reg8 := (@m_dmam[3].B.l);
            end;
          $42:
            begin
              m_p1_reg8 := (@m_dmam[0].B.l);
            end;
          $46:
            begin
              m_p1_reg8 := (@m_dmam[1].B.l);
            end;
          $4a:
            begin
              m_p1_reg8 := (@m_dmam[2].B.l);
            end;
          $4e:
            begin
              m_p1_reg8 := (@m_dmam[3].B.l);
            end;
        else
          begin
            m_p1_reg8 := (@m_dummy.b.l);
          end;
        end;
      end;
    p_CR16:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $20:
            begin
              m_p1_reg16 := (@m_dmac[0].w.l);
            end;
          $24:
            begin
              m_p1_reg16 := (@m_dmac[1].w.l);
            end;
          $28:
            begin
              m_p1_reg16 := (@m_dmac[2].w.l);
            end;
          $2c:
            begin
              m_p1_reg16 := (@m_dmac[3].w.l);
            end;
          $40:
            begin
              m_p1_reg16 := (@m_dmac[0].w.l);
            end;
          $44:
            begin
              m_p1_reg16 := (@m_dmac[1].w.l);
            end;
          $48:
            begin
              m_p1_reg16 := (@m_dmac[2].w.l);
            end;
          $4c:
            begin
              m_p1_reg16 := (@m_dmac[3].w.l);
            end;
          $3c, $7c:
            begin
              m_p1_reg16 := (@m_intnest);
            end;
        else
          begin
            m_p1_reg16 := (@m_dummy.w.l);
          end;
        end;
      end;
    p_CR32:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $00:
            begin
              m_p1_reg32 := (@m_dmas[0].d);
            end;
          $04:
            begin
              m_p1_reg32 := (@m_dmas[1].d);
            end;
          $08:
            begin
              m_p1_reg32 := (@m_dmas[2].d);
            end;
          $0c:
            begin
              m_p1_reg32 := (@m_dmas[3].d);
            end;
          $10:
            begin
              m_p1_reg32 := (@m_dmad[0].d);
            end;
          $14:
            begin
              m_p1_reg32 := (@m_dmad[1].d);
            end;
          $18:
            begin
              m_p1_reg32 := (@m_dmad[2].d);
            end;
          $1c:
            begin
              m_p1_reg32 := (@m_dmad[3].d);
            end;
          $20:
            begin
              m_p1_reg32 := (@m_dmad[0].d);
            end;
          $24:
            begin
              m_p1_reg32 := (@m_dmad[1].d);
            end;
          $28:
            begin
              m_p1_reg32 := (@m_dmad[2].d);
            end;
          $2c:
            begin
              m_p1_reg32 := (@m_dmad[3].d);
            end;
        else
          begin
            m_p1_reg32 := (@m_dummy.d);
          end;
        end;
      end;
    p_D8:
      begin
        m_ea1.d := RDOP;
        m_ea1.d := AddDisplacement(m_pc.d, Integer(m_ea1.sb.l));
      end;
    p_D16:
      begin
        m_ea1.d := RDOP;
        m_ea1.b.h := RDOP;
        m_ea1.d := AddDisplacement(m_pc.d, Integer(m_ea1.sw.l));
      end;
    p_I3:
      begin
        m_imm1.d := Cardinal(((m_op and $07) and $FFFFFFFF));
      end;
    p_I8:
      begin
        m_imm1.d := RDOP;
      end;
    p_I16:
      begin
        m_imm1.d := RDOP;
        m_imm1.b.h := RDOP;
      end;
    p_I24:
      begin
        m_imm1.d := RDOP;
        m_imm1.b.h := RDOP;
        m_imm1.b.h2 := RDOP;
      end;
    p_I32:
      begin
        m_imm1.d := RDOP;
        m_imm1.b.h := RDOP;
        m_imm1.b.h2 := RDOP;
        m_imm1.b.h3 := RDOP;
      end;
    p_M:
      begin
        m_ea1.d := m_ea2.d;
      end;
    p_M8:
      begin
        m_ea1.d := RDOP;
      end;
    p_M16:
      begin
        m_ea1.d := RDOP;
        m_ea1.b.h := RDOP;
      end;
    p_R:
      begin
        m_p1_reg8 := m_p2_reg8;
        m_p1_reg16 := m_p2_reg16;
        m_p1_reg32 := m_p2_reg32;
      end;
  end;
  case inst^.operand2 of
    p_A:
      begin
        m_p2_reg8 := (@m_xwa[m_regbank].B.l);
      end;
    p_F:
      begin
        m_p2_reg8 := (@m_f2.b.l);
      end;
    p_SR:
      begin
        m_p2_reg16 := (@m_sr.w.l);
      end;
    p_C8:
      begin
        m_p2_reg8 := get_reg8_current(m_op);
      end;
    p_C16:
      begin
        m_p2_reg16 := get_reg16_current(m_op);
      end;
    p_C32:
      begin
        m_p2_reg32 := get_reg32_current(m_op);
      end;
    p_CR8:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $22:
            begin
              m_p2_reg8 := (@m_dmam[0].B.l);
            end;
          $26:
            begin
              m_p2_reg8 := (@m_dmam[1].B.l);
            end;
          $2a:
            begin
              m_p2_reg8 := (@m_dmam[2].B.l);
            end;
          $2e:
            begin
              m_p2_reg8 := (@m_dmam[3].B.l);
            end;
          $42:
            begin
              m_p2_reg8 := (@m_dmam[0].B.l);
            end;
          $46:
            begin
              m_p2_reg8 := (@m_dmam[1].B.l);
            end;
          $4a:
            begin
              m_p2_reg8 := (@m_dmam[2].B.l);
            end;
          $4e:
            begin
              m_p2_reg8 := (@m_dmam[3].B.l);
            end;
        else
          begin
            m_p2_reg8 := (@m_dummy.b.l);
          end;
        end;
      end;
    p_CR16:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $20:
            begin
              m_p2_reg16 := (@m_dmac[0].w.l);
            end;
          $24:
            begin
              m_p2_reg16 := (@m_dmac[1].w.l);
            end;
          $28:
            begin
              m_p2_reg16 := (@m_dmac[2].w.l);
            end;
          $2c:
            begin
              m_p2_reg16 := (@m_dmac[3].w.l);
            end;
          $40:
            begin
              m_p2_reg16 := (@m_dmac[0].w.l);
            end;
          $44:
            begin
              m_p2_reg16 := (@m_dmac[1].w.l);
            end;
          $48:
            begin
              m_p2_reg16 := (@m_dmac[2].w.l);
            end;
          $4c:
            begin
              m_p2_reg16 := (@m_dmac[3].w.l);
            end;
          $3c, $7c:
            begin
              m_p2_reg16 := (@m_intnest);
            end;
        else
          begin
            m_p2_reg16 := (@m_dummy.w.l);
          end;
        end;
      end;
    p_CR32:
      begin
        m_imm1.d := RDOP;
        case m_imm1.d of
          $00:
            begin
              m_p2_reg32 := (@m_dmas[0].d);
            end;
          $04:
            begin
              m_p2_reg32 := (@m_dmas[1].d);
            end;
          $08:
            begin
              m_p2_reg32 := (@m_dmas[2].d);
            end;
          $0c:
            begin
              m_p2_reg32 := (@m_dmas[3].d);
            end;
          $10:
            begin
              m_p2_reg32 := (@m_dmad[0].d);
            end;
          $14:
            begin
              m_p2_reg32 := (@m_dmad[1].d);
            end;
          $18:
            begin
              m_p2_reg32 := (@m_dmad[2].d);
            end;
          $1c:
            begin
              m_p2_reg32 := (@m_dmad[3].d);
            end;
          $20:
            begin
              m_p2_reg32 := (@m_dmad[0].d);
            end;
          $24:
            begin
              m_p2_reg32 := (@m_dmad[1].d);
            end;
          $28:
            begin
              m_p2_reg32 := (@m_dmad[2].d);
            end;
          $2c:
            begin
              m_p2_reg32 := (@m_dmad[3].d);
            end;
        else
          begin
            m_p2_reg32 := (@m_dummy.d);
          end;
        end;
      end;
    p_D8:
      begin
        m_ea2.d := RDOP;
        m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sb.l));
      end;
    p_D16:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sw.l));
      end;
    p_I3:
      begin
        m_imm2.d := Cardinal(((m_op and $07) and $FFFFFFFF));
      end;
    p_I8:
      begin
        m_imm2.d := RDOP;
      end;
    p_I16:
      begin
        m_imm2.d := RDOP;
        m_imm2.b.h := RDOP;
      end;
    p_I32:
      begin
        m_imm2.d := RDOP;
        m_imm2.b.h := RDOP;
        m_imm2.b.h2 := RDOP;
        m_imm2.b.h3 := RDOP;
      end;
    p_M8:
      begin
        m_ea2.d := RDOP;
      end;
    p_M16:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
      end;
  end;
end;

procedure TTLCS900H.op_80;
var
  inst: PInstruction;
begin
  m_p1_reg32 := get_reg32_current((m_op - 1));
  m_p2_reg32 := get_reg32_current(m_op);
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  inst := (@m_mnemonic_80[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_88;
var
  inst: PInstruction;
begin
  m_p1_reg32 := get_reg32_current((m_op - 1));
  m_p2_reg32 := get_reg32_current(m_op);
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt(m_op)));
  m_cycles := Integer((Int64(m_cycles) + 1));
  m_op := RDOP;
  inst := (@m_mnemonic_80[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_90;
var
  inst: PInstruction;
begin
  m_p1_reg32 := get_reg32_current((m_op - 1));
  m_p2_reg32 := get_reg32_current(m_op);
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  inst := (@m_mnemonic_90[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_98;
var
  inst: PInstruction;
begin
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt(m_op)));
  m_cycles := Integer((Int64(m_cycles) + 1));
  m_op := RDOP;
  inst := (@m_mnemonic_98[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_A0;
var
  inst: PInstruction;
begin
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  inst := (@m_mnemonic_a0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_A8;
var
  inst: PInstruction;
begin
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt(m_op)));
  m_cycles := Integer((Int64(m_cycles) + 1));
  m_op := RDOP;
  inst := (@m_mnemonic_a0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_B0;
var
  inst: PInstruction;
begin
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  inst := (@m_mnemonic_b0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_B8;
var
  inst: PInstruction;
begin
  m_ea2.d := (get_reg32_current(m_op))^;
  m_op := RDOP;
  m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt(m_op)));
  m_cycles := Integer((Int64(m_cycles) + 1));
  m_op := RDOP;
  inst := (@m_mnemonic_b8[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_C0;
var
  inst: PInstruction;
  reg: PCardinal;
begin
  case (m_op and $07) of
    $00:
      begin
        m_ea2.d := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $01:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 2));
      end;
    $02:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_ea2.b.h2 := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 3));
      end;
    $03:
      begin
        m_op := RDOP;
        case (m_op and $03) of
          $00:
            begin
              m_ea2.d := (get_reg32(m_op))^;
              m_cycles := Integer((Int64(m_cycles) + 1));
            end;
          $01:
            begin
              m_ea2.b.l := RDOP;
              m_ea2.b.h := RDOP;
              m_ea2.d := AddDisplacement((get_reg32(m_op))^, Integer(m_ea2.sw.l));
              m_cycles := Integer((Int64(m_cycles) + 3));
            end;
          $02:
            begin
            end;
          $03:
            begin
              case m_op of
                $03:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt((get_reg8(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $07:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(SmallInt((get_reg16(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $13:
                  begin
                    m_ea2.b.l := RDOP;
                    m_ea2.b.h := RDOP;
                    m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sw.l));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
              end;
            end;
        end;
      end;
    $04:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        (reg)^ := Cardinal(((Int64((reg)^) - (1 shl (m_op and $03))) and $FFFFFFFF));
        m_ea2.d := (reg)^;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $05:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        m_ea2.d := (reg)^;
        (reg)^ := Cardinal(((Int64((reg)^) + (1 shl (m_op and $03))) and $FFFFFFFF));
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_c0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.oC8;
var
  inst: PInstruction;
begin
  if ((m_op and $08) <> 0) then
  begin
    m_p2_reg8 := get_reg8_current(m_op);
    m_p2_reg16 := get_reg16_current(((m_op shr 1) and $03));
  end
  else
  begin
    m_op := RDOP;
    m_p2_reg8 := get_reg8(m_op);
    m_p2_reg16 := get_reg16(m_op);
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_c8[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_D0;
var
  inst: PInstruction;
  reg: PCardinal;
begin
  case (m_op and $07) of
    $00:
      begin
        m_ea2.d := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $01:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 2));
      end;
    $02:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_ea2.b.h2 := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 3));
      end;
    $03:
      begin
        m_op := RDOP;
        case (m_op and $03) of
          $00:
            begin
              m_ea2.d := (get_reg32(m_op))^;
              m_cycles := Integer((Int64(m_cycles) + 1));
            end;
          $01:
            begin
              m_ea2.b.l := RDOP;
              m_ea2.b.h := RDOP;
              m_ea2.d := AddDisplacement((get_reg32(m_op))^, Integer(m_ea2.sw.l));
              m_cycles := Integer((Int64(m_cycles) + 3));
            end;
          $02:
            begin
            end;
          $03:
            begin
              case m_op of
                $03:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt((get_reg8(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $07:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(SmallInt((get_reg16(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $13:
                  begin
                    m_ea2.b.l := RDOP;
                    m_ea2.b.h := RDOP;
                    m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sw.l));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
              end;
            end;
        end;
      end;
    $04:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        (reg)^ := Cardinal(((Int64((reg)^) - (1 shl (m_op and $03))) and $FFFFFFFF));
        m_ea2.d := (reg)^;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $05:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        m_ea2.d := (reg)^;
        (reg)^ := Cardinal(((Int64((reg)^) + (1 shl (m_op and $03))) and $FFFFFFFF));
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_d0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.oD8;
var
  inst: PInstruction;
begin
  if ((m_op and $08) <> 0) then
  begin
    m_p2_reg16 := get_reg16_current(m_op);
    m_p2_reg32 := get_reg32_current(m_op);
  end
  else
  begin
    m_op := RDOP;
    m_p2_reg16 := get_reg16(m_op);
    m_p2_reg32 := get_reg32(m_op);
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_d8[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_E0;
var
  inst: PInstruction;
  reg: PCardinal;
begin
  case (m_op and $07) of
    $00:
      begin
        m_ea2.d := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $01:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 2));
      end;
    $02:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_ea2.b.h2 := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 3));
      end;
    $03:
      begin
        m_op := RDOP;
        case (m_op and $03) of
          $00:
            begin
              m_ea2.d := (get_reg32(m_op))^;
              m_cycles := Integer((Int64(m_cycles) + 1));
            end;
          $01:
            begin
              m_ea2.b.l := RDOP;
              m_ea2.b.h := RDOP;
              m_ea2.d := AddDisplacement((get_reg32(m_op))^, Integer(m_ea2.sw.l));
              m_cycles := Integer((Int64(m_cycles) + 3));
            end;
          $02:
            begin
            end;
          $03:
            begin
              case m_op of
                $03:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt((get_reg8(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $07:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(SmallInt((get_reg16(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $13:
                  begin
                    m_ea2.b.l := RDOP;
                    m_ea2.b.h := RDOP;
                    m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sw.l));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
              end;
            end;
        end;
      end;
    $04:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        (reg)^ := Cardinal(((Int64((reg)^) - (1 shl (m_op and $03))) and $FFFFFFFF));
        m_ea2.d := (reg)^;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $05:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        m_ea2.d := (reg)^;
        (reg)^ := Cardinal(((Int64((reg)^) + (1 shl (m_op and $03))) and $FFFFFFFF));
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_e0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_E8;
var
  inst: PInstruction;
begin
  if ((m_op and $08) <> 0) then
  begin
    m_p2_reg32 := get_reg32_current(m_op);
  end
  else
  begin
    m_op := RDOP;
    m_p2_reg32 := get_reg32(m_op);
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_e8[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

procedure TTLCS900H.op_F0;
var
  inst: PInstruction;
  reg: PCardinal;
begin
  case (m_op and $07) of
    $00:
      begin
        m_ea2.d := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $01:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 2));
      end;
    $02:
      begin
        m_ea2.d := RDOP;
        m_ea2.b.h := RDOP;
        m_ea2.b.h2 := RDOP;
        m_cycles := Integer((Int64(m_cycles) + 3));
      end;
    $03:
      begin
        m_op := RDOP;
        case (m_op and $03) of
          $00:
            begin
              m_ea2.d := (get_reg32(m_op))^;
              m_cycles := Integer((Int64(m_cycles) + 1));
            end;
          $01:
            begin
              m_ea2.b.l := RDOP;
              m_ea2.b.h := RDOP;
              m_ea2.d := AddDisplacement((get_reg32(m_op))^, Integer(m_ea2.sw.l));
              m_cycles := Integer((Int64(m_cycles) + 3));
            end;
          $02:
            begin
            end;
          $03:
            begin
              case m_op of
                $03:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(ShortInt((get_reg8(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $07:
                  begin
                    m_op := RDOP;
                    m_ea2.d := (get_reg32(m_op))^;
                    m_op := RDOP;
                    m_ea2.d := AddDisplacement(m_ea2.d, Integer(SmallInt((get_reg16(m_op))^)));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
                $13:
                  begin
                    m_ea2.b.l := RDOP;
                    m_ea2.b.h := RDOP;
                    m_ea2.d := AddDisplacement(m_pc.d, Integer(m_ea2.sw.l));
                    m_cycles := Integer((Int64(m_cycles) + 3));
                  end;
              end;
            end;
        end;
      end;
    $04:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        (reg)^ := Cardinal(((Int64((reg)^) - (1 shl (m_op and $03))) and $FFFFFFFF));
        m_ea2.d := (reg)^;
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
    $05:
      begin
        m_op := RDOP;
        reg := get_reg32(m_op);
        m_ea2.d := (reg)^;
        (reg)^ := Cardinal(((Int64((reg)^) + (1 shl (m_op and $03))) and $FFFFFFFF));
        m_cycles := Integer((Int64(m_cycles) + 1));
      end;
  end;
  m_op := RDOP;
  inst := (@m_mnemonic_f0[m_op]);
  prepare_operands(inst);
  ExecuteOpcode(inst^.opfunc);
  m_cycles := Integer((Int64(m_cycles) + (inst)^.cycles));
end;

end.

