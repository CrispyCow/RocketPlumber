# FlowMap Guide

`FlowMap` owns the game-map domain model and map-level validation. It must stay
independent of calculator orchestration, rendering, UI, and concrete component
implementations.

## Ownership Model

- `GameMap.components` and `GameMap.pipe_behaviors` are global whole-map
  `TypeGroupedDict` stores. `ShipBlueprint` keeps ordinary build-time dictionaries.
  Component and pipe ownership is carried by
  `PlacedComponent.ship` and `PlacedPipe.ship`; surface ownership is carried by
  `surface_shiptags`.
- `ships` stores lightweight per-ship state such as docking status. It does not
  own per-ship component, pipe, or surface dictionaries.
- A galaxy-escape `pre_escape_map` checkpoint is permanently read-only after
  creation, including all nested state. Render snapshots may share it; consumers
  needing an independently mutable map must explicitly deep-copy it.
- A default `GameMap()` contains `:primary` and one primary surface tile at
  `TileCoord(0, 0)`. A `ShipBlueprint` is a detached construction payload and
  starts with empty collections.
- Repeated whole-map work uses `TypeGroupedDicts` traversal/replacement APIs;
  ordinary collection iteration is read-only. Collect keys before structural removal.
  Use `mapreducevalues` / `mapreducepairs` with an explicit `init` for scalar or
  structured totals. The bulk `set_component!` accepts ordinary dictionaries
  and grouped component collections, preserving each component's ship tag.
- Use the exported component, pipe, surface, ownership, and per-ship iteration
  helpers. Direct dictionary mutation easily bypasses ownership normalisation,
  placement checks, or cleanup.
- Use `ShipBlueprint` for generated/detached ships and `merge_ship!` to insert
  one into a live map. Component ownership tags inside a blueprint are
  provisional; merge retags components and wraps pipes with the destination
  ship name.

## Domain Boundaries

- Placement functions return `RequestStatus` values for expected invalid player
  actions. Reserve exceptions for broken invariants or programming errors.
- Keep docking transitions and render-offset state coherent. Moving ships may
  temporarily occupy transformed render positions while their stored tile
  coordinates remain authoritative.
- `AbstractSpaceMap` and its generic accessors live here. The encounter-capable
  `SpaceMapState` implementation lives in `HexFlowProcGen`; avoid importing that
  higher-level package back into `FlowMap`.
- Persistent learning types live here because they are saved in `GameMap`;
  tutorial definitions and render-thread learning flow live in
  `HexFlowLearningSystem`.

## Persistence And Tests

`GameMap`, ship/docking state, space-map values, learning progress, encounter
data, and playthrough statistics can all reach saved files. Any layout or type
identity change needs corresponding review of
`local_packages/HexFlowPersistence/src/migrations.jl` and an older-save fixture
when available.

Run:

```shell
julia --project=local_packages/FlowMap -e 'using Pkg; Pkg.test()'
```

Also run downstream calculator tests for changes to validation, docking,
ownership, or space-map interfaces.
