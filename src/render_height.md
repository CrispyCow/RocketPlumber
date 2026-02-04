# Render height guide

This document describes the numeric render-height scheme used across the renderer. It is the single source of truth for choosing draw heights when pushing `RenderCommand`s.

## Principles

- Render order is deterministic and controlled by a signed 32-bit integer called `draw_height` placed on every `RenderCommand`.
- Commands are sorted ascending (lowest to highest). Lower numbers draw first (background), higher numbers draw last (overlays/ui).
- Use the named constants defined in `local_packages/HexFlowRendering/src/HexFlowRendering.jl` where possible rather than hard-coding numbers. Note: the constants are NOT exported — reference them as `HexFlowRendering.RENDER_HEIGHT_*`.

## Canonical named layers (current)

These are the canonical constants defined in `HexFlowRendering.jl` and their intended semantics:

- `RENDER_HEIGHT_BACKGROUND = -1000` : Deep background, world-floor, very-behind geometry.
- Tractor beams (docking connection visuals) render at `RENDER_HEIGHT_TRACTOR_BEAM` so they sit deep in the background, behind both ship tiles and components. ⚠️ Note: this constant is defined in `local_packages/HexFlowRendering/src/HexFlowRendering.jl`.
- `RENDER_HEIGHT_PIPE_BASE = -10`   : Base pipe sprite (beneath fluid mask).
- `RENDER_HEIGHT_PIPE = 0`          : Pipe fluid mask / main pipe layer. Pipes sit above background but beneath nodes/components.
- `RENDER_HEIGHT_NODE = 100000`     : Node vertices. Drawn above pipes and most component art, but below overlay UI.
- `RENDER_HEIGHT_COMPONENT_BEHIND = 1000` : Parts that should appear behind main component sprites (fluid masks, energy bars).
- `RENDER_HEIGHT_COMPONENT_STATIC = 2000` : Static component base art.
- `RENDER_HEIGHT_COMPONENT_ANIM = 3000` : Animated component overlays (thrust flames, pump on-sprites, smoke). Use small offsets above this for internal layering.
- `RENDER_HEIGHT_OVERLAY_BASE = 101000` : UI/overlays such as stalled-state overlays and other screen overlays. These should be very high to avoid accidental occlusion by components.

If you add a new named layer, add it to `HexFlowRendering.jl` and document it here.

## Offsets and composition

- Component and pipe renderers should accept an optional `render_height_offset::Integer=0` (codebase commonly uses `Int32` or `Integer`) and add it to their base heights. This allows tile-level nudging (e.g., multi-tile assemblies or modals) without changing the global constants.
- When delegating `render_base_elem!` / `render_map_elem!` or `render_pipe_base!`, forward `kwargs...` and preserve `render_height_offset` so lower-level helpers compute the final `draw_height`.
- Prefer expressing final heights using the named constants, e.g.:
  - `draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)`
  - `draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE) + Int32(render_height_offset)`

## Examples (real code patterns)

- Push a static base sprite (helper `render_basic_tile` / `render_basic_sprite`):
  - draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset
- Push a fluid mask behind the base (liquid/gas helpers):
  - draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset
- Push an animated flame on top of the component:
  - draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset
- Push a stall overlay from a fragment:
  - draw_height = HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE + render_height_offset

## RenderCommand and numeric rules

- The `RenderCommand` struct (in `local_packages/RenderEngine/src/RenderEngine.jl`) requires an explicit `draw_height` (an `Int32`) when constructing via the preferred constructor `RenderCommand(uniforms, VAO::Symbol, draw_height::Int32)`. There is a convenience constructor accepting `Int64` which validates the value fits in `Int32`.
- Because `draw_height` is an `Int32`, passing values outside the `Int32` range will raise an error — validate and cast when composing offsets.
- The renderer sorts queued commands by `(draw_height, program-type, VAO)` so equal `draw_height` values will be grouped deterministically by program/VAO.

## Ghost and placement helpers

- Tile ghost (placement preview) should be pushed above everything currently rendered by applying an offset of `+100000` via the `render_height_offset` kwarg when calling `render_base_elem!`. This is how the code currently does placement previews in `src/interactions.jl` (e.g., `render_height_offset = Int32(100000)`). Using the named constants this effectively produces heights above `RENDER_HEIGHT_OVERLAY_BASE`.
- Pipe ghost: prefer to draw the pipe-ghost at `RENDER_HEIGHT_PIPE + 1` (or `draw_height = 1`) so it sits above existing pipes (`RENDER_HEIGHT_PIPE = 0`) but well below nodes (`RENDER_HEIGHT_NODE = 100000`).

## Where to look / edit

- Named constants: `local_packages/HexFlowRendering/src/HexFlowRendering.jl` (they are intentionally not exported; reference as `HexFlowRendering.RENDER_HEIGHT_*`).
- RenderCommand behavior and sorting: `local_packages/RenderEngine/src/RenderEngine.jl`.
- Component and pipe rendering helpers (patterns for using offsets): `local_packages/HexFlowRendering/src/HexFlowRendering.jl`, `local_packages/components/*/src/*.jl`, and `local_packages/components/component_module_guide.md`.

## Notes for contributors

- Prefer placing draw-height assignment at the component fragment level (lowest-level helpers) rather than in the central renderer.
- When using literal offsets in code, cast to `Int32` (or `Integer` consistently) to avoid accidental type mismatches. Example: `Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)`.
- After changing render-height constants or call sites, run `include("src/repl_launch.jl")` from a Julia REPL to surface any signature or constructor errors early.

If anything here is unclear or you want a different layering for a particular component, open an issue or ask on the repo chat and reference this file.
