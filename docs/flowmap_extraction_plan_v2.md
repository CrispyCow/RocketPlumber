# FlowMap Package Extraction Plan (No Re-Export Strategy)

## Overview

This plan details the extraction of map-related functionality from `FlowEngine` into a new `FlowMap` package. A strict "no re-export" policy is enforced: `FlowEngine` will depends on `FlowMap` but will NOT export `FlowMap`'s symbols. This requires updating all downstream packages to depend on `FlowMap` explicitly where needed.

## Architecture

| Package | Responsibility | Dependencies |
|---------|----------------|--------------|
| **FlowMap** (New) | Map logic, Storage, Validation, Geometry | `HexComponentsAPI`, `HexFrame` |
| **FlowEngine** (Refactored) | Simulation, MNA, Fluid Propagation | `FlowMap`, `HexComponentsAPI`, `HexElements`, `HexFluids`, ... |
| **HexComponentsAPI** | Interfaces, Behaviors | (Remains independent of `FlowMap` to avoid circularity) |

### Functional Split

**FlowMap**:
- **Types**: `GameMap`, `ShipMap`, `DockingStatus` (and variants), `RenderPosOffsetState`.
- **Logic**: Ship management (`add_ship!`), Component accessors (`get_component`), Geometry (`get_axial_bounds`), Placement Validation (`placement_valid`, `is_on_surface_tile`).
- **Interfaces**: Defines the concrete `placement_valid(::ComponentBehavior, ::TileCoord, ::GameMap)` method (overloading API).

**FlowEngine**:
- **Types**: `DerivedMapState`, `MNA_State`.
- **Logic**: `MNA_solve`, `update_components!`, `prune`, `ground_search`.
- **Note**: Functions that iterate the map for basic access move to `FlowMap`. Functions that iterate the map for *electrical analysis* stay in `FlowEngine`.

---

## Detailed Dependency Analysis

Based on codebase code investigation, here are the required dependency updates:

| Package | Action | Reasoning |
|---------|--------|-----------|
| **HexComponentsAPI** | **No Change** | Circular dependency avoidance. `FlowMap` will depend on it. |
| **HexFlowBasicComponents** | **Remove FlowEngine** | Clean. No usage of Map or Engine types found. |
| **HexFlowBasicPipes** | **Add FlowMap**, Keep FlowEngine | Uses `DerivedMapState` (Engine) and needs `PipeBehavior` map access (Map). |
| **HexFlowNozzleComponents** | **Add FlowMap**, Keep FlowEngine | Uses `GameMap` heavily (Map) and `MNA_State` for thrust (Engine). |
| **HexFlowPipeComponents** | **Add FlowMap**, Keep FlowEngine | Uses `GameMap` (validation) and `DerivedMapState` (fluid render). |
| **HexFlowPumpComponents** | **Add FlowMap**, Keep FlowEngine | Uses `GameMap` (validation) and `MNA_State` (pump logic). |
| **HexFlowSwitchComponents** | **Add FlowMap**, Keep FlowEngine | Uses `GameMap` (validation) and `DerivedMapState` (fluid render). |
| **HexFlowTankComponents** | **Add FlowMap**, Keep FlowEngine | Uses `GameMap` (validation) and `MNA_State` (tank properties). |
| **HexFlowRendering** | **Add FlowMap**, Keep FlowEngine | Iterates maps (Map) and visualizes fluids (Engine). |
| **HexFlowProcGen** | **Add FlowMap**, **Remove FlowEngine** | Only does Map content generation. No MNA usage. |
| **HexFlowCalculator** | **Add FlowMap**, Keep FlowEngine | Core loop using both. |
| **HexFrame** | No Change | Foundational. |

---

## Migration Steps

### 1. Package Creation (User Action)
Create `local_packages/FlowMap` with `Project.toml`:
```toml
name = "FlowMap"
uuid = "<generate-uuid>"
authors = ["Your Name"]
version = "0.1.0"

[deps]
HexComponentsAPI = "a2289db6-e3a5-4e05-9c21-8734dce2bbd4"
HexFrame = "5e4e96f9-9c53-49aa-b8a9-74f43a6aaf47"
StructEquality = "6ec83bb0-ed9f-11e9-3b4c-2b04cb4e219c"
```

### 2. Dependency Updates (User Action / Project.toml Edits)
Update `Project.toml` for all packages listed in the **Detailed Dependency Analysis** table.
- Add `FlowMap` dependency where indicated.
- Remove `FlowEngine` dependency where indicated (`HexFlowProcGen`, `HexFlowBasicComponents`).

### 3. Code Migration (Agent Action)
1. **Populate FlowMap**:
   - Move Map Structs (`ShipMap`, `GameMap`) and Accessors.
   - Move Docking Logic (`DockingStatus`).
   - Move Geometry/Bounds logic.
   - Implement `placement_valid(::ComponentBehavior, ::TileCoord, ::GameMap)` here.
2. **Refactor FlowEngine**:
   - `using FlowMap`
   - Remove moved code.
   - **CRITICAL**: Do NOT add `export GameMap` etc.
   - Ensure MNA functions reference `FlowMap.GameMap` or import it.

### 4. Source Updates (Agent Action)
Iterate through all packages and update usage:
- `using FlowEngine` -> `using FlowEngine, FlowMap` (or just `FlowMap`).
- Replace `FlowEngine.GameMap` checks with `GameMap` (after `using FlowMap`).
- Fix `placement_valid` calls if necessary (though dispatch should handle it).

**Specific File Updates**:
- `tools/map_encoder/encode_map.jl`: Update imports.
- `src/gameloop.jl`: Update JLD2 serialization mapping.
```julia
# Old
# typemap = Dict("FlowEngine.ShipMap" => JLD2.Upgrade(FlowEngine.ShipMap))

# New
using FlowMap
# ...
typemap = Dict(
    "FlowEngine.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
    "FlowEngine.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
    "FlowEngine.DockingStatus" => JLD2.Upgrade(FlowMap.DockingStatus), # verify if needed for abstracts
    "FlowEngine.ConnectedDockStat" => JLD2.Upgrade(FlowMap.ConnectedDockStat),
    # etc...
)
```

### 5. Test Migration
- Move tests from `FlowEngine/test/runtests.jl` that focus on Map/Ship logic to `FlowMap/test/runtests.jl`.
- Keep MNA tests in `FlowEngine/test/runtests.jl`.

---

## Execution Checklist

1. [ ] **User**: Create `local_packages/FlowMap` package structure.
2. [ ] **User**: Run package manager commands to add dependencies (as per matrix).
3. [ ] **Agent**: Move code from `FlowEngine.jl` to `FlowMap/src/FlowMap.jl`.
4. [ ] **Agent**: Clean up `FlowEngine.jl`.
5. [ ] **Agent**: Update `src/gameloop.jl` JLD2 logic.
6. [ ] **Agent**: Update imports in `local_packages/components/*`.
7. [ ] **Agent**: Update imports in `HexFlowProcGen`, `HexFlowRendering`, `HexFlowCalculator`.
8. [ ] **Agent**: Update imports in `tools/map_encoder/encode_map.jl`.
9. [ ] **Agent**: Split tests.
10. [ ] **User**: Run tests/game to verify.
