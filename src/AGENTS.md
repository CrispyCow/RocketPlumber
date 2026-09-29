# Application Layer Guide

`src/` connects the local packages into the playable application. Keep domain
logic in the lowest suitable package; this layer should primarily coordinate
launching, input, UI, rendering, persistence, and game-session flow.

## File Map

- `RocketPlumber.jl` is the canonical application assembly point. Keep normal
  application source includes and runtime imports there.
- `precompile_workload.jl` exercises a headless game-session path during root
  package precompilation, after application definitions and entry points.
- `scripts/repl_launch.jl` is a thin development adapter that loads Revise
  before RocketPlumber and calls `RocketPlumber.launch()`.
- `scripts/smoke_test.jl` loads `test/smoke/` support after importing the package.
  Its fixture drives the optional frame hook and exits through normal shutdown;
  smoke-only definitions are not part of normal package assembly.
- `RocketPlumber.jl` owns the JuliaC `@main(args)` and PackageCompiler
  `julia_main()::Cint` entry points. Both call `launch()` through one startup
  path. Runtime resources are owned by `HexFlowRendering`.
- `initial_window_setup.jl`, `startmenu.jl`, and `gameloop.jl` own application
  startup, session transitions, the render loop, and calculator IPC. Startup is
  invoked through the package API; importing the package must remain passive.
  Headless callers must set `JULIA_GLFW_PLATFORM=null` before importing the
  package; `RocketPlumber.jl` must not choose a process-wide GLFW backend.
- `interactions.jl` translates keyboard and mouse input into view-only changes
  or calculator commands.
- `ui_*.jl` contains the CImGui interface. `recording.jl` and `timelapse.jl`
  handle capture concerns.
- `components.jl` defines application-level component instances and
  procedural-generation registrations; implementations live in
  `local_packages/components/`.
- `tutorials.jl` defines learning entries and includes generators from
  `demo_maps/`.
- `gameloop.jl` owns session orchestration, calculator IPC, and dispatch from
  saved, generated, or empty map sources; `HexFlowPersistence` owns saved types,
  JLD2 save/load, and upgrade conversions.

## Thread And State Boundaries

- The main thread owns GLFW events, OpenGL, CImGui, input, and rendering. The
  calculator thread owns authoritative simulation mutation.
- Send gameplay changes through `MapEditCommand` constructors and
  `try_enqueue_command!`. Do not mutate the live `GameMap` from UI, input, or
  render code.
- Treat the latest `FlowCalculatorSnapshot` as a read-only render model. The
  calculator publishes through triple-buffered storage; do not retain or
  mutate snapshot internals as an alternate state channel.
- View and other presentation-only state may remain on the main thread when it
  cannot affect simulation results.

The authoritative calculator pipeline and transaction rules live in
`local_packages/HexFlowCalculator/AGENTS.md`. If an application change needs a
new mutation, add a command rather than bypassing that boundary.

## Persistence

- When a persisted type changes shape, package, or meaning, review the typemap
  and `rconvert` reconstruction in `HexFlowPersistence/src/migrations.jl`
  under `local_packages/`, and test an older save when one is available.
- Struct field defaults are not a substitute for JLD2 migration logic.
- Keep `GameMap` and saved domain types independent of UI/OpenGL state.
- Demo maps are Julia generators under `demo_maps/`; keep tutorial registration
  in `tutorials.jl` aligned when adding, removing, or renaming one.

## Rendering Integration

- Use the named render-height constants from `HexFlowRendering`. The ordering
  and reserved bands are documented in `render_height.md`.
- Preserve per-ship `pos_offset` and `render_height_offset` as render calls pass
  through application code.
- Runtime shaders and the atlas belong to `HexFlowRendering`. Source sprites
  remain in `tools/TexturePacker/textures/`; follow `tools/AGENTS.md` for
  regeneration. Same-repository consumers should use the package resource
  accessors rather than reconstructing package paths.
- Shader and render-program changes belong in `HexFlowRendering` or
  `RenderEngine`, not in the UI files.

## Verification

For application integration or gameplay changes, run:

```shell
julia --project=. --threads=2,1 --gcthreads=1,1 scripts/smoke_test.jl
```

This opens a real window and needs a working display/OpenGL context. Allow
roughly six minutes before treating startup or execution as hung. Use
`scripts/repl_launch.jl` for behaviour that requires manual inspection. Changes
limited to a local package should run that package's tests first.
