# Application Layer Guide

`src/` connects the local packages into the playable application. Keep domain
logic in the lowest suitable package; this layer should primarily coordinate
launching, input, UI, rendering, persistence, and game-session flow.

## File Map

- `repl_launch.jl` is the development entry point. It loads Revise so package
  code, shaders, and source assets can be iterated on in place.
- `auto_test_launch.jl` boots the real application, drives
  `test_harness.jl`, and exits through the normal shutdown path.
- `julia_main.jl` is the production/JuliaC entry point. It does not build
  assets; it verifies that the externally produced rendering artifacts exist.
- `initial_window_setup.jl`, `startmenu.jl`, and `gameloop.jl` own application
  startup, session transitions, the render loop, and calculator IPC.
- `interactions.jl` translates keyboard and mouse input into view-only changes
  or calculator commands.
- `ui_*.jl` contains the CImGui interface. `recording.jl` and `timelapse.jl`
  handle capture concerns.
- `components.jl` defines application-level component instances and
  procedural-generation registrations; implementations live in
  `local_packages/components/`.
- `tutorials.jl` defines learning entries and includes generators from
  `demo_maps/`.
- `map_loading.jl` owns JLD2 save/load adapters and upgrade conversions.

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

- When a persisted type changes shape, package, or meaning, update the typemap
  and/or `rconvert` reconstruction in `map_loading.jl` and test an older save
  when one is available.
- Struct field defaults are not a substitute for JLD2 migration logic.
- Keep `GameMap` and saved domain types independent of UI/OpenGL state.
- Demo maps are Julia generators under `demo_maps/`; keep tutorial registration
  in `tutorials.jl` aligned when adding, removing, or renaming one.

## Rendering Integration

- Use the named render-height constants from `HexFlowRendering`. The ordering
  and reserved bands are documented in `render_height.md`.
- Preserve per-ship `pos_offset` and `render_height_offset` as render calls pass
  through application code.
- Source sprites belong in `tools/TexturePacker/textures/`; development uses
  the tracked atlas in `tools/TexturePacker/outputs/`. Follow
  `tools/AGENTS.md` for regeneration.
- Shader and render-program changes belong in `HexFlowRendering` or
  `RenderEngine`, not in the UI files.

## Verification

For application integration or gameplay changes, run:

```shell
julia --project=. --threads=2,1 --gcthreads=1,1 src/auto_test_launch.jl
```

This opens a real window and needs a working display/OpenGL context. Allow
roughly six minutes before treating startup or execution as hung. Use
`src/repl_launch.jl` for behaviour that requires manual inspection. Changes
limited to a local package should run that package's tests first.
