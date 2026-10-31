# PSP ATRAC call costs

Follow-up to `00a40ae`.

`sceAtracSetData*` and `sceAtracDecodeData` now cost what the hardware recording
`threads/scheduling/callcosts` measured. Each call is modelled as a busy part, the
library's own CPU work during which a worse-priority thread does not run, and
then a wait for the media engine's decode, during which other threads run.
Setting the data counts as decoding the first frame.

| Codec (recorded file) | Call | Busy | Wait | Recorded |
|---|---|---:|---:|---|
| ATRAC3 (mono, 10 KB) | set data | 250 us | 650 us | ~900 us, worse thread 50-90% |
| | first decode | 150 us | 550 us | ~700 us, 50-90% |
| | later decodes | 40 us | 660 us | ~700 us, over 90% |
| ATRAC3+ (stereo, 45 KB) | set data | 800 us | 2700 us | ~3.5 ms, 50-90% |
| | first decode | 150 us | 2850 us | ~3.0 ms, over 90% |
| | later decodes | 100 us | 2400 us | ~2.5 ms, over 90% |

The recordings only provide one channel layout per codec. The costs are
therefore per codec, and channel-count scaling is not assumed. A per-slot
`Decoded` flag distinguishes the first decode after the data is set. Older direct
states without it start from the first-decode cost.

All ATRAC lines of `callcosts`, and the `sceAtracSetDataAndGetID ~4ms, waits`
line of `syscallkinds`, now match their recordings. Neither test passes, because
of the remaining lines:

- memory-stick open/read and module load times. The test itself says these
  depend on the card (an SD card in an adapter was used), so they were not tuned
  to that one card.
- `sceGeDrawSync` over 60 colour+depth clears takes ~56 ms on hardware against
  our ~23 ms. One configuration is not enough to recalibrate the GE fill-rate
  model.
- `sceKernelUnloadModule` ~400 us against our ~500 us.

## Verification

- Regular suite: **547 PASS / 91 FAIL / 638**, unchanged status set; complete
  JIT/pool and interpreter/serial reports byte-identical.
- `--hw` profile: **520 PASS / 118 FAIL / 638**, unchanged status set.
- Old kind-1/kind-2 imports keep their digests. The MHP3rd frame11000 movie
  state passes the full save/restore/continuation matrix (11,266,337 bytes,
  second-generation load 805 ms).

No expected outputs, normalization, settings or images were changed.
