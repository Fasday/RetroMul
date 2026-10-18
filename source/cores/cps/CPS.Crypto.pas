unit CPS.Crypto;

interface

uses
  System.SysUtils;

// Program words are in bus (big endian) order; data reads retain the source.
function DecryptCPS2(const ProgramROM: TBytes; Key0, Key1, EncryptedBytes: Cardinal): TBytes;

function CPS3Mask(Address, Key1, Key2: Cardinal): Cardinal;

implementation

type
  TSBox = record
    Table: array[0..63] of Byte;
    Inputs: array[0..5] of Integer;
    Outputs: array[0..1] of Integer;
  end;

  TOptimizedBox = record
    Input: array[0..255] of Byte;
    Output: array[0..63] of Byte;
  end;

  TBoxes = array[0..15] of TOptimizedBox;

  TKey64 = array[0..1] of Cardinal;

  TKey96 = array[0..3] of Cardinal;

// CPS2 S-boxes and key bit wiring
const
  fn1_groupA: array[0..7] of Integer = (10, 4, 6, 7, 2, 13, 15, 14);
  fn1_groupB: array[0..7] of Integer = (0, 1, 3, 5, 8, 9, 11, 12);
  fn2_groupA: array[0..7] of Integer = (6, 0, 2, 13, 1, 4, 14, 7);
  fn2_groupB: array[0..7] of Integer = (3, 5, 9, 10, 8, 15, 12, 11);
  SBoxes1: array[0..15] of TSBox = (
    (Table: (0, 2, 2, 0, 1, 0, 1, 1, 3, 2, 0, 3, 0, 3, 1, 2, 1, 1, 1, 2, 1, 3, 2, 2, 2, 3, 3, 2, 1, 1, 1, 2, 2, 2, 0, 0, 3, 1, 3, 1, 1, 1, 3, 0, 0, 1, 0, 0, 1, 2, 2, 1, 2, 3, 2, 2, 2, 3, 1, 3, 2, 0, 1, 3); Inputs: (3, 4, 5, 6, -1, -1); Outputs: (3, 6)),
    (Table: (3, 0, 2, 2, 2, 1, 1, 1, 1, 2, 1, 0, 0, 0, 2, 3, 2, 3, 1, 3, 0, 0, 0, 2, 1, 2, 2, 3, 0, 3, 3, 3, 0, 1, 3, 2, 3, 3, 3, 1, 1, 1, 1, 2, 0, 1, 2, 1, 3, 2, 3, 1, 1, 3, 2, 2, 2, 3, 1, 3, 2, 3, 0, 0); Inputs: (0, 1, 2, 4, 7, -1); Outputs: (2, 7)),
    (Table: (3, 0, 3, 1, 1, 0, 2, 2, 3, 1, 2, 0, 3, 3, 2, 3, 0, 1, 0, 1, 2, 3, 0, 2, 0, 2, 0, 1, 0, 0, 1, 0, 2, 3, 1, 2, 1, 0, 2, 0, 2, 1, 0, 1, 0, 2, 1, 0, 3, 1, 2, 3, 1, 3, 1, 1, 1, 2, 0, 2, 2, 0, 0, 0); Inputs: (0, 1, 2, 3, 6, 7); Outputs: (0, 1)),
    (Table: (3, 2, 0, 3, 0, 2, 2, 1, 1, 2, 3, 2, 1, 3, 2, 1, 2, 2, 1, 3, 3, 2, 1, 0, 1, 0, 1, 3, 0, 0, 0, 2, 2, 1, 0, 1, 0, 1, 0, 1, 3, 1, 1, 2, 2, 3, 2, 0, 3, 3, 2, 0, 2, 1, 3, 3, 0, 0, 3, 0, 1, 1, 3, 3); Inputs: (0, 1, 3, 5, 6, 7); Outputs: (4, 5)),
    (Table: (3, 3, 2, 0, 3, 0, 3, 1, 0, 3, 0, 1, 0, 2, 1, 3, 1, 3, 0, 3, 3, 1, 3, 3, 3, 2, 3, 2, 2, 3, 1, 2, 0, 2, 2, 1, 0, 1, 2, 0, 3, 3, 0, 1, 3, 2, 1, 2, 3, 0, 1, 3, 0, 1, 2, 2, 1, 2, 1, 2, 0, 1, 3, 0); Inputs: (0, 1, 2, 3, 6, -1); Outputs: (1, 6)),
    (Table: (1, 2, 3, 2, 1, 3, 0, 1, 1, 0, 2, 0, 0, 2, 3, 2, 3, 3, 0, 1, 2, 2, 1, 0, 1, 0, 1, 2, 3, 2, 1, 3, 2, 2, 2, 0, 1, 0, 2, 3, 2, 1, 2, 1, 2, 1, 0, 3, 0, 1, 2, 3, 1, 2, 1, 3, 2, 0, 3, 2, 3, 0, 2, 0); Inputs: (2, 4, 5, 6, 7, -1); Outputs: (5, 7)),
    (Table: (0, 1, 0, 2, 1, 1, 0, 1, 0, 2, 2, 2, 1, 3, 0, 0, 1, 1, 3, 1, 2, 2, 2, 3, 1, 0, 3, 3, 3, 2, 2, 2, 1, 1, 3, 0, 3, 1, 3, 0, 1, 3, 3, 2, 1, 1, 0, 0, 1, 2, 2, 2, 1, 1, 1, 2, 2, 0, 0, 3, 2, 3, 1, 3); Inputs: (1, 2, 3, 4, 5, 7); Outputs: (0, 3)),
    (Table: (2, 1, 0, 3, 3, 3, 2, 0, 1, 2, 1, 1, 1, 0, 3, 1, 1, 3, 3, 0, 1, 2, 1, 0, 0, 0, 3, 0, 3, 0, 3, 0, 1, 3, 3, 3, 0, 3, 2, 0, 2, 1, 2, 2, 2, 1, 1, 3, 0, 1, 0, 1, 0, 1, 1, 1, 1, 3, 1, 0, 1, 2, 3, 3); Inputs: (0, 1, 3, 4, 6, 7); Outputs: (2, 4)),
    (Table: (0, 0, 0, 3, 3, 1, 1, 0, 2, 0, 2, 0, 0, 0, 3, 2, 0, 1, 2, 3, 2, 2, 1, 0, 3, 0, 0, 0, 0, 0, 2, 3, 3, 0, 0, 1, 1, 2, 3, 3, 0, 1, 3, 2, 0, 1, 3, 3, 2, 0, 0, 1, 0, 2, 0, 0, 0, 3, 1, 3, 3, 3, 3, 3); Inputs: (0, 1, 5, 6, 7, -1); Outputs: (0, 5)),
    (Table: (2, 3, 2, 3, 0, 2, 3, 0, 2, 2, 3, 0, 3, 2, 0, 2, 1, 0, 2, 3, 1, 1, 1, 0, 0, 1, 0, 2, 1, 2, 2, 1, 3, 0, 2, 1, 2, 3, 3, 0, 3, 2, 3, 1, 0, 2, 1, 0, 1, 2, 2, 3, 0, 2, 1, 3, 1, 3, 0, 2, 1, 1, 1, 3); Inputs: (2, 3, 4, 6, 7, -1); Outputs: (6, 7)),
    (Table: (3, 0, 2, 1, 1, 3, 1, 2, 2, 1, 2, 2, 2, 0, 0, 1, 2, 3, 1, 0, 2, 0, 0, 2, 3, 1, 2, 0, 0, 0, 3, 0, 2, 1, 1, 2, 0, 0, 1, 2, 3, 1, 1, 2, 0, 1, 3, 0, 3, 1, 1, 0, 0, 2, 3, 0, 0, 0, 0, 3, 2, 0, 0, 0); Inputs: (0, 2, 3, 4, 5, 6); Outputs: (1, 4)),
    (Table: (0, 1, 0, 0, 2, 1, 3, 2, 3, 3, 2, 1, 0, 1, 1, 1, 1, 1, 0, 3, 3, 1, 1, 0, 0, 2, 2, 1, 0, 3, 3, 2, 1, 3, 3, 0, 3, 0, 2, 1, 1, 2, 3, 2, 2, 2, 1, 0, 0, 3, 3, 3, 2, 2, 3, 1, 0, 2, 3, 0, 3, 1, 1, 0); Inputs: (0, 1, 2, 3, 5, 7); Outputs: (2, 3)),
    (Table: (1, 1, 1, 1, 1, 0, 1, 3, 3, 2, 3, 0, 1, 2, 0, 2, 3, 3, 0, 1, 2, 1, 2, 3, 0, 3, 2, 3, 2, 0, 1, 2, 0, 1, 0, 3, 2, 1, 3, 2, 3, 1, 2, 3, 2, 0, 1, 2, 2, 0, 0, 0, 2, 1, 3, 0, 3, 1, 3, 0, 1, 3, 3, 0); Inputs: (1, 2, 3, 4, 5, 7); Outputs: (0, 4)),
    (Table: (3, 0, 0, 0, 0, 1, 0, 2, 3, 3, 1, 3, 0, 3, 1, 2, 2, 2, 3, 1, 0, 0, 2, 0, 1, 0, 2, 2, 3, 3, 0, 0, 1, 1, 3, 0, 2, 3, 0, 3, 0, 3, 0, 2, 0, 2, 0, 1, 0, 3, 0, 1, 3, 1, 1, 0, 0, 1, 3, 3, 2, 2, 1, 0); Inputs: (0, 1, 2, 3, 5, 6); Outputs: (1, 3)),
    (Table: (0, 1, 1, 2, 0, 1, 3, 1, 2, 0, 3, 2, 0, 0, 3, 0, 3, 0, 1, 2, 2, 3, 3, 2, 3, 2, 0, 1, 0, 0, 1, 0, 3, 0, 2, 3, 0, 2, 2, 2, 1, 1, 0, 2, 2, 0, 0, 1, 2, 1, 1, 1, 2, 3, 0, 3, 1, 2, 3, 3, 1, 1, 3, 0); Inputs: (0, 2, 4, 5, 6, 7); Outputs: (2, 6)),
    (Table: (0, 1, 2, 2, 0, 1, 0, 3, 2, 2, 1, 1, 3, 2, 0, 2, 0, 1, 3, 3, 0, 2, 2, 3, 3, 2, 0, 0, 2, 1, 3, 3, 1, 1, 1, 3, 1, 2, 1, 1, 0, 3, 3, 2, 3, 2, 3, 0, 3, 1, 0, 0, 3, 0, 0, 0, 2, 2, 2, 1, 2, 3, 0, 0); Inputs: (0, 1, 3, 4, 6, 7); Outputs: (5, 7)));
  SBoxes2: array[0..15] of TSBox = (
    (Table: (2, 0, 2, 0, 3, 0, 0, 3, 1, 1, 0, 1, 3, 2, 0, 1, 2, 0, 1, 2, 0, 2, 0, 2, 2, 2, 3, 0, 2, 1, 3, 0, 0, 1, 0, 1, 2, 2, 3, 3, 0, 3, 0, 2, 3, 0, 1, 2, 1, 1, 0, 2, 0, 3, 1, 1, 2, 2, 1, 3, 1, 1, 3, 1); Inputs: (0, 3, 4, 5, 7, -1); Outputs: (6, 7)),
    (Table: (1, 1, 0, 3, 0, 2, 0, 1, 3, 0, 2, 0, 1, 1, 0, 0, 1, 3, 2, 2, 0, 2, 2, 2, 2, 0, 1, 3, 3, 3, 1, 1, 1, 3, 1, 3, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1, 1, 2, 3, 1, 1, 2, 0, 3, 3, 3, 2, 2, 3, 1, 1, 1, 3, 0); Inputs: (1, 2, 3, 4, 6, -1); Outputs: (3, 5)),
    (Table: (1, 0, 2, 2, 3, 3, 3, 3, 1, 2, 2, 1, 0, 1, 2, 1, 1, 2, 3, 1, 2, 0, 0, 1, 2, 3, 1, 2, 0, 0, 0, 2, 2, 0, 1, 1, 0, 0, 2, 0, 0, 0, 2, 3, 2, 3, 0, 1, 3, 0, 0, 0, 2, 3, 2, 0, 1, 3, 2, 1, 3, 1, 1, 3); Inputs: (1, 2, 4, 5, 6, 7); Outputs: (1, 4)),
    (Table: (1, 3, 3, 0, 3, 2, 3, 1, 3, 2, 1, 1, 3, 3, 2, 1, 2, 3, 0, 3, 1, 0, 0, 2, 3, 0, 0, 0, 3, 3, 0, 1, 2, 3, 0, 0, 0, 1, 2, 1, 3, 0, 0, 1, 0, 2, 2, 2, 3, 3, 1, 2, 1, 3, 0, 0, 0, 3, 0, 1, 3, 2, 2, 0); Inputs: (0, 2, 3, 5, 6, 7); Outputs: (0, 2)),
    (Table: (3, 1, 3, 0, 3, 0, 3, 1, 3, 0, 0, 1, 1, 3, 0, 3, 1, 1, 0, 1, 2, 3, 2, 3, 3, 1, 2, 2, 2, 0, 2, 3, 2, 2, 2, 1, 1, 3, 3, 0, 3, 1, 2, 1, 1, 1, 0, 2, 0, 3, 3, 0, 0, 2, 0, 0, 1, 1, 2, 1, 2, 1, 1, 0); Inputs: (0, 2, 4, 6, -1, -1); Outputs: (4, 6)),
    (Table: (0, 3, 0, 3, 3, 2, 1, 2, 3, 1, 1, 1, 2, 0, 2, 3, 0, 3, 1, 2, 2, 1, 3, 3, 3, 2, 1, 2, 2, 0, 1, 0, 2, 3, 0, 1, 2, 0, 1, 1, 2, 0, 2, 1, 2, 0, 2, 3, 3, 1, 0, 2, 3, 3, 0, 3, 1, 1, 3, 0, 0, 1, 2, 0); Inputs: (1, 3, 4, 5, 6, 7); Outputs: (0, 3)),
    (Table: (0, 0, 2, 1, 3, 2, 1, 0, 1, 2, 2, 2, 1, 1, 0, 3, 1, 2, 2, 3, 2, 1, 1, 0, 3, 0, 0, 1, 1, 2, 3, 1, 3, 3, 2, 2, 1, 0, 1, 1, 1, 2, 0, 1, 2, 3, 0, 3, 3, 0, 3, 2, 2, 0, 2, 2, 1, 2, 3, 2, 1, 0, 2, 1); Inputs: (0, 1, 3, 4, 5, 7); Outputs: (1, 7)),
    (Table: (0, 2, 1, 2, 0, 2, 2, 0, 1, 3, 2, 0, 3, 2, 3, 0, 3, 3, 2, 3, 1, 2, 3, 1, 2, 2, 0, 0, 2, 2, 1, 2, 2, 3, 3, 3, 1, 1, 0, 0, 0, 3, 2, 0, 3, 2, 3, 1, 1, 1, 1, 0, 1, 0, 1, 3, 0, 0, 1, 2, 2, 3, 2, 0); Inputs: (1, 2, 3, 5, 6, 7); Outputs: (2, 5)),
    (Table: (2, 1, 2, 1, 2, 3, 1, 3, 2, 2, 1, 3, 3, 0, 0, 1, 0, 2, 0, 3, 3, 1, 0, 0, 1, 1, 0, 2, 3, 2, 1, 2, 1, 1, 2, 1, 1, 3, 2, 2, 0, 2, 2, 3, 3, 3, 2, 0, 0, 0, 0, 0, 3, 3, 3, 0, 1, 2, 1, 0, 2, 3, 3, 1); Inputs: (2, 3, 4, 6, -1, -1); Outputs: (3, 5)),
    (Table: (3, 2, 3, 3, 1, 0, 3, 0, 2, 0, 1, 1, 1, 0, 3, 0, 3, 1, 3, 1, 0, 1, 2, 3, 2, 2, 3, 2, 0, 1, 1, 2, 3, 0, 0, 2, 1, 0, 0, 2, 2, 0, 1, 0, 0, 2, 0, 0, 1, 3, 1, 3, 2, 0, 3, 3, 1, 0, 2, 2, 2, 3, 0, 0); Inputs: (0, 1, 3, 5, 7, -1); Outputs: (0, 2)),
    (Table: (2, 2, 1, 0, 2, 3, 3, 0, 0, 0, 1, 3, 1, 2, 3, 2, 2, 3, 1, 3, 0, 3, 0, 3, 3, 2, 2, 1, 0, 0, 0, 2, 1, 2, 2, 2, 0, 0, 1, 2, 0, 1, 3, 0, 2, 3, 2, 1, 3, 2, 2, 2, 3, 1, 3, 0, 2, 0, 2, 1, 0, 3, 3, 1); Inputs: (0, 1, 2, 3, 5, 7); Outputs: (1, 6)),
    (Table: (1, 2, 3, 2, 0, 2, 1, 3, 3, 1, 0, 1, 1, 2, 2, 0, 0, 1, 1, 1, 2, 1, 1, 2, 0, 1, 3, 3, 1, 1, 1, 2, 3, 3, 1, 0, 2, 1, 1, 1, 2, 1, 0, 0, 2, 2, 3, 2, 3, 2, 2, 0, 2, 2, 3, 3, 0, 2, 3, 0, 2, 2, 1, 1); Inputs: (0, 2, 4, 5, 6, 7); Outputs: (4, 7)),
    (Table: (2, 0, 1, 1, 2, 1, 3, 3, 1, 1, 1, 2, 0, 1, 0, 2, 0, 1, 2, 0, 2, 3, 0, 2, 3, 3, 2, 2, 3, 2, 0, 1, 3, 0, 2, 0, 2, 3, 1, 3, 2, 0, 0, 1, 1, 2, 3, 1, 1, 1, 0, 1, 2, 0, 3, 3, 1, 1, 1, 3, 3, 1, 1, 0); Inputs: (0, 1, 3, 6, 7, -1); Outputs: (0, 3)),
    (Table: (1, 2, 2, 1, 0, 3, 3, 1, 0, 2, 2, 2, 1, 0, 1, 0, 1, 1, 0, 1, 0, 2, 1, 0, 2, 1, 0, 2, 3, 2, 3, 3, 2, 2, 1, 2, 2, 3, 1, 3, 3, 3, 0, 1, 0, 1, 3, 0, 0, 0, 1, 2, 0, 3, 3, 2, 3, 2, 1, 3, 2, 1, 0, 2); Inputs: (0, 1, 2, 4, 5, 6); Outputs: (4, 7)),
    (Table: (2, 3, 2, 1, 3, 2, 3, 0, 0, 2, 1, 1, 0, 0, 3, 2, 3, 1, 0, 1, 2, 2, 2, 1, 3, 2, 2, 1, 0, 2, 1, 2, 0, 3, 1, 0, 0, 3, 1, 1, 3, 3, 2, 0, 1, 0, 1, 3, 0, 0, 1, 2, 1, 2, 3, 2, 1, 0, 0, 3, 2, 1, 1, 3); Inputs: (0, 2, 3, 4, 5, 7); Outputs: (1, 2)),
    (Table: (2, 0, 0, 3, 2, 2, 2, 1, 3, 3, 1, 1, 2, 0, 0, 3, 1, 0, 3, 2, 1, 0, 2, 0, 3, 2, 2, 3, 2, 0, 3, 0, 1, 3, 0, 2, 2, 1, 3, 3, 0, 1, 0, 3, 1, 1, 3, 2, 0, 3, 0, 2, 3, 2, 1, 3, 2, 3, 0, 0, 1, 3, 2, 1); Inputs: (2, 3, 4, 5, 6, 7); Outputs: (5, 6)));
  KeyBits1: array[0..95] of Integer = (33, 58, 49, 36, 0, 31, 22, 30, 3, 16, 5, 53, 10, 41, 23, 19, 27, 39, 43, 6, 34, 12, 61, 21, 48, 13, 32, 35, 6, 42, 43, 14, 21, 41, 52, 25, 18, 47, 46, 37, 57, 53, 20, 8, 55, 54, 59, 60, 27, 33, 35, 18, 8, 15, 63, 1, 50, 44, 16, 46, 5, 4, 45, 51, 38, 25, 13, 11, 62, 29, 48, 2, 59, 61, 62, 56, 51, 57, 54, 9, 24, 63, 22, 7, 26, 42, 45, 40, 23, 14, 2, 31, 52, 28, 44, 17);
  KeyBits2: array[0..95] of Integer = (34, 9, 32, 24, 44, 54, 38, 61, 47, 13, 28, 7, 29, 58, 18, 1, 20, 60, 15, 6, 11, 43, 39, 19, 63, 23, 16, 62, 54, 40, 31, 3, 56, 61, 17, 25, 47, 38, 55, 57, 5, 4, 15, 42, 22, 7, 2, 19, 46, 37, 29, 39, 12, 30, 49, 57, 31, 41, 26, 27, 24, 36, 11, 63, 33, 16, 56, 62, 48, 60, 59, 32, 12, 30, 53, 48, 10, 0, 50, 35, 3, 59, 14, 49, 51, 45, 44, 2, 21, 33, 55, 52, 23, 28, 8, 26);
  SubBits: array[0..63] of Integer = (5, 10, 14, 9, 4, 0, 15, 6, 1, 8, 3, 2, 12, 7, 13, 11, 5, 12, 7, 2, 13, 11, 9, 14, 4, 1, 6, 10, 8, 0, 15, 3, 4, 10, 2, 0, 6, 9, 12, 1, 11, 7, 15, 8, 13, 5, 14, 3, 14, 11, 12, 7, 4, 5, 2, 10, 1, 15, 0, 9, 8, 6, 13, 3);

procedure Optimize(const Source: array of TSBox; out Dest: TBoxes);
begin
  for var B := 0 to 15 do
  begin
    for var V := 0 to 255 do
    begin
      var Value := 0;
      for var i := 0 to 5 do
        if Source[B].Inputs[i] >= 0 then
          Value := Value or (((V shr Source[B].Inputs[i]) and 1) shl i);
      Dest[B].Input[V] := Value;
    end;
    for var V := 0 to 63 do
      Dest[B].Output[V] :=
        ((Source[B].Table[V] and 1) shl Source[B].Outputs[0]) or
        (((Source[B].Table[V] shr 1) and 1) shl Source[B].Outputs[1]);
  end;
end;

procedure Expand(const Source: TKey64; const Bits: array of Integer; out Dest: TKey96);
begin
  Dest := Default(TKey96);
  for var i := 0 to 95 do
    Dest[i div 24] := Dest[i div 24] or (((Source[Bits[i] div 32] shr (Bits[i] mod 32)) and 1) shl (i mod 24));
end;

procedure Extra(var Key: Cardinal; SourceBit, DestBit: Integer); inline;
begin
  Key := Key xor (((Key shr SourceBit) and 1) shl DestBit);
end;

function F(Value: Byte; const Boxes: TBoxes; Round: Integer; Key: Cardinal): Byte; inline;
begin
  Result := 0;
  for var B := 0 to 3 do
    Result := Result or Boxes[Round * 4 + B].Output[Boxes[Round * 4 + B].Input[Value] xor ((Key shr (B * 6)) and 63)];
end;

function Feistel(Value: Word; const A, B: array of Integer; const Boxes: TBoxes; const Key: TKey96): Word;
begin
  var L: Byte := 0;
  var R: Byte := 0;
  for var i := 0 to 7 do
  begin
    L := L or (((Value shr B[i]) and 1) shl i);
    R := R or (((Value shr A[i]) and 1) shl i);
  end;
  L := L xor F(R, Boxes, 0, Key[0]);
  R := R xor F(L, Boxes, 1, Key[1]);
  L := L xor F(R, Boxes, 2, Key[2]);
  R := R xor F(L, Boxes, 3, Key[3]);
  Result := 0;
  for var i := 0 to 7 do
    Result := Result or (((L shr i) and 1) shl A[i]) or (((R shr i) and 1) shl B[i]);
end;

function DecryptCPS2(const ProgramROM: TBytes; Key0, Key1, EncryptedBytes: Cardinal): TBytes;
begin
  if Odd(Length(ProgramROM)) or (EncryptedBytes > Cardinal(Length(ProgramROM))) then
    raise EArgumentException.Create('Invalid CPS2 encrypted program range');

  Result := Copy(ProgramROM);
  var Master: TKey64;
  Master[0] := Key0;
  Master[1] := Key1;
  var Key: TKey96;
  Expand(Master, KeyBits1, Key);
  Extra(Key[0], 1, 4);
  Extra(Key[0], 2, 5);
  Extra(Key[0], 8, 11);
  Extra(Key[1], 0, 5);
  Extra(Key[1], 8, 11);
  Extra(Key[2], 1, 5);
  Extra(Key[2], 8, 11);
  var Boxes1, Boxes2: TBoxes;
  Optimize(SBoxes1, Boxes1);
  Optimize(SBoxes2, Boxes2);
  for var Address := 0 to $FFFF do
  begin
    var Seed := Feistel(Address, fn1_groupA, fn1_groupB, Boxes1, Key);
    var SubKey: TKey64 := Default(TKey64);
    for var i := 0 to 63 do
      SubKey[i div 32] := SubKey[i div 32] or (((Seed shr SubBits[i]) and 1) shl (i mod 32));
    SubKey[0] := SubKey[0] xor Master[0];
    SubKey[1] := SubKey[1] xor Master[1];
    var K2: TKey96;
    Expand(SubKey, KeyBits2, K2);
    Extra(K2[0], 0, 5);
    Extra(K2[0], 6, 11);
    Extra(K2[1], 0, 5);
    Extra(K2[1], 1, 4);
    Extra(K2[2], 2, 5);
    Extra(K2[2], 3, 4);
    Extra(K2[2], 7, 11);
    Extra(K2[3], 1, 5);
    var Offset := Address * 2;
    while Offset < Integer(EncryptedBytes) do
    begin
      var WordValue := (Word(ProgramROM[Offset]) shl 8) or ProgramROM[Offset + 1];
      WordValue := Feistel(WordValue, fn2_groupA, fn2_groupB, Boxes2, K2);
      Result[Offset] := Byte(WordValue shr 8);
      Result[Offset + 1] := Byte(WordValue and $FF);
      Inc(Offset, $20000);
    end;
  end;
end;

function Rotate16(Value: Word; Count: Integer): Word; inline;
begin
  Result := Word(((Cardinal(Value) shl Count) or (Value shr (16 - Count))) and $FFFF);
end;

function RotXor(Value, Key: Word): Word;
begin
  Result := Word((Cardinal(Value) + Rotate16(Value, 2)) and $FFFF);
  Result := Rotate16(Result, 4) xor (Result and (Value xor Key));
end;

function CPS3Mask(Address, Key1, Key2: Cardinal): Cardinal;
begin
  Address := Address xor Key1;
  var Value := RotXor(Word((Address and $FFFF) xor $FFFF), Word(Key2 and $FFFF));
  Value := Value xor Word((Address shr 16) xor $FFFF);
  Value := RotXor(Value, Word(Key2 shr 16));
  Value := Value xor Word((Address xor Key2) and $FFFF);
  Result := Cardinal(Value) or (Cardinal(Value) shl 16);
end;

end.

