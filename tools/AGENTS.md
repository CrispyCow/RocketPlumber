# Repository Tools Guide

Tools have different environments and side effects. Read the tool's source and
local README/instructions before running it, and invoke paths from the
repository root unless its documentation explicitly changes directory.

`review_instructions.md` is an opt-in checklist for a particular review
workflow, not a repository-wide policy. The root `AGENTS.md` Runic rules take
precedence during ordinary edits.

## Maintenance Tools

- `run_all_package_tests.jl` dynamically discovers
  `local_packages/**/test/runtests.jl`, runs suites in separate processes, and
  writes ignored logs under `logs/package_test_runs/`. It does not run tool
  tests. Use `--list` or `--help` before a large sweep.
- `local_package_updater.jl` resolves, instantiates, and precompiles every local
  package environment. Its `--update` option additionally upgrades packages
  and is expected to change resolution/manifests; use it only when upgrades are
  in scope.

## Texture Atlas

`TexturePacker/` has its own environment. Source PNGs are in `textures/`, and
the generated `outputs/TileTextureAtlas1.png` and `.json` files are tracked and
used directly in development.

From the repository root, inspect or run the current CLI with:

```shell
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl --help
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl \
  tools/TexturePacker/textures tools/TexturePacker/outputs/TileTextureAtlas1 \
  --pack-method row
```

The code's current default packing method is `row`; pass the method explicitly
so an atlas-wide layout change is intentional. Commit the PNG and JSON together
and launch the application to inspect any changed sprites.

## Map Tools

- `map_encoder/encode_map.jl` takes an existing `.jld2` path, not a bare map
  name. A bare `.jl` output filename is placed under `src/demo_maps/`.
- `map_encoder/compare_maps.jl` takes the original `.jld2` path and a generator
  file, then checks structure, identity safety, and produced elements.
- `map_encoder/README.md` gives the CLI overview and
  `map_encode_instructions.md` gives the agent authoring workflow. The scripts'
  current usage/error text remains authoritative if documentation later drifts.
- `map_diagnostics/` loads saved maps using the application's conversion hooks
  and is the preferred place for one-off MNA/save inspection rather than adding
  diagnostics to gameplay code.

## Standalone Tool Environments

- `timelapse_export/` is a separately tested tool that uses the root project.
  Run its pure suite with
  `julia --project=. tools/timelapse_export/test/runtests.jl`. Real exports
  require OpenGL and a display; `--inspect` does not. Do not commit generated
  videos, GIFs, palettes, or test saves.
- `EncounterBalance/` uses its own environment for `Plots` while loading game
  packages from the root environment. Instantiate its environment before first
  use; `--audit` runs the textual generation audit.
- Production rendering artifacts and executable builds are created in an
  external build repository. Tools here generate development assets only.
