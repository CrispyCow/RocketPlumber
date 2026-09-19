# Map Encoder Tools

The map encoder turns a saved JLD2 `GameMap` into either a readable structural
listing or a Julia `mapgen_*` function. The comparator checks a generated map
against the save.

Run both scripts from the repository root with the root project. The current
dependency chain initialises GLFW while loading component packages, so these
tools require a working display/OpenGL environment even though they are
command-line programs.

## Typical Workflow

1. Inspect the saved map:

   ```shell
   julia --project=. tools/map_encoder/encode_map.jl path/to/source_map.jld2
   ```

2. Either author a clean generator from that listing or have the encoder emit
   a starting point:

   ```shell
   julia --project=. tools/map_encoder/encode_map.jl \
     path/to/source_map.jld2 mapgen_source_map.jl
   ```

3. Compare the result with the save:

   ```shell
   julia --project=. tools/map_encoder/compare_maps.jl \
     path/to/source_map.jld2 src/demo_maps/mapgen_source_map.jl
   ```

The detailed authoring and validation procedure is in
`map_encode_instructions.md`.

## Encoder Behaviour

The input must be an existing path ending in lowercase `.jld2`. Bare map names
are not resolved implicitly.

With no output argument, the encoder prints a readable per-ship listing of
components, pipes, rotations, mirroring, ownership, stored representations,
and surface tiles. This listing is diagnostic text, not executable Julia.

An optional output argument selects the output form:

```shell
# Write the readable listing; the parent directory must already exist
julia --project=. tools/map_encoder/encode_map.jl \
  path/to/source_map.jld2 path/to/encoded_map.txt

# Write a Julia generator
julia --project=. tools/map_encoder/encode_map.jl \
  path/to/source_map.jld2 mapgen_source_map.jl
```

A bare `.jl` filename is written under `src/demo_maps/`. A path such as
`generated/mapgen_source_map.jl` is honoured, and its parent directories are
created. The encoder still prints the readable listing to stdout when it
writes either kind of output file.

The generated function name comes from the input save's basename, not the
output filename. For `source_map.jld2`, the comparator expects a top-level
zero-argument function named `mapgen_source_map`. Use an input basename that
can form a valid Julia identifier.

## What Generated Code Preserves

Generated code reconstructs:

- ship names;
- component coordinates, concrete behaviours, rotations, mirroring, and
  ownership;
- pipe coordinates, concrete behaviours, and ownership;
- surface coordinates and ownership.

It does not reconstruct ship docking status, `space_map`, `learning_system`,
or playthrough `statistics`; those fields receive the defaults established by
`GameMap(blueprint)` and `merge_ship!` unless the generator is extended
manually. Time-lapse history is stored separately from the `GameMap` and is
simply omitted.

Both tools load through `src/map_loading.jl`, including its JLD2 upgrade hooks.
That loader warns and returns a default `GameMap` after a load failure. Always
read loader warnings and sanity-check the reported ships, components, pipes,
and surface tiles before trusting output.

## Comparator Scope

The comparator includes and executes the supplied generator file, so only run
it on code you trust. It checks the following within a numeric tolerance:

- component and pipe locations and ownership;
- component type, rotation, mirroring, and exposed tunable values;
- pipe type and exposed tunable values;
- ship-surface coordinates and ownership;
- active circuit elements produced by components and pipes;
- potentially unsafe shared component or pipe instances.

This is a structural and active-electrical equivalence check, not full
`GameMap` equality. It does not compare docking, space, learning, statistics,
time-lapse, fluid declarations, or every unexposed internal field. Exit status
0 means the implemented checks passed; a mismatch or tool error exits 1.

Generated tutorial maps normally live in `src/demo_maps/` and are included and
registered through `src/tutorials.jl`.
