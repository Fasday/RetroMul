# Vulkan HLE renderers for other consoles

`RM.Vulkan.HLE` (`TVulkanHLERenderer`, in `source/gpu/vulkan`) is the common
part of the Vulkan HLE renderers. It holds what the PSP's renderer
(`PSP.GE.VulkanHLE`, described in `HLE.md`) did that does not depend on the
GE. A new console's renderer derives from it and adds only what is its own.
The contract is at the top of `RM.Vulkan.HLE.pas`; this is the short version.
The base holds only what the PSP uses. A console that needs more adds it when
it needs it.

## What the base does

- Device: a `TVulkanCompute` with a graphics queue, owned and freed by the
  renderer. Two slots, each with a command buffer, a vertex buffer and a
  staging buffer; `Submit`, `WaitAll`, `StageUpload`, `CopyToImage`,
  `ImageBarrier`, `HostReadBarrier`. Every image stays in the general layout.
- Targets (`TVulkanHLETarget`): one RGBA8 colour image and one depth/stencil
  image (D32_SFLOAT_S8_UINT, else D24_UNORM_S8_UINT) per (address, format,
  stride), `Scale` times the surface's size. `FindTarget` finds, grows (twice
  as tall, up to `MaxHeight`) and drops (least recently used, past
  `HLEMaxTargets`).
- Coherence with console memory: shadows, holds, watches, `FlushAll`, runs
  (described below).
- Texture cache (`TVulkanHLETexture`): textures decoded to RGBA8, with their
  levels as mip levels; their source bytes are kept and compared once a run.
  Texture scaling (`RM.Vulkan.TexScale`) applies above 1x. Descriptor sets are
  cached per sampler.
- Pipelines cached by a 64-bit key; samplers by a 32-bit key; one render pass
  (`FRenderPass`) and one layout (`FLayout`: one combined image sampler for
  the fragment shader, push constants for both stages).
- Batches: vertices of one size go into the slot's buffer and are drawn with
  one `vkCmdDraw` until `FlushDraw`.
- Frames: `ReadFrame` reads a target into a `TEmulatorFrame`, reusing the
  pixel arrays.
- `TVulkanHLEStats`: draws, primitives, submits, flushes, loads, stores,
  texture uploads and hits, waiting and flush time, and so on.

## Making one

1. Derive from `TVulkanHLERenderer`. Create the device with
   `TryCreateVulkanCompute(..., Graphics = True)` and call
   `inherited Create(Compute, Scale, SizeOf(Vertex), SizeOf(Push), FrameWidth, FrameHeight)`.
   To give the targets' images more usage bits, add them to `FColorUsage` and
   `FDepthUsage` before the first target is made. The PSP adds STORAGE to the
   colour and SAMPLED to the depth.
2. Implement the abstract methods:

   | Method | What it does |
   | --- | --- |
   | `PipelineFor(Key)` | Makes the pipeline for a key (the console's shaders and fixed-function state) with `FRenderPass` and `FLayout`, or with its own. `Pipeline(Key)` caches the result. |
   | `LoadTarget(T)` | Puts the surface from console memory into the target's images, each pixel as a Scale x Scale block. The base takes the shadow afterwards. |
   | `StoreTarget(T)` | Writes the images' newer pixels (the box `X1..Y2`) back into console memory, in the console's format. The base clears `Dirty` and updates the shadow. |
   | `DescribeTexture(Request, ...)` | A new texture's size, levels and scale (`ScaleFor`, or 1). |
   | `TextureMatches(T, Request)` | Whether console memory still holds the texture's source bytes (`SameSource`). |
   | `DecodeTexture(T, Request)` | `KeepSource`, then for each level `LevelTexels`, the texels as RGBA8 and `UploadLevel`. |
   | `WatchTexture(T, Request)` | Watches the texture's bytes in console memory (normally `WatchMemory`). |
   | `MemoryEquals`, `ReadMemory` | Compares and reads console memory in the renderer's address space (wrapping as the console does). |
   | `HoldMemory`, `MemoryHeld`, `ReleaseHolds` | Holds pages: any access to a held page must call the renderer first. |
   | `WatchMemory`, `ReleaseWatches` | Watches pages: a write to a watched page must call the renderer first. |
   | `RecordFrame(T, W, H)` | Records the conversion of a target's colour into `FReadback` as W x H `TAlphaColor` pixels. |

   Optional overrides: `Unbound` (forget the bindings the subclass caches),
   `NewTarget`, `InitTarget` and `DestroyTarget` (a target class of your own,
   with more images or sets), `TargetNewer` (more than colour can be newer;
   the PSP's depth), `NewRun` (forget per-run state), `FreeDevice` (your
   device objects, then `inherited`).
3. Draw. When the state changes: `FlushDraw`; pick the target with
   `FindTarget`, then `EnsureTarget`; pick the texture with `CachedTexture`
   (or `TargetAsTexture` for a target drawn from directly), then
   `TextureSet`; call `BeginDrawing(T)`; call `BeginPass`; bind
   `Pipeline(Key)` and the set and keep `FBoundPipeline` and `FBoundSet` up to
   date. For each primitive: `ReserveVertices`, `HoldNewRows`, `AddVertices`,
   `Drawn`.

## Coherence with console memory

Console memory is the reference whenever the console itself looks at it. A
target is either equal to memory or newer than it:

- Equal (`Loaded`): `Shadow` holds the bytes it was loaded from. Before each
  use, `EnsureTarget` compares them with memory (`MemoryEquals`) and loads the
  target again when they differ.
- Newer (`Dirty`): it has been drawn since. The pages of the rows drawn are
  held (`HoldNewRows`, `HoldMemory`); the rest of the target is watched
  (`BeginDrawing`, `WatchMemory`).
- An access to a held page: the console's memory calls the subclass, which
  calls `FlushAll`. `FlushAll` waits for the GPU and stores every newer target
  (`StoreTarget`). It then releases all holds and watches and starts a new
  run (`NewRun`).
- A write to a watched page does not stop the GPU. The subclass knows where
  the write went: it marks the targets it reaches `Stale` outside the rows
  drawn, starts a new run so that textures are compared again, and watches
  the other targets again. Drawing into a stale target's other rows flushes
  first. A stale target is not shown from its image.
- Textures are compared with their source bytes once a run (`Verified`) and
  watched from then on.
- The base calls `FlushAll` itself only when a target grows, when a target to
  load is still held by another one, and on destruction.

## Who calls Sync

The base never decides when the console needs its memory complete; the
subclass does, from what the console's GPU and CPU do:

- `Sync` (a `FlushAll`): call it when memory must hold everything drawn so
  far. On the PSP that is `TPSPGEEngine.Synchronize`: before a state is saved
  or hashed, and at the end of a `PSPRun`. The CPU waiting for a list needs
  no `Sync`: its reads of held pages call back.
- `Release`: call it when the console's GPU stops for now (on the PSP,
  `TPSPGEEngine.ReleaseBackend`, after each stretch the GE runs). What is recorded
  starts on the GPU if the other slot has finished, without waiting. The
  targets stay held.
- Accesses to held pages need no `Sync`: they call back through the memory's
  hold mechanism (on the PSP, `TPSPMemory.OnVRAMFault` and `OnWatchFault`).
  An engine that touches memory itself without going through those hooks
  must say so first (the PSP's `Access`).

## Limits of the base for other consoles

These are known limits; nothing in the code addresses them yet.

- Memory model: addresses are 32-bit and the subclass maps them to pages. The
  PSP's targets live in a separate 2 MB VRAM with mirrors. On a console with
  shared memory (the Xbox's 64 MB UMA), targets and textures sit in main RAM.
  CPU accesses would then hit held pages much more often, and every hit
  stores all targets. Holds would have to be finer, or flushes per target.
- Linear surfaces only: a row is `Stride * PixelBytes` bytes, and holds, the
  shadow and the stored box all follow rows. Swizzled or tiled surfaces (the
  Xbox's swizzled render targets and textures) do not fit. They would need
  the whole surface held and a different store.
- Depth: the depth/stencil image's format is the base's choice (D32F+S8 or
  D24+S8), and the base does no depth coherence at all. Where a console's
  depth buffer lives, its format in memory (16-bit on the PSP; D24S8 or 24-bit
  float on the Xbox), its loads, stores, holds and watches are the
  subclass's. With D24 the precision is 24 bits.
- One render pass shape: one RGBA8 colour attachment (loaded, stored) and one
  depth/stencil attachment. There are no multiple render targets, no other
  colour formats (565 or float targets are kept as RGBA8) and no MSAA.
- One pipeline layout: a single combined image sampler. A console with
  several textures per draw (the Xbox's four stages) needs another layout and
  more sets per texture.
- Textures: RGBA8 decoded on the CPU, levels as a 2D mip chain. There are no
  compressed formats on the GPU (DXT would be decoded on the CPU), no cube
  maps, no 3D textures. Sampler keys cover wrap or clamp, filters and mips
  only (no mirror, no border colour other than transparent black, no
  anisotropy).
- Batches: one vertex format, non-indexed draws, `HLEVertexCapacity`
  vertices per slot.
- One scale for all targets. Frames are read back to host memory; the
  readback buffer is sized from the frame size given at creation.
- One graphics queue and two slots; not thread safe (the emulation thread
  only).
