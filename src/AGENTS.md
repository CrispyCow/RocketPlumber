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
  path. `parse_launch_args` handles `--telemetry`, and `launch(; telemetry)`
  starts telemetry before the loops and saves its report on normal shutdown.
  Session cleanup collects partial intervals after waiting for the calculator.
  Runtime resources are owned by `HexFlowRendering`.
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
- `RocketPlumber.jl` includes generators from `demo_maps/`; `tutorials.jl`
  defines the tutorial map registry and learning entries.
- `gameloop.jl` owns session orchestration, calculator IPC, and dispatch from
  saved, generated, or empty map sources; `HexFlowPersistence` owns saved types,
  JLD2 save/load, and upgrade conversions.

## Thread And State Boundaries

- The main thread owns GLFW events, OpenGL, CImGui, input, and rendering. The
  calculator thread owns authoritative simulation mutation. Keep Julia's
  normal I/O-loop scheduling and yield between rendered frames so it can
  service pending tasks and timer wake-ups.
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

- The game session supplies `write_game_crash_dump` through the calculator loop's
  `crash_dump_writer` keyword. It adds the root package version and delegates
  timestamp/path/JLD2 writing to `HexFlowPersistence` synchronously before shutdown.
- Route application saves through `save_game` in `gameloop.jl`; it passes the
  root package version from `Base.pkgversion` to `HexFlowPersistence.savemap`.
  Save failures propagate through these wrappers; interactive UI actions catch
  them, warn with the path/backtrace, and use `flowcalc_ipc.console_push` to notify
  the player. Start-menu loading likewise catches authoritative map errors.
  These interactive boundaries propagate interrupts; calculator crash-dump writer
  failures remain contained so shutdown proceeds.
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

## CImGui UI

- Normal UI text uses the default embedded ProggyClean bitmap font at 13 px; do not push a font for normal-sized text.
- Text rendered at an explicit non-default size should use `CImGui.PushFont(UI_VECTOR_FONT, size)` so the embedded scalable ProggyForever font is used.
- Do not use `CImGui.PushFont(C_NULL, size)` to scale the default bitmap font.

## Verification

For application integration or gameplay changes, run:

```shell
julia --project=. --threads=2,1 scripts/smoke_test.jl
```

This opens a real window and needs a working display/OpenGL context and the
documented Julia threading setup. Its 1200-tick script represents about twenty
seconds at 60 UPS; a warmed run took about half a minute including startup and
teardown. Fresh compilation may take longer. The graphical test is not part of
the headless CI sweep. Pass `--telemetry --duration 60` for a longer telemetry
run; the default remains 20 simulated seconds, and shorter runs are rejected.
Use `scripts/repl_launch.jl` for behaviour that requires
manual inspection. Changes limited to a local package should run that
package's tests first.
