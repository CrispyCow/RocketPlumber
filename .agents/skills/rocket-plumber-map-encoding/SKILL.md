---
name: rocket-plumber-map-encoding
description: Reconstruct a saved Rocket Plumber JLD2 GameMap as maintainable Julia map-generator source and validate it against the save. Use only when explicitly asked to encode, reconstruct, or convert a saved map.
---

# Rocket Plumber Map Encoding

Turn a trusted saved `GameMap` into maintainable `mapgen_*` Julia source. The bundled scripts inspect the save, provide a mechanically faithful draft when useful, and compare the finished generator with the saved construction state.

Run every command from the repository root with the root Julia project. The component dependency chain currently loads rendering packages, so the scripts require a working display/OpenGL environment. If GLFW/X11 initialisation fails in a restricted execution context, retry the same trusted command in an approved display-enabled context when one is available; that failure says nothing about the save itself.

## Required resources

Before writing or changing a generator, read [references/reconstruction-guide.md](references/reconstruction-guide.md) completely. It contains the current constructor, ownership, placement, immutable values, multi-ship, and cleanup rules that are easy to miss from encoder output alone.

Before interpreting comparator output or declaring success, read [references/validation.md](references/validation.md) completely. It defines what the comparator proves, what it deliberately omits, and how to diagnose failures.

The scripts are normal command-line programs; inspect their source only when maintaining or debugging the helpers themselves.

## Workflow

1. Locate the actual `.jld2` save and decide the intended final generator path. Preserve any existing user changes and read the applicable repository instructions for that path.
2. Inspect the save with the strict encoder:

   ```shell
   julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/encode_map.jl path/to/source.jld2
   ```

   Confirm the reported ships and component, pipe, and surface counts are plausible before authoring code.
3. Read the reconstruction guide, inspect the current constructors and nearby demo maps it points to, then choose either:
   - manual authoring for a small or conceptually simple map; or
   - a mechanically generated draft for a large map:

     ```shell
     julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/encode_map.jl \
       path/to/source.jld2 /tmp/mapgen_example.jl
     ```

   The output filename determines the generated function name. Treat direct output as a faithful starting point, not maintainable final source.
4. Put the final `mapgen_*` function in the appropriate project location, normally `src/demo_maps/`. Use current public constructors, meaningful grouping, terse comments, and all saved runtime values. Immutable component and pipe templates may be reused directly across placements.
5. Before final validation, add the standard formatter header to the final MapGen file, with an accurate, stable `Scope:` describing that specific map, then run Runic on the file:

   ```julia
   #=
   Scope: <accurate description of this map generator>
   Formatter: Runic
   =#
   ```

   ```shell
   julia --project=@runic -m Runic --inplace src/demo_maps/mapgen_example.jl
   ```

6. Run the comparator against the formatted final file:

   ```shell
   julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/compare_maps.jl \
     path/to/source.jld2 src/demo_maps/mapgen_example.jl
   ```

   The comparator calls the top-level zero-argument function named after the generator file stem (`mapgen_example` above), not after the save basename. Resolve every discrepancy; do not stop at plausible-looking source.
7. Re-run comparison after cleanup or integration edits. If the map is registered in tutorials or gameplay, run the relevant package checks and the display-enabled application smoke test, or report why those checks were not run.

## Success criteria

The work is complete only when:

- the save loads without fallback or partial-load ambiguity;
- the generator is maintainable and follows current project conventions;
- ship, component, pipe, and surface ownership is preserved;
- saved component and pipe runtime values are preserved in immutable behaviours;
- the comparator exits successfully and every printed comparison category passes;
- omitted runtime state has been reviewed separately where relevant; and
- the source save is not committed merely as a conversion by-product unless it is intentionally a fixture or asset.

Never weaken the comparator or replace exact saved values merely to make a mismatch disappear. Investigate current constructors and intended behaviour instead.
