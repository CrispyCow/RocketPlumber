# FlowMap Package Extraction Plan

## Overview

This document outlines the plan to extract map-related functionality from `FlowEngine` into a new `FlowMap` package. The goal is to:

1. **Separate concerns**: Keep MNA (Modified Nodal Analysis) calculation logic in `FlowEngine`, move map data structures and accessors to `FlowMap`
2. **Enable HexComponentsAPI to depend on FlowMap**: This allows `placement_valid` to have a properly typed `GameMap` parameter instead of the current workaround with a generic `surface` type

## Proposed Package Name

**`FlowMap`**

This name clearly indicates it handles the game map data structures while remaining consistent with the `Flow*` naming convention.

---

## Element Analysis

### Elements to MOVE to FlowMap

These are map data structures and accessors that have no MNA dependencies:

#### Core Types (Lines 49-167)
| Element | Type | Reason for Move |
|---------|------|-----------------|
| `RenderPosOffsetState` | struct | Ship render offset animation state - purely cosmetic/map concern |
| `DockingStatus` | abstract type | Docking state machine - map/ship management |
| `ConnectedDockStat` | struct | Docking status variant |
| `ApproachingDockStat` | struct | Docking status variant |
| `DepartingDockStat` | struct | Docking status variant |
| `ShipMap` | struct | **Core map data structure** - holds components, pipes, surfaces |
| `GameMap` | struct | **Core map data structure** - holds multiple ships |

#### ShipMap Abstraction Functions (Lines 204-303)
All `ShipMap` accessor functions:
- `get_component(ship::ShipMap, ...)`, `has_component`, `set_component!`, `delete_component!`
- `get_pipe(ship::ShipMap, ...)`, `has_pipe`, `set_pipe!`, `delete_pipe!`
- `get_all_components(ship::ShipMap)`, `get_all_pipes(ship::ShipMap)`
- `count_components(ship::ShipMap)`, `count_pipes(ship::ShipMap)`, `count_surface_tiles(ship::ShipMap)`
- `is_on_surface_tile(coord, ship::ShipMap)`, `set_surface_tile!`, `delete_surface_tile!`, `get_all_surface_tiles(ship::ShipMap)`
- `delete_all_components!(ship::ShipMap)`, `delete_all_pipes!(ship::ShipMap)`, `delete_all_surface_tiles!(ship::ShipMap)`

#### GameMap Abstraction Functions (Lines 305-548)
All `GameMap` accessor functions:
- `_get_ship`, `add_ship!`, `remove_ship!`, `get_all_ship_names`, `has_ship`, `get_ship`
- All GameMap overloads of ShipMap accessors (component, pipe, surface operations)
- Multi-ship query helpers: `has_component_any_ship`, `get_component_any_ship`, `has_pipe_any_ship`, `get_pipe_any_ship`, `is_on_surface_tile_any_ship`
- Batch operations: `delete_all_components!`, `delete_all_pipes!`, `delete_all_surface_tiles!`
- `placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ...)` - **Key function for HexComponentsAPI**

#### Bounds and Geometry Functions (Lines 549-654)
- `get_axial_bounds(tiles::AbstractSet{TileCoord})` and overloads for `ShipMap`, `GameMap`
- `get_cartesian_bounds(tiles::AbstractSet{TileCoord})` and overloads
- `get_surface_centroid(tiles::AbstractSet{TileCoord})` and overloads
- `get_all_surfaces_combined(gamemap::GameMap)`

#### Surface Edge Functions (Lines 656-698)
- `get_all_ship_edge_coords(derivedmapstate::DerivedMapState)` - **Note: References DerivedMapState**
- `count_edge_tiles(derivedmapstate::DerivedMapState)` - **Note: References DerivedMapState**
- `count_surfacetile_adjacencies`
- `find_ship_surface_edgetiles!(edgesurface, ship::ShipMap)`
- `find_ship_surface_edgetiles!(edgesurface, gamemap::GameMap)`
- `find_ship_surface_edgetiles!(derivedmapstate, gamemap)` - **Note: References DerivedMapState**

#### Placement Validation Functions (Lines 700-770)
- `is_node_on_ship_surface`
- `can_place_component_at`
- `can_place_pipe_at`
- `can_remove_surface_at`

#### Ship Helper Functions (Lines 772-870)
- `find_ship_for_surface`
- `find_ships_adjacent_to_coord`
- `would_bridge_ships`
- `find_valid_ship_for_placement`
- `find_ship_with_component`
- `find_ship_with_pipe`
- `offset_ship!`

#### Docking Functions (Lines 872-980)
- `get_ship_render_offset`
- `get_render_offset(ship::ShipMap)`
- `update_render_offset!(ship::ShipMap)`
- `get_docking_status`, `set_docking_status!`
- `update_docking!`
- `clear_all_docking_statuses!`
- `find_ship_for_node`

---

### Elements to KEEP in FlowEngine

These have MNA/electrical calculation dependencies:

#### State Types (Lines 168-201)
| Element | Type | Reason to Keep |
|---------|------|----------------|
| `DerivedMapState` | struct | Contains `prunedelements`, `prunednodes`, `nodeconnections`, `nodeprimefluidtags`, `nodeactualfluids` - all MNA-related |
| `MNA_State` | struct | Core MNA calculation state |
| `ConnectionVect` | const | Used in node connection mapping |

#### Helper Functions (Lines 982-1015)
- `add_or_increment!` - Used in MNA node counting
- `element_has_node` - Element inspection for MNA
- `element_other_node` - Element inspection for MNA
- `add_pipes_abs_element!` - Creates electrical elements

#### Component Update Functions (Lines 1017-1033)
- `update_components!(ship::ShipMap, mna_state::MNA_State)` - **Uses MNA_State**
- `update_components!(gamemap::GameMap, mna_state::MNA_State)` - **Uses MNA_State**

**Note**: These functions iterate over ShipMap/GameMap components but require MNA_State. They should stay in FlowEngine which will depend on FlowMap.

#### Element Listing Functions (Lines 1035-1097)
- `list_elements(ship::ShipMap)` - Collects electrical elements
- `list_elements(gamemap::GameMap)` - Aggregates electrical elements
- `list_nodes(elements::Vector{AbsoluteElement})` - MNA node listing

#### MNA Graph Algorithms (Lines 1099-1314)
- `prune(elements)` - Prunes dead electrical branches
- `build_node_connection_map!(derivedmapstate)` - Builds node graph for MNA
- `connect_fluidtags!(derivedmapstate)` - Propagates fluid tags through network
- `ground_search(elements)` - Graph traversal for grounded elements
- `clear_dangling_dependants(elements)` - Removes orphaned dependent sources
- `abs_element_get_current(element, derivedmapstate, mna_state)` - Gets current through element

#### Fluid Tag Functions (Lines 1360-1430)
- `get_tile_fluid_tag(ship::ShipMap, ...)` - Gets fluid from component
- `get_node_fluid_tags(node, ship::ShipMap)` - Node fluid query
- `get_node_fluid_tags(node, gamemap::GameMap)` - Multi-ship fluid query
- `fluidtag_nodes(derivedmapstate, gamemap)` - Assigns fluid tags

#### MNA Core Functions (Lines 1432-1786)
- `MNA_indexnodes`
- `is_resistor`, `is_csource`, `is_vsource`
- `MNA_splitelements!`
- `MNA_getA` - Builds A matrix
- `MNA_getZ` - Builds Z matrix
- `MNA_solve` - Solves MNA system

---

### Boundary Cases - Require Careful Handling

#### Functions That Reference Both Map and MNA Types

1. **`find_ship_surface_edgetiles!(derivedmapstate::DerivedMapState, gamemap::GameMap)`** (Line 693)
   - This overload writes to `DerivedMapState.ship_surface_edge`
   - **Recommendation**: Move the `Set{TileCoord}` and `ShipMap` overloads to `FlowMap`. Keep the `DerivedMapState` overload in `FlowEngine` (it just calls the Set version).

2. **`get_all_ship_edge_coords(derivedmapstate::DerivedMapState)`** (Line 658)
   - Simple accessor to DerivedMapState field
   - **Recommendation**: Keep in `FlowEngine` as it's a DerivedMapState accessor.

3. **`count_edge_tiles(derivedmapstate::DerivedMapState)`** (Line 661)
   - Simple accessor to DerivedMapState field
   - **Recommendation**: Keep in `FlowEngine`.

4. **`update_components!(ship/gamemap, mna_state)`** (Lines 1019-1033)
   - Iterates map but uses MNA_State
   - **Recommendation**: Keep in `FlowEngine`. It will import ShipMap/GameMap from FlowMap.

5. **`list_elements(ship/gamemap)`** (Lines 1035-1077)
   - Iterates map to collect electrical elements
   - **Recommendation**: Keep in `FlowEngine`. It needs AbsoluteElement and produce_abs_elements.

6. **`get_node_fluid_tags(node, ship/gamemap)`** (Lines 1365-1417)
   - Iterates map to get fluid tags from components
   - **Recommendation**: Keep in `FlowEngine` as it's part of fluid simulation logic.

---

## Dependency Analysis

### Current FlowEngine Dependencies

```toml
[deps]
HexComponentsAPI = "..."  # For ComponentBehavior, placement_valid import
HexElements = "..."       # For AbsoluteElement, ElementID, etc.
HexFluids = "..."         # For FluidTags
HexFrame = "..."          # For coordinate types
LinearAlgebra = "..."
SmallCollections = "..."
SparseArrays = "..."
StructEquality = "..."
```

### Proposed FlowMap Dependencies

```toml
[deps]
HexComponentsAPI = "..."  # For ComponentBehavior, PipeBehavior, ComponentOnTile
HexFrame = "..."          # For coordinate types (TileCoord, EdgeCoord, etc.)
StructEquality = "..."    # For @struct_hash_equal
```

**Note**: FlowMap does NOT need HexElements or HexFluids - those are only used by MNA logic.

### Proposed FlowEngine Dependencies (After Refactor)

```toml
[deps]
FlowMap = "..."           # NEW - For GameMap, ShipMap, etc.
HexComponentsAPI = "..."  # For ComponentBehavior, produce_abs_elements
HexElements = "..."       # For AbsoluteElement, ElementID, etc.
HexFluids = "..."         # For FluidTags
HexFrame = "..."          # For coordinate types
LinearAlgebra = "..."
SmallCollections = "..."
SparseArrays = "..."
StructEquality = "..."
```

---

## Packages That Currently Depend on FlowEngine

These packages will need their dependencies updated:

### Packages That Should Depend on FlowMap (Instead of/In Addition to FlowEngine)

| Package | Current FlowEngine Usage | New Dependency |
|---------|-------------------------|----------------|
| `HexComponentsAPI` | None currently, but `placement_valid` error message references it | Add `FlowMap` dependency |
| `HexFlowBasicComponents` | Uses FlowEngine (unclear what exactly) | Likely needs `FlowMap` |
| `HexFlowBasicPipes` | Uses FlowEngine | Likely needs `FlowMap` |
| `HexFlowNozzleComponents` | Uses `GameMap`, `is_on_surface_tile`, `is_node_on_ship_surface` | Replace with `FlowMap` |
| `HexFlowPipeComponents` | Uses FlowEngine | Check if only map types needed |
| `HexFlowPumpComponents` | Uses `MNA_State`, `DerivedMapState` | Keep `FlowEngine`, may also need `FlowMap` |
| `HexFlowSwitchComponents` | Uses `DerivedMapState` | Keep `FlowEngine`, may also need `FlowMap` |
| `HexFlowTankComponents` | Uses `MNA_State` | Keep `FlowEngine`, may also need `FlowMap` |
| `HexFlowCalculator` | Uses both map types and MNA functions | Keep `FlowEngine`, add `FlowMap` |
| `HexFlowRendering` | Uses `FlowEngine.get_all_components` | Add `FlowMap` |
| `HexFlowProcGen` | Uses `GameMap`, `ShipMap`, docking status, bounds, `offset_ship!` | Replace with `FlowMap` |
| Root project (`src/*.jl`) | Uses both extensively | Keep `FlowEngine`, add `FlowMap` |

### Detailed Component Package Analysis

After reviewing the grep results, here's what each component package uses:

1. **HexFlowNozzleComponents**: Uses `GameMap` type, `is_on_surface_tile`, `is_node_on_ship_surface` in `placement_valid`
   - **Action**: Add `FlowMap`, keep `FlowEngine` (may use re-exports)

2. **HexFlowPumpComponents**: Uses `MNA_State` for `update_flowbehav!` and `render_map_elem!`, `DerivedMapState` for fluid colours
   - **Action**: Keep `FlowEngine` (will get FlowMap via re-exports)

3. **HexFlowSwitchComponents**: Uses `DerivedMapState` for `render_map_elem!` fluid colours
   - **Action**: Keep `FlowEngine` dependency

4. **HexFlowTankComponents**: Uses `MNA_State` for `update_flowbehav!` current lookups
   - **Action**: Keep `FlowEngine` dependency

5. **HexFlowPipeComponents**: Uses `DerivedMapState.nodeactualfluids` in `render_map_elem!`
   - **Action**: Keep `FlowEngine` dependency (needs DerivedMapState)

6. **HexFlowBasicPipes**: Uses `DerivedMapState.nodeactualfluids` in `render_pipe_map!`
   - **Action**: Keep `FlowEngine` dependency (needs DerivedMapState)

7. **HexFlowBasicComponents**: Only has `using FlowEngine` but doesn't appear to use any FlowEngine-specific types
   - **Action**: May be able to remove FlowEngine dependency, or keep for potential future use. Investigate during implementation.

---

## Re-exports Strategy

To minimise breaking changes, `FlowEngine` should re-export all symbols from `FlowMap`:

```julia
module FlowEngine

using FlowMap
# Re-export all FlowMap exports
export ShipMap, GameMap
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship, offset_ship!
# ... etc.

# Or use a blanket re-export pattern:
# for name in names(FlowMap)
#     @eval export $name
# end
```

This allows existing code to continue working with `using FlowEngine` while new code can choose to use `using FlowMap` directly.

---

## HexComponentsAPI Integration

### Current Situation

The current `placement_valid` default in HexComponentsAPI:

```julia
function placement_valid(behav::T, coord::TileCoord, surface; kwargs...) where {T <: ComponentBehavior}
    error("placement_valid should be called with GameMap as the surface argument; the method for that is implemented in FlowEngine")
end
```

### After Refactor

With FlowMap, HexComponentsAPI can:

1. Add `FlowMap` as a dependency
2. Import `GameMap` type
3. Provide a proper typed default implementation:

```julia
using FlowMap: GameMap, is_on_surface_tile

function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...) where {T <: ComponentBehavior}
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (true, "")
    else
        return (false, "Not on ship surface")
    end
end
```

This moves the default implementation from FlowEngine to HexComponentsAPI where it belongs, removing the awkward circular reference.

---

## Execution Checklist

### Pre-Execution: Package Creation (User Action Required)

Please create the following package:

**Package Name**: `FlowMap`
**Location**: `local_packages/FlowMap/`

Suggested UUID (you can generate a new one): `<will be auto-generated>`

Required dependencies in Project.toml:
```toml
[deps]
HexComponentsAPI = "a2289db6-e3a5-4e05-9c21-8734dce2bbd4"
HexFrame = "5e4e96f9-9c53-49aa-b8a9-74f43a6aaf47"
StructEquality = "6ec83bb0-ed9f-11e9-3b4c-2b04cb4e219c"
```

### Pre-Execution: Dependency Updates (User Action Required)

Add `FlowMap` as a dependency to:

1. **FlowEngine** (`local_packages/FlowEngine/Project.toml`)
2. **HexComponentsAPI** (`local_packages/components/HexComponentsAPI/Project.toml`)
3. **HexFlowProcGen** (`local_packages/HexFlowProcGen/Project.toml`)
4. **Root Project** (`Project.toml`)

Packages that will get FlowMap indirectly via FlowEngine re-exports (no change needed):
- `HexFlowNozzleComponents` - uses GameMap, is_on_surface_tile, is_node_on_ship_surface
- `HexFlowRendering` - uses get_all_components
- `HexFlowCalculator` - uses GameMap, ShipMap extensively
- `HexFlowPumpComponents`, `HexFlowSwitchComponents`, `HexFlowTankComponents`, `HexFlowPipeComponents`, `HexFlowBasicPipes` - use DerivedMapState/MNA_State, keep FlowEngine dep

### Code Migration Steps

1. **Create FlowMap module** with:
   - All map types (ShipMap, GameMap, docking status types)
   - All map accessor functions
   - All bounds/geometry functions
   - All placement validation functions
   - Ship helper functions
   - Docking animation functions

2. **Update FlowEngine**:
   - Add `using FlowMap`
   - Re-export all FlowMap symbols for backwards compatibility
   - Remove migrated code
   - Keep DerivedMapState, MNA_State, and all MNA functions
   - Keep functions that take both map types and MNA types

3. **Update HexComponentsAPI**:
   - Add `using FlowMap`
   - Move `placement_valid` default implementation here
   - Remove error-throwing default

4. **Update using statements** in all affected packages

5. **Update tests**:
   - FlowEngine tests that test map functionality should move to FlowMap
   - Keep MNA tests in FlowEngine

6. **Update copilot-instructions.md** to reflect new package structure

---

## Potential Issues and Mitigations

### Issue 1: Circular Dependencies

**Risk**: If FlowMap needs HexComponentsAPI (for `ComponentOnTile` type in `ShipMap`) and HexComponentsAPI needs FlowMap (for `GameMap` in `placement_valid`).

**Mitigation**: This is actually fine because:
- FlowMap uses `ComponentOnTile` as a stored type (doesn't call methods on it)
- HexComponentsAPI uses `GameMap` as a parameter type and calls `is_on_surface_tile`

Both are valid forward uses. Julia handles this correctly when both packages are in the workspace.

### Issue 2: Breaking Changes

**Risk**: Existing code using `using FlowEngine` may break.

**Mitigation**: FlowEngine will re-export all FlowMap symbols, maintaining backwards compatibility.

### Issue 3: Test Failures

**Risk**: Tests may fail during transition.

**Mitigation**: 
- Run tests after each step
- Keep re-exports in place until all tests pass
- Consider running the game after each major step

---

## Questions for Clarification

1. **Package naming**: Is `FlowMap` acceptable, or would you prefer a different name like `HexFlowMap` or `GameMapEngine`?

2. **Component packages**: For packages like `HexFlowBasicComponents` and `HexFlowBasicPipes`, should I investigate their exact FlowEngine usage before starting, or handle them during implementation?

3. **Re-export strategy**: Should FlowEngine permanently re-export FlowMap symbols for convenience, or should we eventually require explicit `using FlowMap`?

4. **Test migration**: Should FlowMap have its own test suite (recommended), or should tests stay in FlowEngine temporarily?

---

## Summary

| Aspect | FlowMap (New) | FlowEngine (Refactored) |
|--------|---------------|------------------------|
| **Purpose** | Map data structures and accessors | MNA calculation and fluid simulation |
| **Key Types** | `GameMap`, `ShipMap`, `DockingStatus` variants | `DerivedMapState`, `MNA_State` |
| **Key Functions** | `get_component`, `set_component!`, `is_on_surface_tile`, `offset_ship!`, bounds functions | `MNA_solve`, `prune`, `ground_search`, `list_elements`, `update_components!` |
| **Dependencies** | HexComponentsAPI, HexFrame, StructEquality | **FlowMap**, HexComponentsAPI, HexElements, HexFluids, HexFrame, LinearAlgebra, SmallCollections, SparseArrays, StructEquality |
| **Downstream Users** | HexComponentsAPI, component packages, HexFlowProcGen, HexFlowRendering | HexFlowCalculator, component packages (for MNA) |

