# Optional Vulkan GE in the PSP frontend

The RetroMul PSP settings page now offers **Renderer: CPU (software) / Vulkan
compute (experimental)**. The persisted setting is in `psp.ini`:

```ini
[Video]
Renderer=cpu
```

`vulkan` requests the compute backend. Missing/unknown values use CPU. CPU is
still the default, and Win32 remains CPU-only. Vulkan driver/feature/self-test
failure is nonfatal: the worker keeps running on the CPU, logs the reason through
`Console.HLE.Log`, and exposes it in `TPSPCoreAdapter.RendererStatus`. It is not
sent to `TakeError`, because the frontend treats that channel as a fatal fault.

## Application semantics and lifetime

The choice is captured when a new PSP worker is created, normally on Stop/Start
or reopening the game. It is marked `OnNextLoad` in the settings page. Changing
it during play does not switch the active renderer. Reset/LoadExec of a running
game retain the choice and the backend. Reset of an already faulted/finished
worker already recreated the worker before this change, so that is a restart.

`Core.Platforms.PSP.Renderer.TPSPRendererSession` owns the backend inside
`TPSPWorker.Execute`, in a `try/finally`. It creates and destroys Vulkan on that
worker thread, detaches the engine seam before destruction, and releases it
before the console, GE and memory are destroyed. The existing memory reset
faults drain held VRAM on Reset and LoadExec; neither replaces those objects.
The constructor probe in `TPSPCoreAdapter.Create` never initializes Vulkan.

The backend's destructor now releases resources in `finally` even if its last
Sync fails, and the arithmetic self-test frees any partially created temporary
resources on construction failure. Device-loss recovery/replay during rendering
is still not implemented; real run failures use the existing worker error path.

Audio queue pacing, `Core.Platforms.PSP.Playback`, live JIT selection, system language,
confirm-button choice and nickname are unchanged. The timing anchors are set
after renderer initialization so Vulkan startup time does not become guest time.
No raster/texture arithmetic or GE-engine seam was changed for frontend wiring.

## Reproduce

Initialize the existing dependency submodules (including WinUI's children):

```powershell
git submodule update --init --recursive
.\tests\cores\psp\run\build_frontend.ps1
.\tests\cores\psp\run\build.ps1 -Project PSPAdapterRun.dpr
.\tests\cores\psp\run\bin\PSPAdapterRun_win64.exe D:\Soft\PSP\Lumines.cso 12 cpu.png -mute -frame 180
.\tests\cores\psp\run\bin\PSPAdapterRun_win64.exe D:\Soft\PSP\Lumines.cso 12 gpu.png -mute -frame 180 -gpu
.\tests\cores\psp\run\bin\PSPAdapterRun_win64.exe D:\Soft\PSP\Lumines.cso 9 -gpu -lifecycle -mute
```

The adapter smoke opens through `CreateEmulationCore`, not the headless PSPRun
path. `-frame N` captures exactly frame N and fails if polling misses it or it
times out; it never substitutes a nearby frame. `-lifecycle` exercises
pause/resume, reset and stop/start. Its displayed frame count spans restarts and
is deliberately not presented as an FPS measurement. `-gpu` changes only this
run's config object, not the user's saved INI.

```powershell
.\tests\cores\psp\run\build.ps1 -Project PSPRendererLifecycleTest.dpr
$env:VK_INSTANCE_LAYERS = 'VK_LAYER_KHRONOS_validation'
$env:VK_LAYER_VALIDATE_SYNC = '1'
.\tests\cores\psp\run\bin\PSPRendererLifecycleTest_win64.exe `
  .\tests\cores\psp\run\pspautotests\tests\gpu\primitives\triangles.prx
Remove-Item Env:VK_INSTANCE_LAYERS, Env:VK_LAYER_VALIDATE_SYNC

.\tests\cores\psp\run\build_frontend_targets.ps1
```

The lifecycle test checks config defaults/round trips and preservation of system
and interpreter choices. On an actual worker thread it queues GPU work, resets,
requests the console's normal LoadExec callback, verifies that RAM was reset and
the backend survived, injects constructor and run exceptions, verifies detached
callbacks and released held pages, then reattaches. It requires a usable Vulkan
device; an unsupported host is not counted as a GPU test pass.

## Verified here

* Windows/Win64 RetroMul **full Release build and link pass**, including settings
  UI. `build_frontend.ps1` supplies dependency paths for a fresh worktree and
  keeps the complete MSBuild log in `bin/frontend-Win64-Release.log`.
* Linux64 and Android64 compile the adapter, session, settings page, Vulkan
  backend and dependencies successfully using Delphi 37.0. This is **unit/object
  compilation only**, not a linked application or a runtime qualification.
  Full logs are in `bin/frontend-<target>/build.log`; compiler exit codes are
  checked, not filtered away. Initial missing submodule/search-path failures were
  corrected by initializing the pinned dependencies and supplying their paths.
* Factory/worker Lumines frame 180: CPU and Vulkan PNGs and full pixel SHA-256
  match, both muted and with audio. Muted pacing was about 60 guest FPS in both
  modes; audio runs include queue priming and were about 62 FPS over this short
  startup interval. This is a pacing smoke, not a new renderer speed benchmark.
  Hash: `6bf95967c05f704b4cb2ba641d86a14afde6b511f6da7de8fc62d488289dc281`.
* Factory/worker Daxter frame 180: CPU and Vulkan PNGs/hash match at about 60
  guest FPS. Vulkan reports 39,166 GPU primitives in this run.
  Hash: `fabd3dbfd6fdfcd3230b59378477ad3f545276c988cc3fc63b13b6f6617663a8`.
* Muted CPU and Vulkan pause/reset/restart smoke runs complete without error.
* Forced missing ICD: adapter remains live on CPU, with the same Lumines frame
  180 hash/PNG and no fatal `TakeError` notification.
* Win32 adapter builds and runs `-gpu` on CPU with the unsupported-host reason.
* Worker-thread lifecycle/config/failure-injection test passes with normal and
  synchronization validation enabled, with no Vulkan validation errors.

The CPU/GPU bit-exactness qualification and remaining per-primitive fallbacks
are unchanged; see `tests/gpu/vulkan/README.md`. Linux/Android runtime behaviour
has not been tested on devices by this worker.
