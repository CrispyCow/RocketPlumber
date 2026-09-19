# Map Encoding And Code Generation Guide

Use this procedure to convert a saved JLD2 `GameMap` into maintainable Julia
source. It is deliberately detailed: map conversion crosses persistence,
component constructors, mutable behaviour state, ship ownership, and circuit
generation, and a structurally plausible generator can still be wrong.

Read the repository and `tools/` `AGENTS.md` files before starting. When the
result will live under `src/demo_maps/`, also read `src/AGENTS.md`.

## Scope And Prerequisites

Run commands from the repository root with the root project:

```shell
julia --project=. tools/map_encoder/encode_map.jl path/to/source_map.jld2
```

The input must be an existing path ending in lowercase `.jld2`. The scripts do
not resolve bare map names through a `maps/` directory.

The current package dependency chain initialises GLFW while loading component
packages. Both scripts therefore need a working display/OpenGL environment;
they are not currently headless utilities.

Only run the comparator on a generator file you trust. It uses `include` and
executes that file as Julia code in `Main`.

## 1. Load And Inspect The Save

Start with the readable encoder output:

```shell
julia --project=. tools/map_encoder/encode_map.jl path/to/source_map.jld2
```

To retain the listing, provide a non-`.jl` output path:

```shell
julia --project=. tools/map_encoder/encode_map.jl \
  path/to/source_map.jld2 /tmp/source_map.txt
```

The parent directory for a text output must already exist. The encoder always
prints the readable listing to stdout, even when it also writes a file.

The listing contains, per ship:

- placed component coordinates and their stored representations;
- rotations, mirror flags, and ownership tags;
- pipe coordinates and stored behaviours;
- owned surface tiles.

It resembles Julia constructors but is a diagnostic listing, not an
executable `GameMap` expression.

### Confirm That Loading Really Succeeded

Both tools use the application's canonical loader in `src/map_loading.jl`, so
older saves benefit from the current JLD2 conversion hooks. The loader also
catches load failures, emits a warning, and returns a default `GameMap`.

Do not continue merely because the command exited normally. Check for messages
such as `Map load failed; returning empty`, then sanity-check:

- the expected ship names;
- approximate component and pipe counts;
- the expected surface extent;
- a few distinctive component types and coordinates.

A conversion of the fallback map can look valid while containing only default
state.

### Check The Input Basename

The input basename determines the required function name. For:

```text
path/to/cold_gas_intro.jld2
```

the generator must define:

```julia
function mapgen_cold_gas_intro()
    # ...
end
```

The basename is not aggressively sanitised. Rename the save before conversion
if the suffix after `mapgen_` would not be a valid Julia identifier.

## 2. Understand What Is And Is Not Encoded

The encoder reconstructs the ship construction data:

- ship names;
- components, pipes, and surface tiles;
- component rotation and mirroring;
- component, pipe, and surface ownership.

It does not reconstruct these `GameMap` concerns:

- `ShipState.docking_status`;
- `space_map`, including velocity, manoeuvre, encounter, and galaxy-escape
  state;
- `learning_system`;
- playthrough `statistics`;
- time-lapse history stored beside a map.

Generated maps receive the defaults used by `GameMap(blueprint)` and
`merge_ship!`: connected docking state, an empty space map, no learning system,
and fresh statistics. Time-lapse history is not part of the generated
`GameMap` and is simply omitted. Tutorial learning configuration normally
belongs in `src/tutorials.jl`, not in the map generator.

If any omitted state matters to the intended result, plan and validate that
integration separately. The comparator does not cover it.

## 3. Choose An Authoring Path

### Manual Authoring

Prefer manual authoring for small tutorial and showcase maps, or whenever the
saved representation can be expressed cleanly with current public
constructors. This gives useful names, comments, and constructor intent rather
than preserving internal fragment layout mechanically.

Good current references include:

- `src/demo_maps/mapgen_basicplumbing.jl` for a small single-ship map;
- `src/demo_maps/mapgen_controllingcoldgas.jl` for repeated stateful
  components;
- `src/demo_maps/mapgen_liquidtransfer.jl` for multiple ships;
- `src/demo_maps/mapgen_teasership.jl` for a large generated map.

### Direct Generation

For a large proc-generated map or one with many unique runtime values, emit a
Julia starting point:

```shell
julia --project=. tools/map_encoder/encode_map.jl \
  path/to/source_map.jld2 mapgen_source_map.jl
```

A bare `.jl` filename is written under `src/demo_maps/`. A path such as
`generated/mapgen_source_map.jl` is used as written and its parent directories
are created. The function name still comes from the input save, not the output
filename.

Direct output serialises component and pipe behaviours with `repr`. It favours
reconstruction over readability and may expose internal fragments. First
compare the untouched output. Then clean it up in small steps, comparing after
each semantic edit.

Do not choose between these paths by a rigid component count. Consider how
many distinct constructors and mutable states need to be reconstructed and
whether the resulting source will remain understandable.

## 4. Verify Constructors From Current Source

Encoded output shows stored structure; it does not tell you which public
constructor originally produced that structure. Wrapper and fragment
constructors may transform their inputs.

For every component type used in a manually authored generator:

1. Find a current application instance or map example in `src/components.jl`
   and `src/demo_maps/`.
2. Find the constructor in the relevant package under
   `local_packages/components/`.
3. Read the package tests for state and edge-case semantics.
4. Map the saved fields back to constructor arguments.
5. Confirm the result with the comparator; do not rely on type and coordinate
   agreement alone.

Useful implementation packages are:

- `HexFlowBasicComponents` for shared fragments;
- `HexFlowTankComponents` for gas, liquid, and pressure-fed tanks;
- `HexFlowNozzleComponents` for nozzles and chambers;
- `HexFlowPumpComponents` for turbopumps and electric pumps;
- `HexFlowSwitchComponents` for switches and valves;
- `HexFlowBasicPipes` for built-in pipe behaviours.

### Current Tank Example

Thevenin tanks take a fragment type, the supported connection count, and
keyword parameters:

```julia
gas_tank = ThevininTankCompBehav(
    GasTankBehavFrag,
    3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 200.0,
    max_voltage = 50.0,
    initial_charge = 150.0,
    series_conductance = 5.0,
)
```

Do not assume application constants have the same stored values as the save.
For example, `TriGasTank` is a particular configured instance, not a type.

### Switched-Nozzle Connection Trap

For the current switched nozzle constructor, `connected_node` is the external
node that connects to the ship's pipe network:

```julia
switched_nozzle = SwitchedNozzleCompBehav(
    throat_area = 0.2,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
    limit_temperature_k = 400.0,
)
```

The constructor creates a switch from that external node to
`HexFrame.NODE_INTERNAL_1` and a nozzle from the internal node to ground. Do
not pass `NODE_INTERNAL_1` as `connected_node`. A wrong value can produce the
right component type and tunables while creating the wrong circuit topology.

### Pressure-Fed Tank State

A pressure-fed tank with initial liquid must also identify that liquid:

```julia
pressure_fed_tank = PressureFedTankCompBehav(
    PressureFedTankBehavFrag(
        initial_liquid_charge = 150.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        initial_gas_charge = 0.0,
        max_liquid_charge = 200.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = HexFluids.MONOPROP_LIQUID,
    ),
    (HexFrame.NODE_Q_NEG,),
    5.0,
    HexFluids.COLD_GAS,
    NoRotationBehavFrag(),
)
```

Omitting `initial_liquid_fluid` while supplying positive liquid charge leaves
the stored liquid identity unset. This is an example of state that may not be
obvious from a high-level component name.

### Pipe Examples

Current built-in pipes accept either their default conductance or an explicit
value:

```julia
scrap_pipe = ScrapPipeBehav()      # 2.0 S
big_pipe = BigPipeBehav()          # 10.0 S
custom_pipe = ScrapPipeBehav(5.0)  # 5.0 S
```

Verify these defaults against `HexFlowBasicPipes` when future code changes
them; generated output should preserve the saved value explicitly where
necessary.

## 5. Build A Single-Ship Map

`ShipBlueprint()` starts with empty component, pipe, and surface collections.
Populate the blueprint, then construct the primary map with
`GameMap(blueprint)`.

```julia
"""Create a small map used to demonstrate gas storage."""
function mapgen_gas_storage_example()
    blueprint = ShipBlueprint()

    gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag,
        3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200.0,
        max_voltage = 50.0,
        initial_charge = 150.0,
        series_conductance = 5.0,
    )

    blueprint.components[TileCoord(0, 0)] =
        PlacedComponent(gas_tank, HexFrame.Q_POS, :_blueprint)

    push!(blueprint.ship_tiles, TileCoord(0, 0))

    gamemap = GameMap(blueprint)
    return gamemap
end
```

Blueprint component ownership is provisional. Use `:_blueprint` in
`PlacedComponent`; `GameMap(blueprint)` and `merge_ship!` replace it with the
destination ship name. To preserve mirroring, use the four-argument form:

```julia
PlacedComponent(component, HexFrame.R_NEG, true, :_blueprint)
```

Blueprint pipe dictionaries contain raw `PipeBehavior` values, not
`PlacedPipe` wrappers:

```julia
pipe_coord = PipeCoord(
    VertexCoord(TileCoord(0, 0), HexFrame.Q_POS),
    VertexCoord(TileCoord(0, 0), HexFrame.R_NEG),
)
blueprint.pipe_behaviors[pipe_coord] = ScrapPipeBehav()
```

The `PipeCoord` constructor canonicalises its endpoints and rejects invalid
geometry. Valid built-in render spans include side, short-diagonal, and
long-diagonal spans. Copy coordinates exactly from the encoded listing unless
the map design is intentionally changing.

## 6. Keep Stateful Placements Independent

Many component behaviours are immutable outer structs containing mutable
state. Reusing one instance can make interacting with one tile change another
tile.

This is unsafe for a stateful component:

```julia
nozzle = SwitchedNozzleCompBehav(
    throat_area = 0.2,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
)

blueprint.components[TileCoord(1, 0)] =
    PlacedComponent(nozzle, HexFrame.Q_NEG, :_blueprint)
blueprint.components[TileCoord(1, -1)] =
    PlacedComponent(nozzle, HexFrame.Q_NEG, :_blueprint)
```

Use fresh construction for a few instances or a template plus `deepcopy` for
repetition:

```julia
nozzle_template = SwitchedNozzleCompBehav(
    throat_area = 0.2,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
)

blueprint.components[TileCoord(1, 0)] =
    PlacedComponent(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)
blueprint.components[TileCoord(1, -1)] =
    PlacedComponent(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)
```

Apply the same caution to application constants such as `TriGasTank`,
`TurboPump`, and `LargeAdjValve`. Treat a constant as a reference
configuration; use `deepcopy` or a fresh constructor for each stateful
placement.

The comparator's identity check is a backstop, not permission to reuse
instances until it complains. It skips `isbitstype` values, conservatively
flags other shared objects, and permits generated sharing when it also detects
sharing somewhere in the original map. It does not compare the two maps'
complete aliasing graphs.

## 7. Respect Placement And Ownership Semantics

The generic component placement rule requires a surface tile, but specialised
components may override it. Nozzles deliberately sit off the ship surface with
their external input node touching the owning ship's surface.

Consequently, do not “repair” an encoded off-surface nozzle by adding its tile
to `ship_tiles`. Preserve the original surface and verify the nozzle's
`connected_node`, rotation, and mirrored state together.

The six rotations are:

```julia
HexFrame.Q_POS
HexFrame.R_NEG
HexFrame.S_POS
HexFrame.Q_NEG
HexFrame.R_POS
HexFrame.S_NEG
```

Coordinates use these forms:

```julia
TileCoord(q, r)
VertexCoord(TileCoord(q, r), HexFrame.Q_POS)
PipeCoord(vertex_1, vertex_2)
```

Within a live `GameMap`, component, pipe, and surface dictionaries are global
and ownership is carried by tags. Within a `ShipBlueprint`, component tags are
provisional and pipes are unwrapped. Let `GameMap(blueprint)` and `merge_ship!`
perform the final retagging.

## 8. Build Multi-Ship Maps Correctly

Construct the primary ship first, then merge additional blueprints:

```julia
function mapgen_two_ship_example()
    primary_blueprint = ShipBlueprint()
    push!(primary_blueprint.ship_tiles, TileCoord(0, 0))

    secondary_blueprint = ShipBlueprint()
    push!(secondary_blueprint.ship_tiles, TileCoord(4, 0))

    gamemap = GameMap(primary_blueprint)
    merge_ship!(gamemap, :secondary, secondary_blueprint)
    return gamemap
end
```

Do not start with `GameMap()` and then call
`merge_ship!(gamemap, :primary, primary_blueprint)`: the default map already
contains `:primary`, so the merge is rejected.

`merge_ship!` also rejects collisions with existing component, pipe, or
surface coordinates. Different ships still occupy the same global coordinate
space.

Direct multi-ship generation assumes the source map has a `:primary` ship.
Ship names are preserved with `Symbol(...)`; local variable names are derived
from sanitised ship names. Review unusual ship names because distinct names
such as `A-B` and `A_B` can produce the same local variable suffix.

The direct generator does not preserve docking statuses. If a particular
status matters, add it deliberately using the current `merge_ship!` interface
and validate it separately because the comparator does not check it.

## 9. Clean Up Directly Generated Code

First compare the untouched generated file. Once it passes, improve it without
changing its meaning:

1. Add a short docstring describing the map and, for tutorials, the learning
   objective.
2. Add clear sections for each ship.
3. Group components by role or type, followed by pipes and surface tiles.
4. Add brief comments for non-obvious topology or constructor choices.
5. Preserve constructor arguments and saved values exactly during the first
   cleanup pass.
6. Do not replace repeated constructor expressions with one shared stateful
   instance. Use a verified template plus `deepcopy`.
7. Do not replace an emitted constructor with an application constant unless
   its type, tunables, internal state, and produced elements are equivalent.
8. Re-run the comparator after every semantic edit.

Reordering independent dictionary assignments is normally safe. Be more
cautious when consolidating constructors, changing ownership, or altering
surface coordinates.

## 10. Compare Against The Save

Run:

```shell
julia --project=. tools/map_encoder/compare_maps.jl \
  path/to/source_map.jld2 src/demo_maps/mapgen_source_map.jl
```

The generator file must define a top-level, zero-argument
`mapgen_<source_basename>()` in `Main` and return a `GameMap`. A function hidden
inside another module is not found.

The comparator checks:

- component and pipe coordinates and owner tags;
- component concrete type, rotation, mirroring, and the current values exposed
  by `get_tunables`;
- pipe concrete type and values exposed by `get_pipe_tunables`;
- surface coordinates and ownership;
- the order-independent multiset of active `AbsoluteElement`s, comparing
  element type, endpoints, dependant ID, and value;
- potentially unsafe shared component and pipe instances.

Numeric tunables and element values use a tolerance of `1e-6`. Types,
coordinates, owner tags, rotations, mirroring, connections, and dependant IDs
are exact.

### Comparator Limitations

Passing comparison means the implemented structural and active-electrical
checks passed. It is not complete `GameMap` equality.

The comparator does not check:

- docking status, `space_map`, `learning_system`, statistics, or time-lapse;
- fluid declarations, propagated fluids, temperatures, or solved MNA results;
- inactive circuit elements;
- `AbsoluteElement.id` or element ordering;
- arbitrary component or pipe fields not exposed through tunables or active
  elements;
- an exact match between the original and generated object-aliasing graphs.

It reports the ship-name sets, but the current `perfect_match` calculation does
not independently require `ship_names_match`. Components, pipes, and surfaces
normally reveal ownership differences, but an extra or missing metadata-only
empty ship can escape the final status. Inspect the printed ship summary rather
than relying only on exit status.

The loader fallback described earlier applies here as well. Two fallback maps
could appear to match after failed loading, so warnings and map counts are part
of validation.

Status 0 means all implemented checks passed. Any detected mismatch or caught
tool error exits 1; the exit code does not distinguish those cases.

## 11. Interpret Failures

### Function Not Found

- Confirm the generator function uses the input save's basename.
- Confirm the basename forms a valid Julia identifier.
- Define the function at top level rather than only inside a module.
- Remember that renaming the output `.jl` file does not rename the expected
  function.

### Constructor Or Include Error

- Inspect the current constructor definition rather than copying an old guide
  or reverse-engineering internal fragments blindly.
- Confirm all component packages needed by the expression are available in
  the tool's loading context.
- Check whether a generated `repr` refers to an internal type whose
  construction has changed.

### Component Or Pipe Mismatch

- Compare the owner, coordinate, concrete type, rotation, and mirror flag.
- Compare every exposed tunable in the order returned by the current API.
- For pipes, confirm the complete `PipeCoord`; canonical endpoint order does
  not make a different span equivalent.

### Shared References

- Create a fresh behaviour per placement or `deepcopy` a verified template.
- Check nested mutable fragments even when the outer component type is
  immutable.
- Treat a pass as a heuristic result because the identity check has the
  limitations described above.

### Circuit Element Mismatch With Matching Structure

This usually indicates a semantically wrong constructor argument or internal
state. Check:

- external versus internal node selection;
- component rotation and mirroring;
- conductance, source, and dependant-source values;
- wrapper constructors that transform inputs;
- whether the relevant elements are active.

The switched-nozzle `connected_node` mistake is the canonical example: the
component type and tunables can look plausible while its circuit endpoints are
wrong.

### Structural Match But Different Gameplay

Inspect data outside comparator scope: fluid declarations, stored fields not
exposed as tunables, docking, learning, space-map state, statistics, derived
fluid state, and solver results. Use the affected package tests and a real
application smoke test where appropriate.

## 12. Integrate The Generator

Maintainable project generators belong under `src/demo_maps/`. When the game
should expose a new tutorial or showcase map:

1. include the generator through the current helper near the top of
   `src/tutorials.jl`;
2. add or update the corresponding `LearningEntry` or other registration;
3. keep learning-system configuration in `src/tutorials.jl`;
4. preserve Australian English in comments, docstrings, and tutorial prose;
5. run the comparison again after integration;
6. run relevant package tests and the display-enabled application smoke test
   when gameplay integration changed.

Do not commit the source JLD2 save merely as a conversion by-product unless it
is intended to remain a fixture or project asset.

## Final Checklist

- The loader produced the expected ships and approximate map size without a
  fallback warning.
- The generator name exactly matches the input basename.
- Every manual constructor was checked against current source.
- Stateful placements use distinct instances.
- Component rotation, mirroring, ownership, and pipe coordinates match.
- Surface ownership is preserved, including intentional off-surface nozzles.
- Multi-ship coordinates do not collide and `:primary` is constructed first.
- Omitted runtime state has been reviewed separately.
- The comparator's printed ship summary and all mismatch sections are clean.
- The generator has a useful docstring and comments without hiding exact
  constructor intent.
- Integration and display-dependent checks were run or explicitly reported as
  not run.
