# HexFlowRendering Guide

`HexFlowRendering` is the game-specific layer above `RenderEngine`. It defines
typed render programs, shaders, sprite/tile/pipe helpers, particles, animation,
and render-height constants. Keep raw OpenGL resource mechanics in
`RenderEngine` and gameplay state mutation outside both packages.

## Render Program Contracts

- A render-program change commonly spans the program singleton type, its
  `AbstractRenderUniforms` struct, the `uniforms_type` mapping, shader sources,
  initialisation helper, and command construction. Review them together.
- Uniform struct field names must match GLSL uniform names exactly; program
  setup discovers locations from those fields.
- Call `setup_glprog!` with the corresponding shader stages and vertex layout.
  Attribute layout changes must stay aligned with `VboAttribFormat`, shader
  inputs, VAO creation, and every producer of that vertex data.
- Keep render commands data-only. OpenGL calls and resource ownership remain on
  the main thread.

## Position And Layering

- Forward `pos_offset` through all component, pipe, beam, and helper render
  paths so docking animation applies uniformly.
- Forward `render_height_offset` and use the named render-height constants; do
  not introduce local magic heights. `src/render_height.md` is the detailed
  ordering reference and must be updated when the global layer scheme changes.
- Pipe stacking uses `HexFrame` stacking ranks and
  `RENDER_HEIGHT_PIPE_RANK_MULTIPLIER`; preserve deterministic ordering for
  overlapping pipe spans.

## Assets

- Runtime shaders and the texture atlas belong under `assets/` in this package.
  Resource accessors `shader_dir()` and `texture_atlas_dir()` expose their
  relocatable package paths for same-repository consumers.
- Resource roots use `RelocatableFolders.@path`; resolve child paths when the
  resource is accessed. Revise does not affect resource selection.
- Add source sprites under `tools/TexturePacker/textures/` and regenerate the
  tracked atlas in `assets/texture_atlas/`. See `tools/AGENTS.md`.

## Verification

Run:

```shell
julia --project=local_packages/HexFlowRendering -e 'using Pkg; Pkg.test()'
```

Changes involving real shader compilation, atlas contents, or OpenGL state also
need a display-enabled application launch and visual inspection.
