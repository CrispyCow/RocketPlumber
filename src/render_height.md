# Render height guide

This document describes the numeric render-height scheme used across the renderer. It is the single source of truth for choosing draw heights when pushing `RenderCommand`s.

## Principles

- Render order is deterministic and controlled by a signed 32-bit integer called `draw_height` placed on every `RenderCommand`.
- Commands are sorted ascending (lowest to highest). Lower numbers draw first (background), higher numbers draw last (overlays/ui).
- Use the named constants defined in `local_packages/HexFlowRendering/src/HexFlowRendering.jl` where possible rather than hard-coding numbers. The constants are not exported; reference them as `HexFlowRendering.RENDER_HEIGHT_*`.

## Canonical named layers

These are the canonical constants defined in `HexFlowRendering.jl` and their intended semantics:

- `RENDER_HEIGHT_TRACTOR_BEAM = -1100`: Docking connection visuals, deep background.
- `RENDER_HEIGHT_BACKGROUND = -1000`: Ship surface tiles and world-floor geometry.
- `RENDER_HEIGHT_PIPE_RANK_MULTIPLIER = 10`: Spacing between deterministic pipe stacking-rank bands.
- `RENDER_HEIGHT_COMPONENT_BEHIND = 1000`: Parts that should appear behind main component sprites (fluid masks, energy bars).
- `RENDER_HEIGHT_COMPONENT_STATIC = 2000`: Static component base art.
- `RENDER_HEIGHT_COMPONENT_ANIM = 3000`: Animated component overlays (thrust flames, pump on-sprites, smoke). Use small offsets above this for internal layering.
- `RENDER_HEIGHT_NODE = 100000`: Node vertices. Drawn above pipes and most component art, but below overlay UI.
- `RENDER_HEIGHT_OVERLAY_BASE = 101000`: UI/overlays such as stalled-state overlays and other screen overlays. These should be very high to avoid accidental occlusion by components.
- `ANIMATING_SHIP_RENDER_HEIGHT_OFFSET = 1500000000`: Lift applied to an animating ship's full render stack. This is intentionally above `RENDER_HEIGHT_OVERLAY_BASE` so the entire moving ship, including nodes and stall overlays, sits above stationary ships.

`RENDER_HEIGHT_PIPE_BASE` and `RENDER_HEIGHT_PIPE` remain defined for legacy flat pipe renderers. Rank-aware pipe renderers should use `RENDER_HEIGHT_PIPE_RANK_MULTIPLIER`.

If you add a new named layer, add it to `HexFlowRendering.jl` and document it here.

## Pipe stacking ranks

Pipes use deterministic stacking ranks from `HexFrame.get_stacking_rank(pipe::PipeCoord)::Int`. Higher ranks stack above lower ranks.

- Long diagonals: ranks 1-3.
- Short diagonal pairs: ranks 4-6.
- Side spans: rank 7.

Rank-aware pipe renderers reserve a 10-unit render-height band for each rank:

```julia
fluidmask_height = Int32(get_stacking_rank(position)) * HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER + Int32(render_height_offset)
pipe_height = fluidmask_height + Int32(1)
```

This gives the following default heights:

| Rank | Fluid mask | Pipe sprite |
|------|------------|-------------|
| 1 | 10 | 11 |
| 2 | 20 | 21 |
| 3 | 30 | 31 |
| 4 | 40 | 41 |
| 5 | 50 | 51 |
| 6 | 60 | 61 |
| 7 | 70 | 71 |

Within each band, the fluid mask renders first and the pipe sprite renders second. Across bands, a higher-rank fluid mask renders above the complete lower-rank pipe, so overlapping pipe masks and sprites stack consistently.

## Offsets and composition

- Component and pipe renderers should accept an optional `render_height_offset::Integer = 0` and add it to their base heights. This allows tile-level nudging, moving-ship lifting, and previews without changing global constants.
- When delegating `render_base_elem!`, `render_map_elem!`, `render_pipe_base!`, or `render_pipe_map!`, forward `kwargs...` and preserve `render_height_offset` so lower-level helpers compute the final `draw_height`.
- For ships that are being animated by docking/undocking, use the dedicated `ANIMATING_SHIP_RENDER_HEIGHT_OFFSET` rather than a small ad hoc bump. The intent is to move the whole ship render stack above every stationary layer, not just above tiles or pipes.

## Examples

- Push a pipe fluid mask at the bottom of its rank band:
  - `draw_height = Int32(get_stacking_rank(position)) * HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER + Int32(render_height_offset)`
- Push the pipe sprite above its fluid mask:
  - `draw_height = Int32(get_stacking_rank(position)) * HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER + Int32(1) + Int32(render_height_offset)`
- Push a component fluid mask behind the base:
  - `draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset`
- Push a static component base sprite:
  - `draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset`
- Push an animated flame on top of the component:
  - `draw_height = HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset`
- Push a stall overlay from a fragment:
  - `draw_height = HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE + render_height_offset`

## RenderCommand and numeric rules

- The `RenderCommand` struct in `local_packages/RenderEngine/src/RenderEngine.jl` requires an explicit `draw_height` (`Int32`) when constructing via `RenderCommand(uniforms, draw_height::Int32)`.
- There is a convenience constructor accepting `Int64` which validates the value fits in `Int32`.
- Because `draw_height` is an `Int32`, passing values outside the `Int32` range will raise an error; validate and cast when composing offsets.
- The renderer sorts queued commands by `(draw_height, program-type)`, so distinct rank-band heights are the intended ordering mechanism for overlapping pipes.

## Ghost and placement helpers

- Tile ghost placement previews should be pushed above normal world rendering by applying an offset of `+100000` via the `render_height_offset` kwarg when calling `render_base_elem!`. This is how the code currently does placement previews in `src/interactions.jl`.
- Pipe ghosts should use the same rank-band calculation as normal pipes with an appropriate preview offset. Avoid reverting pipe previews to the old flat `RENDER_HEIGHT_PIPE` layer.

## Where to look / edit

- Named constants: `local_packages/HexFlowRendering/src/HexFlowRendering.jl`.
- RenderCommand behaviour and sorting: `local_packages/RenderEngine/src/RenderEngine.jl`.
- Pipe rank calculation: `local_packages/HexFrame/src/HexFrame.jl`.
- Component and pipe rendering helpers: `local_packages/HexFlowRendering/src/HexFlowRendering.jl`, `local_packages/components/*/src/*.jl`, and `local_packages/components/component_module_guide.md`.

## Notes for contributors

- Prefer placing draw-height assignment at the component fragment level (lowest-level helpers) rather than in the central renderer.
- When using literal offsets in code, cast to `Int32` or accept `Integer` consistently to avoid accidental type mismatches.
- After changing render-height constants or call sites, run `include("scripts/repl_launch.jl")` from a Julia REPL started with `--project=dev` to surface signature or constructor errors early.
