# Repository Tools Guide

Tools have different environments and side effects. Read the tool's source and
local README/instructions before running it, and invoke paths from the
repository root unless its documentation explicitly changes directory.

Directly runnable `tools/*.jl` scripts are the preferred entry points for
common developer operations. They should normally work from the repository
root and, where intended, through VS Code Run File / Execute File. Substantial
implementations and resources live in UpperCamelCase directories such as
`TexturePacker/`, `EncounterBalance/`, and `TimelapseExport/`; directory casing
does not indicate whether a Julia environment is present. Specialist multi-step
agent workflows belong under `.agents/skills/` rather than turning every
command an agent might run into a skill.

## Maintenance Tools

- `run_all_package_tests.jl` dynamically discovers
  `local_packages/**/test/runtests.jl`, runs suites in separate processes, and
  writes ignored logs under `logs/package_test_runs/`. It does not run tool
  tests. Use `--list` or `--help` before a large sweep.
- `local_package_updater.jl` refreshes every local package environment by
  resolving, instantiating, and precompiling it in a separate Julia process.
  This broader maintenance action may change manifests through Pkg resolution,
  even without `--update`, so use it intentionally. `--update` explicitly
  requests package upgrades and should only be used when upgrades are in scope.

## Texture Atlas

`TexturePacker/` has its own environment. Source PNGs are in `textures/`, and
the generated `outputs/TileTextureAtlas1.png` and `.json` files are tracked and
used directly in development.

From the repository root, rebuild the standard atlas with:

```shell
julia tools/pack_textures.jl
```

The launcher also works with VS Code Run File and starts a separate Julia
process with the Texture Packer project. For custom options or CLI help, use
the underlying tool directly:

```shell
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl --help
julia --project=tools/TexturePacker tools/TexturePacker/src/TexturePacker.jl \
  tools/TexturePacker/textures tools/TexturePacker/outputs/TileTextureAtlas1 \
  --pack-method row
```

The code's current default packing method is `row`; the launcher passes it
explicitly so an atlas-wide layout change is intentional. Commit the PNG and
JSON together and launch the application to inspect any changed sprites.

## Time-Lapse Export

- `TimelapseExport/` uses the root project because it depends on the game's
  packages, rendering stack, and persisted component registrations. Run
  `julia tools/export_timelapse.jl` to export using the editable configuration
  near the top of the launcher; its relative input and output paths are rooted
  at the repository. Arguments supplied to the launcher are forwarded to the
  exporter. Use `julia --project=. tools/TimelapseExport/export.jl --help` for
  the complete CLI and `julia --project=. tools/TimelapseExport/test/runtests.jl`
  for its pure test suite. Real exports require OpenGL and a display;
  `--inspect` does not. Do not commit generated videos, GIFs, palettes, or test
  saves.

## Production Artifacts

Production rendering artifacts and executable builds are created in an
external build repository. Tools here generate development assets only.

## Encounter Balance

From the repository root, generate encounter class, fuel-tag, and component-set
selection plots with:

```shell
julia tools/encounter_balance.jl
```

The PNGs are written to the ignored `tools/EncounterBalance/outputs/` directory.
Use `--display` to also show them in a graphical Julia front end. Run the
deterministic generated-encounter audit with:

```shell
julia tools/encounter_balance.jl --audit
```

The launcher also works with VS Code Run File. It starts a fresh Julia process
with the root game environment first and the small Encounter Balance environment
second. The latter supplies `Plots`; do not add it to the root project.
Before first use, instantiate the tool environment with
`julia --project=tools/EncounterBalance -e 'using Pkg; Pkg.instantiate()'`.
Use the repository-level launcher so the required environment stack is set
consistently.
