# Map Reconstruction Guide

This guide covers the domain knowledge needed to turn a saved JLD2 `GameMap` into maintainable Julia source. Map reconstruction crosses persistence, component constructors, mutable behaviour state, ship ownership, placement rules, and circuit/fluid generation. A generator can look structurally convincing while still being wrong.

## Contents

- [Inspect the save safely](#inspect-the-save-safely)
- [Define the reconstruction boundary](#define-the-reconstruction-boundary)
- [Choose manual authoring or a generated draft](#choose-manual-authoring-or-a-generated-draft)
- [Verify current constructors](#verify-current-constructors)
- [Build a single-ship map](#build-a-single-ship-map)
- [Keep stateful placements independent](#keep-stateful-placements-independent)
- [Respect placement and ownership](#respect-placement-and-ownership)
- [Build multi-ship maps](#build-multi-ship-maps)
- [Clean up generated source](#clean-up-generated-source)
- [Integrate the generator](#integrate-the-generator)
- [Final reconstruction checklist](#final-reconstruction-checklist)

## Inspect the save safely

Run from the repository root:

```shell
julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/encode_map.jl path/to/source_map.jld2
```

The input must be an existing path with a `.jld2` extension. Bare map names are not resolved through `maps/`.

The readable listing contains, per ship:

- placed component coordinates and stored representations;
- rotations, mirror flags, and ownership tags;
- pipe coordinates and stored behaviours; and
- owned surface tiles.

It resembles Julia constructors but is diagnostic text, not an executable `GameMap` expression. Redirect stdout or provide a non-`.jl` output path when a retained listing is useful.

The skill scripts load with the application's JLD2 upgrade typemap but fail hard on missing, malformed, incompatible, or non-`GameMap` data. A successful command therefore cannot be the application's normal empty-map fallback. Still sanity-check the expected ship names, approximate counts, surface extent, and several distinctive component types and coordinates: a valid but unintended save is still the wrong input.

### Generator naming

The generator filename determines the function name. For:

```text
src/demo_maps/mapgen_cold_gas_intro.jl
```

define a top-level function named:

```julia
function mapgen_cold_gas_intro()
    # ...
end
```

The save basename does not need to match. This permits a working save such as `cold_gas_intro_v4.jld2` to produce the stable project API `mapgen_cold_gas_intro`.

Use a `.jl` filename whose stem starts with `mapgen_` and is a valid Julia identifier. The encoder and comparator reject ambiguous names rather than guessing.

## Define the reconstruction boundary

The normal map generator reconstructs ship construction state:

- ship names;
- components, pipes, and surface tiles;
- component rotation and mirroring;
- component, pipe, and surface ownership; and
- the stored behaviour state required for the reconstructed components and pipes to match.

It deliberately does not reconstruct these top-level `GameMap` concerns:

- `ShipState.docking_status`;
- `space_map`, including velocity, manoeuvre, encounter, and galaxy-escape state;
- `learning_system`;
- playthrough `statistics`; or
- time-lapse history stored beside the map.

Generated maps normally receive the defaults established by `GameMap(blueprint)` and `merge_ship!`: connected docking state, an empty space map, no learning system, and fresh statistics. Tutorial learning configuration belongs in `src/tutorials.jl`, not in the map generator. Time-lapse history is not part of the generated `GameMap`.

If omitted state matters to the requested result, handle and validate it as a separate integration concern. Do not assume a passing construction comparison covers it.

## Choose manual authoring or a generated draft

### Manual authoring

Prefer manual authoring for small tutorial/showcase maps or when the saved representation maps cleanly to current public constructors. It produces constructor intent, useful names, and maintainable grouping rather than preserving implementation fragments.

Current references include:

- `src/demo_maps/mapgen_basicplumbing.jl` for a small single-ship map;
- `src/demo_maps/mapgen_controllingcoldgas.jl` for repeated stateful components;
- `src/demo_maps/mapgen_pressurefedintro.jl` for liquid and pressure-fed tank construction;
- `src/demo_maps/mapgen_liquidtransfer.jl` for multiple ships; and
- `src/demo_maps/mapgen_teasership.jl` for a large, grouped map.

Treat these as style and API examples, not as substitutes for comparing against the save; an existing generator may itself have drifted.

### Direct generation

For a large proc-generated map or one with many unique runtime values, emit a starting point:

```shell
julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/encode_map.jl \
  path/to/source_map.jld2 /tmp/mapgen_source_map.jl
```

A bare `.jl` filename is placed under `src/demo_maps/`; a path with a directory is used as written. Prefer `/tmp` for exploratory output so mechanical code does not overwrite maintained source before review.

Direct output serialises stored component and pipe behaviours with `repr`. It favours reconstruction fidelity over readability and may expose internal fragments. Compare the untouched draft first. Then replace internal construction with verified public constructors, consolidate repetition safely, and compare after each semantic edit.

Do not choose between manual and direct authoring by a rigid component count. Consider the number of distinct constructors, mutable states, ownership groups, and whether direct output will remain understandable after cleanup.

## Verify current constructors

Encoded output shows stored structure. It does not reveal which public constructor produced that structure, and wrappers or fragment constructors may transform their inputs.

For each component type used in maintained source:

1. Find current application instances in `src/components.jl` and nearby generators in `src/demo_maps/`.
2. Find the public constructor in the appropriate package under `local_packages/components/`.
3. Read relevant package tests for state and edge-case semantics.
4. Map saved fields back to constructor arguments.
5. Confirm stored state, elements, and fluid declarations with the comparator.

Useful implementation packages are:

- `HexFlowBasicComponents` for shared state, rotation, rendering, and stall fragments;
- `HexFlowTankComponents` for gas, liquid, and pressure-fed tanks;
- `HexFlowNozzleComponents` for nozzles and chambers;
- `HexFlowPumpComponents` for turbopumps and electric pumps;
- `HexFlowSwitchComponents` for switches and valves; and
- `HexFlowBasicPipes` for built-in pipe behaviours.

Application names such as `TriGasTank`, `TurboPump`, and `LargeAdjValve` are configured instances, not types. Their present values may differ from the save.

### Thevenin tank example

The project type retains its established spelling, `ThevininTankCompBehav`. Its public constructor takes a fragment type, supported connection count, and keyword parameters:

```julia
gas_tank = ThevininTankCompBehav(
    GasTankBehavFrag, 3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 200.0,
    max_voltage = 50.0,
    initial_charge = 150.0,
    series_conductance = 5.0,
)
```

For `LiquidTankBehavFrag`, a positive `initial_charge` seeds the stored liquid identity from `fluid`; an empty tank instead has no stored liquid identity. Verify both charge and fluid identity rather than matching only capacity and voltage.

### Basic and switched nozzle node traps

For basic and switched nozzle constructors, `connected_node` is the external node connected to the pipe network:

```julia
nozzle = SwitchedNozzleCompBehav(
    throat_area = 0.2,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
    limit_temperature_k = 400.0,
)
```

The switched constructor creates a switch from that external node to `NODE_INTERNAL_1` and a nozzle from the internal node to ground. Do not pass `NODE_INTERNAL_1` as `connected_node`. A wrong value can preserve type and visible tunables while changing circuit topology and fluid declarations.

Nozzle constructors also derive overheat defaults from throat area unless explicit thermal values are supplied. When reconstructing a save with non-default temperature limit, thermal mass, heat-loss factor, damage, or current temperature, verify that the public constructor and any deliberate state setup reproduce the stored state.

### Pressure-fed tank state

A pressure-fed tank with positive initial liquid charge must identify that liquid:

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

Omitting `initial_liquid_fluid` with positive charge leaves the stored liquid identity unset. Also preserve gas/liquid seal state, force-reactivation state, charges, nodes, and rotation behaviour when the save is not at constructor defaults.

### Pumps, valves, and other stateful wrappers

Pumps and valves commonly combine immutable outer wrappers with mutable energy, rotor, delayed-drive, switch, temperature, stall, or damage state. Matching public constructor arguments may not reproduce a save captured after interaction or simulation. Inspect the stored representation and current package tests; use explicit current constructors plus deliberate state construction only when needed.

### Pipe examples

Built-in pipes accept their default conductance or an explicit saved value:

```julia
scrap_pipe = ScrapPipeBehav()      # 2.0 S currently
big_pipe = BigPipeBehav()          # 10.0 S currently
custom_pipe = ScrapPipeBehav(5.0)  # 5.0 S
```

Use explicit values when preserving a non-default save. Recheck defaults in `HexFlowBasicPipes`; the comments above are current guidance, not an API guarantee.

## Build a single-ship map

`ShipBlueprint()` starts with empty component, pipe, and surface collections. Populate it, then construct the primary map with `GameMap(blueprint)`:

```julia
"Create a small map demonstrating cold-gas storage."
function mapgen_gas_storage_example()
    blueprint = ShipBlueprint()

    gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200.0,
        max_voltage = 50.0,
        initial_charge = 150.0,
        series_conductance = 5.0,
    )

    blueprint.components[TileCoord(0, 0)] =
        PlacedComponent(gas_tank, HexFrame.Q_POS, :_blueprint)
    push!(blueprint.ship_tiles, TileCoord(0, 0))

    return GameMap(blueprint)
end
```

Blueprint component ownership is provisional. Use `:_blueprint`; `GameMap(blueprint)` and `merge_ship!` retag components and wrap pipes with the destination ship name. Preserve mirroring with the four-argument placement form:

```julia
PlacedComponent(component, HexFrame.R_NEG, true, :_blueprint)
```

Blueprint pipe dictionaries contain raw `PipeBehavior` values, not `PlacedPipe` wrappers:

```julia
pipe_coord = PipeCoord(
    VertexCoord(TileCoord(0, 0), HexFrame.Q_POS),
    VertexCoord(TileCoord(0, 0), HexFrame.R_NEG),
)
blueprint.pipe_behaviors[pipe_coord] = ScrapPipeBehav()
```

`PipeCoord` canonicalises endpoints and rejects invalid geometry. Valid built-in render spans include side, short-diagonal, and long-diagonal spans. Copy endpoints exactly from the listing unless the design is intentionally changing; visually similar spans are not equivalent.

## Keep stateful placements independent

Many behaviours are immutable outer structs containing mutable nested state. Reusing one instance can make interaction with one tile mutate another tile.

This is unsafe:

```julia
blueprint.components[TileCoord(1, 0)] =
    PlacedComponent(nozzle_template, HexFrame.Q_NEG, :_blueprint)
blueprint.components[TileCoord(1, -1)] =
    PlacedComponent(nozzle_template, HexFrame.Q_NEG, :_blueprint)
```

Use fresh construction or a verified template plus `deepcopy`:

```julia
blueprint.components[TileCoord(1, 0)] =
    PlacedComponent(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)
blueprint.components[TileCoord(1, -1)] =
    PlacedComponent(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)
```

Apply the same rule to stateful application constants. Treat constants as reference configurations, not reusable placement objects. Stateless isbits pipe behaviours may be shared safely, but fresh pipe constructors are usually clearer.

The comparator recursively looks through immutable wrappers for mutable nested objects and rejects generated placements that share them. This is a backstop; author independent state intentionally.

## Respect placement and ownership

The six rotations are:

```julia
HexFrame.Q_POS
HexFrame.R_NEG
HexFrame.S_POS
HexFrame.Q_NEG
HexFrame.R_POS
HexFrame.S_NEG
```

Coordinates use:

```julia
TileCoord(q, r)
VertexCoord(TileCoord(q, r), HexFrame.Q_POS)
PipeCoord(vertex_1, vertex_2)
```

Within a live `GameMap`, component and pipe dictionaries are global and ownership is stored in `PlacedComponent.ship` and `PlacedPipe.ship`; surface ownership is stored in `surface_shiptags`. `ships` contains per-ship metadata, not per-ship construction dictionaries.

Within a `ShipBlueprint`, component tags are provisional, pipe values are unwrapped, and `ship_tiles` contains only that blueprint's surface. Let `GameMap(blueprint)` and `merge_ship!` perform final retagging rather than manually writing live-map dictionaries.

The generic component rule requires a surface tile, but specialised components can override it. Nozzles deliberately occupy off-surface tiles with their external input node touching the owning ship's surface. Do not “repair” an encoded off-surface nozzle by adding its tile to `ship_tiles`. Preserve surface, connected node, rotation, mirror state, and owner together.

Do not infer surface ownership from nearby components or pipes. Copy the saved ownership tags, especially where ships are close or docked.

## Build multi-ship maps

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

Do not start with `GameMap()` and merge `:primary`: the default map already contains a primary ship and surface tile, so the merge is rejected or leaves unintended construction state.

`merge_ship!` rejects component, pipe, and surface collisions. Different ships share one global coordinate space. It retags component and pipe ownership and creates a `ShipState` with connected docking status unless another status is explicitly supplied.

Direct generation requires a source `:primary` ship and preserves other ship names with `Symbol(repr_string)`. Local blueprint names are sanitised from ship names; the encoder rejects collisions such as `A-B` and `A_B` rather than emitting invalid or ambiguous code.

Docking status is outside ordinary construction reconstruction. If a particular status matters, pass it through the current `merge_ship!` API or set it deliberately and validate it separately.

## Clean up generated source

First compare the untouched generated draft. Once it passes:

1. Add a short docstring describing the map and, for tutorials, its learning objective.
2. Group each ship separately, then group components by role/type, pipes, and surface tiles.
3. Replace internal fragment representations with current public constructors only after verifying equivalence.
4. Add brief comments for non-obvious topology or constructor choices.
5. Preserve saved constructor arguments and state during the first cleanup pass.
6. Consolidate repeated stateful components with a template plus `deepcopy`, never one shared instance.
7. Replace an emitted constructor with an application constant only when type, tunables, full stored state, elements, and fluid declarations match.
8. Re-run the comparator after each semantic batch.

Reordering independent dictionary assignments is normally safe. Consolidating constructors, changing ownership, modifying surfaces, or replacing coordinates deserves immediate comparison.

For large pipe networks, exact explicit assignments are often more maintainable than an abstraction that hides topology. Group by pipe type or map region when that helps review, but avoid generated-looking comments on every line.

## Integrate the generator

Maintained project generators normally belong in `src/demo_maps/`. Read `src/AGENTS.md` and follow the surrounding Julia style.

When the game should expose a new tutorial or showcase map:

1. include the generator through the current helper near the top of `src/tutorials.jl`;
2. add or update the corresponding `LearningEntry` or other registration;
3. keep learning-system configuration in `src/tutorials.jl`;
4. preserve Australian English in comments, docstrings, and tutorial prose;
5. compare the final integrated generator again; and
6. run relevant package tests and the display-enabled application smoke test when gameplay integration changed.

Do not commit the source JLD2 save merely as a conversion by-product unless it is intentionally retained as a fixture or project asset.

## Final reconstruction checklist

- The strict loader reported the expected ships and plausible map counts.
- The generator filename and top-level function name match exactly.
- Every manually expressed constructor was checked against current source and tests.
- Component stored state, including fluid identity and interaction/simulation state, is preserved.
- Stateful placements own distinct mutable state.
- Component rotation, mirroring, ownership, and pipe coordinates match.
- Surface coordinates and ownership match, including intentional off-surface nozzles.
- Multi-ship coordinates do not collide and `:primary` is constructed first.
- Omitted top-level runtime state has been reviewed separately.
- The comparator reports a complete match within its documented scope.
- The generator has useful structure and comments without hiding exact constructor intent.
- Integration and display-dependent checks were run or explicitly reported as not run.
