# Map Comparison And Failure Diagnosis

The comparator checks whether a trusted generator reconstructs the saved map's construction state. It includes and executes the supplied Julia file in `Main`; never run it on untrusted source.

## Contents

- [Run the comparator](#run-the-comparator)
- [What a pass proves](#what-a-pass-proves)
- [Deliberate limitations](#deliberate-limitations)
- [Failure diagnosis](#failure-diagnosis)
- [Validation checklist](#validation-checklist)

## Run the comparator

From the repository root:

```shell
julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/compare_maps.jl \
  path/to/source_map.jld2 src/demo_maps/mapgen_source_map.jl
```

The generator file must define a top-level zero-argument function whose name equals the `.jl` file stem. `mapgen_source_map.jl` must therefore define `mapgen_source_map()`. The function must return a `GameMap`. A function hidden inside a module is not found.

Both scripts use `HexFlowPersistence.loadmap`. Missing files, incompatible saves, absent `stored_gamemap` data, and stored values of the wrong type are errors. There is no default-map fallback in this workflow.

Status 0 means every implemented required comparison passed. A mismatch, invalid generator result, include error, or load error exits 1.

## What a pass proves

Within a numeric tolerance of `1e-6`, the comparator requires:

- the exact set of ship names;
- component coordinates and ownership;
- component concrete type, rotation, and mirroring;
- recursively compared stored component fields, including immutable nested runtime values;
- current values exposed by component tunables;
- pipe coordinates, ownership, concrete type, stored fields, and tunables;
- surface coordinates and ownership;
- the order-independent multiset of all component/pipe circuit elements, including active state, element IDs, dependant IDs, endpoints, types, and values;
- the order-independent multiset of mapped component fluid declarations.

Types, symbols, booleans, coordinates, ownership tags, rotations, mirroring, element activity, connections, and IDs are exact. Floating-point stored fields, tunables, element values, and declaration values use the tolerance.

The recursive stored-state comparison is intentionally stronger than comparing only constructor-facing tunables. It catches state such as charge, seal/switch state, stored liquid identity, energy, rotor state, temperature, damage, stall/autodeactivation state, and constructor-derived thermal values when present in the current component representation.

Component and shipped pipe behaviour graphs are immutable by contract, so identical templates may be reused directly across placements. The comparator checks their complete saved values; runtime state must still be reconstructed.

Elements and declarations are compared as multisets rather than by dictionary iteration order. This detects duplicates without requiring generators to preserve insertion order.

## Deliberate limitations

A passing result is not whole-`GameMap` equality and not a gameplay simulation proof. The comparator deliberately does not compare:

- `ShipState.docking_status` or docking render offsets;
- `space_map`, manoeuvre, encounter, velocity, or galaxy-escape state;
- `learning_system`;
- playthrough statistics;
- time-lapse history;
- derived fluid propagation, region temperatures, filtered circuit state, or solved MNA results; or
- source-code quality, constructor intent, comments, or maintainability.

The generated map receives ordinary constructor defaults for omitted top-level state unless the generator adds it deliberately. Validate any requested omitted state separately using current APIs and relevant tests.

Full stored-state equality and fluid declarations substantially reduce the old risk of a structural match with different gameplay, but future behaviour may depend on external/global state or newly added derived semantics. If gameplay still differs, inspect current component APIs and run the appropriate package/application checks.

## Failure diagnosis

### Save load failed

- Confirm the path exists and ends in `.jld2` (case-insensitive).
- Confirm the file contains `stored_gamemap` and was produced by a compatible Rocket Plumber version.
- Inspect `local_packages/HexFlowPersistence/src/migrations.jl` when an older save type cannot be reconstructed.
- Let `loadmap` errors propagate; do not substitute an empty map after failure.

### Function not found or invalid generator name

- Match the function to the generator file stem, not the save basename.
- Use a stem beginning with `mapgen_` that is a valid Julia identifier.
- Define it at top level in `Main`, not only inside a module.
- Renaming the file requires renaming the function.

### Include, constructor, or execution error

- Inspect the current constructor rather than copying an old generator blindly.
- Confirm the expression uses types imported by the skill's application component-loading context.
- Replace stale internal `repr` construction with current public constructors where practical.
- Confirm the function returns a `GameMap`, not a `ShipBlueprint`, `ShipState`, or `nothing`.

### Ship, ownership, or surface mismatch

- Compare the exact ship-name set first, including metadata-only ships.
- Check component and pipe owner tags at the reported global coordinates.
- Check `surface_shiptags` independently; do not infer surface from component presence.
- For multi-ship maps, construct `:primary` with `GameMap(primary_blueprint)` and merge each other blueprint under its exact symbol.
- Preserve intentional off-surface nozzles.

### Component or pipe mismatch

- Compare coordinate, owner, concrete type, rotation, and mirror state.
- Compare current public-constructor output with the encoder's stored representation.
- Check all tunables and nested runtime state, not just values visible in application constants.
- For pipes, confirm the complete canonical `PipeCoord`; a nearby or visually similar span is different.

### Stored-state mismatch

- Read the reported field path from the outer behaviour to the differing nested value.
- Check charge/energy/current-temperature values and boolean seal, switch, stall, damage, or activation state.
- For liquid tanks, compare the runtime stored-fluid identity as well as nominal constructor fluid.
- For public constructors with derived defaults, pass explicit thermal or timing values if the save differs from current defaults.
- If the save represents evolved runtime state, a clean constructor plus deliberate state setup may be necessary.

### Circuit element mismatch

Check:

- external versus internal node selection;
- rotation and mirroring;
- conductance, source, and dependant-source values;
- active/inactive state;
- element index/order within a component when IDs or dependant IDs differ; and
- wrapper constructors that transform connections or defaults.

The switched-nozzle `connected_node` mistake is canonical: type and high-level tunables may look plausible while element endpoints are wrong.

### Fluid declaration mismatch

Check:

- the external node supplied to nozzles, tanks, pumps, valves, and chambers;
- component rotation and mirroring, which map relative nodes to absolute nodes;
- fixed versus runtime stored fluid identity;
- positive versus empty liquid charge, which can change a source declaration into a liquid constraint; and
- constructor defaults that select gas/liquid type rules.

### Comparison passes but gameplay differs

Inspect concerns outside comparator scope: docking, learning, space-map state, statistics, time-lapse data, derived propagation, temperatures, solver filtering/results, and any external state used by new component behaviour. Run the affected package tests and real application smoke test where appropriate.

## Validation checklist

- The strict loader accepted the intended save.
- The called function name matches the generator filename.
- The generator returned a `GameMap`.
- Ship names and all count summaries match.
- There are no component, pipe, state, surface, element, or declaration discrepancies.
- Omitted top-level runtime state was reviewed separately.
- The comparator was rerun after final cleanup and integration edits.
