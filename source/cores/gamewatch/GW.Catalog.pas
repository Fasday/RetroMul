unit GW.Catalog;

// Nintendo hardware facts from MAME hh_sm510.cpp (BSD-3-Clause, hap).

interface

uses
  GW.CPU;

type
  TGWKeyMatrix = array[0..7, 0..3] of Cardinal;

  TGWModelInfo = record
    Id, Title, ProgramFile, MelodyFile, Screens: string;
    CPU: TGWCPUModel;
    ProgramSize, Layout, RMask, FixedRow, SoundMode: Integer;
    Keys: TGWKeyMatrix;
    BA, B: Cardinal;
  end;

function FindGWModel(const Id: string; out Info: TGWModelInfo): Boolean;

function GWModels: TArray<TGWModelInfo>;

implementation

uses
  System.SysUtils;

const
  Models: array[0..58] of TGWModelInfo = (
    (Id: 'gnw_ball'; Title: 'Ball'; ProgramFile: 'ac-01';
      MelodyFile: ''; Screens: 'gnw_ball.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: 0; SoundMode: 1;
      Keys: (($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_flagman'; Title: 'Flagman'; ProgramFile: 'fl-02';
      MelodyFile: ''; Screens: 'gnw_flagman.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($1, $10, $2, $20), ($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_vermin'; Title: 'Vermin'; ProgramFile: 'mt-03';
      MelodyFile: ''; Screens: 'gnw_vermin.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: 0; SoundMode: 1;
      Keys: (($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_fires'; Title: 'Fire (Silver)'; ProgramFile: 'rc-04';
      MelodyFile: ''; Screens: 'gnw_fires.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: 0; SoundMode: 1;
      Keys: (($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_judge'; Title: 'Judge (purple version)'; ProgramFile: 'ip-15';
      MelodyFile: ''; Screens: 'gnw_judge.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_judgeo'; Title: 'Judge (green version)'; ProgramFile: 'ip-05';
      MelodyFile: ''; Screens: 'gnw_judge.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_manholeg'; Title: 'Manhole (Gold)'; ProgramFile: 'mh-06';
      MelodyFile: ''; Screens: 'gnw_manholeg.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_helmet'; Title: 'Helmet (version CN-17)'; ProgramFile: 'cn-17';
      MelodyFile: ''; Screens: 'gnw_helmet.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_helmeto'; Title: 'Helmet (version CN-07)'; ProgramFile: 'cn-07';
      MelodyFile: ''; Screens: 'gnw_helmet.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_lion'; Title: 'Lion'; ProgramFile: 'ln-08';
      MelodyFile: ''; Screens: 'gnw_lion.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_pchute'; Title: 'Parachute'; ProgramFile: 'pr-21';
      MelodyFile: ''; Screens: 'gnw_pchute.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_octopus'; Title: 'Octopus'; ProgramFile: 'oc-22';
      MelodyFile: ''; Screens: 'gnw_octopus.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_popeye'; Title: 'Popeye (Wide Screen)'; ProgramFile: 'pp-23';
      MelodyFile: ''; Screens: 'gnw_popeye.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_chef'; Title: 'Chef'; ProgramFile: 'fp-24';
      MelodyFile: ''; Screens: 'gnw_chef.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $8, $4), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mmouse'; Title: 'Mickey Mouse (Wide Screen)'; ProgramFile: 'mc-25';
      MelodyFile: ''; Screens: 'gnw_mmouse.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_egg'; Title: 'Egg'; ProgramFile: 'mc-25';
      MelodyFile: ''; Screens: 'gnw_egg.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($20, $10, $2, $1), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_fire'; Title: 'Fire (Wide Screen)'; ProgramFile: 'fr-27';
      MelodyFile: ''; Screens: 'gnw_fire.svg'; CPU: TGWCPUModel.SM5A;
      ProgramSize: $740; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $0), ($0, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $8; B: $4),
    (Id: 'gnw_tbridge'; Title: 'Turtle Bridge'; ProgramFile: 'tl-28';
      MelodyFile: ''; Screens: 'gnw_tbridge.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($8, $0, $0, $4), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_fireatk'; Title: 'Fire Attack'; ProgramFile: 'id-29';
      MelodyFile: ''; Screens: 'gnw_fireatk.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($20, $10, $1, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_stennis'; Title: 'Snoopy Tennis'; ProgramFile: 'sp-30';
      MelodyFile: ''; Screens: 'gnw_stennis.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($2, $1, $0, $10), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_opanic'; Title: 'Oil Panic'; ProgramFile: 'op-51';
      MelodyFile: ''; Screens: 'gnw_opanic_top.svg;gnw_opanic_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($8, $0, $0, $4), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkong'; Title: 'Donkey Kong'; ProgramFile: 'dk-52';
      MelodyFile: ''; Screens: 'gnw_dkong_top.svg;gnw_dkong_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $10), ($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mickdon'; Title: 'Mickey & Donald'; ProgramFile: 'dm-53_565';
      MelodyFile: ''; Screens: 'gnw_mickdon_top.svg;gnw_mickdon_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 2;
      Keys: (($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_ghouse'; Title: 'Green House'; ProgramFile: 'gh-54';
      MelodyFile: ''; Screens: 'gnw_ghouse_top.svg;gnw_ghouse_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $10), ($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkong2'; Title: 'Donkey Kong II'; ProgramFile: 'jr-55_560';
      MelodyFile: ''; Screens: 'gnw_dkong2_top.svg;gnw_dkong2_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $10), ($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mario'; Title: 'Mario Bros.'; ProgramFile: 'mw-56';
      MelodyFile: ''; Screens: 'gnw_mario_left.svg;gnw_mario_right.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 2; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($20, $10, $1, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_rshower'; Title: 'Rain Shower'; ProgramFile: 'lp-57';
      MelodyFile: ''; Screens: 'gnw_rshower_left.svg;gnw_rshower_right.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 2; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $40, $10, $0), ($0, $200, $80, $400), ($8, $1, $4, $2), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_lboat'; Title: 'Life Boat'; ProgramFile: 'tc-58';
      MelodyFile: ''; Screens: 'gnw_lboat_left.svg;gnw_lboat_right.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 2; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $8, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_pinball'; Title: 'Pinball'; ProgramFile: 'pb-59.program';
      MelodyFile: 'pb-59.melody'; Screens: 'gnw_pinball_top.svg;gnw_pinball_bottom.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_bjack'; Title: 'Black Jack'; ProgramFile: 'bj-60.program';
      MelodyFile: 'bj-60.melody'; Screens: 'gnw_bjack_top.svg;gnw_bjack_bottom.svg'; CPU: TGWCPUModel.SM512;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($1, $2, $20, $10), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_squish'; Title: 'Squish'; ProgramFile: 'mg-61';
      MelodyFile: ''; Screens: 'gnw_squish_top.svg;gnw_squish_bottom.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 1; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($2, $8, $1, $4), ($40, $80, $200, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_bsweep'; Title: 'Bomb Sweeper'; ProgramFile: 'bd-62.program';
      MelodyFile: 'bd-62.melody'; Screens: 'gnw_bsweep_top.svg;gnw_bsweep_bottom.svg'; CPU: TGWCPUModel.SM512;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $1, $8, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_sbuster'; Title: 'Safe Buster'; ProgramFile: 'jb-63.program';
      MelodyFile: 'jb-63.melody'; Screens: 'gnw_sbuster_top.svg;gnw_sbuster_bottom.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $8, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_gcliff'; Title: 'Gold Cliff'; ProgramFile: 'mv-64.program';
      MelodyFile: 'mv-64.melody'; Screens: 'gnw_gcliff_top.svg;gnw_gcliff_bottom.svg'; CPU: TGWCPUModel.SM512;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $1, $8, $2), ($10, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_zelda'; Title: 'Zelda'; ProgramFile: 'zl-65.program';
      MelodyFile: 'zl-65.melody'; Screens: 'gnw_zelda_top.svg;gnw_zelda_bottom.svg'; CPU: TGWCPUModel.SM512;
      ProgramSize: $1000; Layout: 1; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $1, $8, $2), ($10, $0, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkjr'; Title: 'Donkey Kong Jr. (New Wide Screen)'; ProgramFile: 'dj-101';
      MelodyFile: ''; Screens: 'gnw_dkjr.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $10), ($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mariocm'; Title: 'Mario''s Cement Factory (New Wide Screen)'; ProgramFile: 'ml-102_577';
      MelodyFile: ''; Screens: 'gnw_mariocm.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_manhole'; Title: 'Manhole (New Wide Screen)'; ProgramFile: 'nh-103';
      MelodyFile: ''; Screens: 'gnw_manhole.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($20, $10, $1, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_tfish'; Title: 'Tropical Fish'; ProgramFile: 'tf-104';
      MelodyFile: ''; Screens: 'gnw_tfish.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $8, $0, $0), ($40, $80, $200, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_smb'; Title: 'Super Mario Bros. (Crystal Screen)'; ProgramFile: 'ym-801.program';
      MelodyFile: 'ym-801.melody'; Screens: 'gnw_smb.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_smbn'; Title: 'Super Mario Bros. (New Wide Screen)'; ProgramFile: 'ym-105.program';
      MelodyFile: 'ym-105.melody'; Screens: 'gnw_smbn.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_climber'; Title: 'Climber (Crystal Screen)'; ProgramFile: 'dr-802.program';
      MelodyFile: 'dr-802.melody'; Screens: 'gnw_climber.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_climbern'; Title: 'Climber (New Wide Screen)'; ProgramFile: 'dr-106.program';
      MelodyFile: 'dr-106.melody'; Screens: 'gnw_climbern.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_bfight'; Title: 'Balloon Fight (Crystal Screen)'; ProgramFile: 'bf-803.program';
      MelodyFile: 'bf-803.melody'; Screens: 'gnw_bfight.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_bfightn'; Title: 'Balloon Fight (New Wide Screen)'; ProgramFile: 'bf-107.program';
      MelodyFile: 'bf-107.melody'; Screens: 'gnw_bfightn.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($40, $80, $400, $0), ($1, $8, $2, $4), ($10, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mariotj'; Title: 'Mario The Juggler'; ProgramFile: 'mb-108.program';
      MelodyFile: 'mb-108.melody'; Screens: 'gnw_mariotj.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($8, $0, $0, $4), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mariocmt'; Title: 'Mario''s Cement Factory (Table Top, version CM-72)'; ProgramFile: 'cm-72.program';
      MelodyFile: 'cm-72.melody'; Screens: 'gnw_mariocmt.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mariocmta'; Title: 'Mario''s Cement Factory (Table Top, version CM-72A)'; ProgramFile: 'cm-72a.program';
      MelodyFile: 'cm-72a.melody'; Screens: 'gnw_mariocmt.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_snoopyp'; Title: 'Snoopy (Panorama Screen)'; ProgramFile: 'sm-91.program';
      MelodyFile: 'sm-91.melody'; Screens: 'gnw_snoopyp.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_popeyep'; Title: 'Popeye (Panorama Screen)'; ProgramFile: 'pg-92.program';
      MelodyFile: 'pg-92.melody'; Screens: 'gnw_popeyep.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkjrp'; Title: 'Donkey Kong Jr. (Panorama Screen)'; ProgramFile: 'cj-93.program';
      MelodyFile: 'cj-93.melody'; Screens: 'gnw_dkjrp.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $0, $10), ($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mbaway'; Title: 'Mario''s Bombs Away'; ProgramFile: 'tb-94.program';
      MelodyFile: 'tb-94.melody'; Screens: 'gnw_mbaway.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($10, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_mmousep'; Title: 'Mickey Mouse (Panorama Screen)'; ProgramFile: 'dc-95.program';
      MelodyFile: 'dc-95.melody'; Screens: 'gnw_mmousep.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkcirc'; Title: 'Donkey Kong Circus'; ProgramFile: 'mk-96.program';
      MelodyFile: 'mk-96.melody'; Screens: 'gnw_dkcirc.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $8, $4, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_ssparky'; Title: 'Spitball Sparky'; ProgramFile: 'bu-201';
      MelodyFile: ''; Screens: 'gnw_ssparky.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($4, $8, $10, $0), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_cgrab'; Title: 'Crab Grab'; ProgramFile: 'ud-202';
      MelodyFile: ''; Screens: 'gnw_cgrab.svg'; CPU: TGWCPUModel.SM510;
      ProgramSize: $1000; Layout: 0; RMask: 2; FixedRow: -1; SoundMode: 1;
      Keys: (($8, $1, $4, $2), ($40, $200, $80, $400), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_boxing'; Title: 'Micro Vs. System: Boxing'; ProgramFile: 'bx-301_744.program';
      MelodyFile: 'bx-301_744.melody'; Screens: 'gnw_boxing.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $100000, $0), ($10, $0, $0, $0), ($0, $0, $20000, $10000), ($2, $1, $0, $0), ($0, $0, $80000, $40000), ($8, $4, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkong3'; Title: 'Micro Vs. System: Donkey Kong 3'; ProgramFile: 'ak-302.program';
      MelodyFile: 'ak-302.melody'; Screens: 'gnw_dkong3.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $100000, $0), ($10, $0, $0, $0), ($0, $0, $20000, $10000), ($2, $1, $0, $0), ($0, $0, $80000, $40000), ($8, $4, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0)); BA: $0; B: $0),
    (Id: 'gnw_dkhockey'; Title: 'Micro Vs. System: Donkey Kong Hockey'; ProgramFile: 'hk-303.program';
      MelodyFile: 'hk-303.melody'; Screens: 'gnw_dkhockey.svg'; CPU: TGWCPUModel.SM511;
      ProgramSize: $1000; Layout: 0; RMask: -1; FixedRow: -1; SoundMode: 1;
      Keys: (($0, $0, $100000, $0), ($10, $0, $0, $0), ($0, $0, $20000, $10000), ($2, $1, $0, $0), ($0, $0, $80000, $40000), ($8, $4, $0, $0), ($40, $200, $80, $400), ($0, $0, $0, $0)); BA: $0; B: $0));

function FindGWModel(const Id: string; out Info: TGWModelInfo): Boolean;
begin
  for var Model in Models do
    if SameText(Model.Id, Id) then
    begin
      Info := Model;
      Exit(True);
    end;

  Info := Default(TGWModelInfo);
  Result := False;
end;

function GWModels: TArray<TGWModelInfo>;
begin
  SetLength(Result, Length(Models));
  for var i := 0 to High(Models) do
    Result[i] := Models[i];
end;

end.

