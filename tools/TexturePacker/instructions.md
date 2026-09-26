# Texture Packer

From the repository root, run the standard Rocket Plumber atlas build with:

```shell
julia tools/pack_textures.jl
```

You can also open `tools/pack_textures.jl` in VS Code and use **Run File**. The
launcher uses this tool's Julia environment in a separate process and resolves
all paths from its own location, regardless of the current working directory.
It reads PNGs from `tools/TexturePacker/textures/` and writes the tracked
runtime atlas to
`local_packages/HexFlowRendering/assets/texture_atlas/TileTextureAtlas1.png`
and `.json`. `HexFlowRendering` owns and loads these package resources. The
standard atlas uses row packing and the tool's existing defaults for padding
and other options. Review and commit both generated files together when the
source textures change.

For help or custom source, output, or packing options, invoke the underlying
tool directly from the repository root:

```shell
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl --help
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl \
  tools/TexturePacker/textures local_packages/HexFlowRendering/assets/texture_atlas/TileTextureAtlas1 \
  --pack-method row
```

The CLI supports `--pack-method row|rect`, `--padding`, `--filetype`,
`--pack-margin`, and `--atlas-width-step`. Run `--help` for their current
defaults. The output base is a path without an extension; the tool writes both
`<output_base>.png` and `<output_base>.json`.
