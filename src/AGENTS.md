# src - Codex Notes

This directory contains the top-level game application code. Also consult the
root `AGENTS.md` and `src/CLAUDE.md` when making non-trivial changes here.

## Key Files

- `repl_launch.jl`: development entry point with Revise and hot reload.
- `auto_test_launch.jl`: non-interactive smoke test that boots gameplay and
  exits after a tick cap.
- `julia_main.jl`: production entry point.
- `gameloop.jl`: GL init, snapshot management, rendering, calculator IPC, and
  learning system tick.
- `map_loading.jl`: JLD2 serialisation and reconstruction hooks.
- `interactions.jl`: keyboard and mouse input, cursor transforms, placement,
  docking beam rendering, and command enqueueing.
- `components.jl`: concrete components and pipes, proc-gen specialisations,
  ship generation configs and weights.
- `tutorials.jl`: learning entries and demo map includes.
- `ui_common.jl`, `ui_game.jl`, `ui_menus.jl`, `ui_learning.jl`: ImGui UI.
- `recording.jl`: FFmpeg screen recording and PNG screenshots.
- `startmenu.jl`: main menu and session state machine.
- `initial_window_setup.jl`: GLFW window and CImGui/ImPlot setup.
- `demo_maps/mapgen_*.jl`: tutorial map generators.

## Editing Rules

- Route gameplay mutations from UI/input code through `MapEditCommand` and
  `try_enqueue_command!`.
- Treat `FlowCalculatorSnapshot` as the render thread's read model.
- When changing saved structures, check whether `src/map_loading.jl` needs a
  reconstruction hook for older saves.
- When adding sprites, place source PNGs under `tools/TexturePacker/textures/`
  and regenerate the atlas and JSON with the texture packer.
- Render height constants live in `HexFlowRendering`; use the exported or
  qualified constants rather than magic numbers.
- Shader uniform struct field names must match GLSL uniform names exactly.

## Simulation Tick Order

Preserve this order unless the change explicitly requires a different one:

1. `update_docking!`
2. `update_manoeuvre_phase!`
3. `update_components!`
4. `update_map!`
5. `update_mna!`
6. `handle_thrusters!`
7. `step_space_map_time!`
8. Publish a deep-copied `FlowCalculatorSnapshot`

