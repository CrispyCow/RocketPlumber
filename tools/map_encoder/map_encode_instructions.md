# Map Encoder Instructions for AI Agents

## Overview
This document provides instructions for AI agents to convert encoded GameMap structures into Julia code that recreates the maps. There are two workflows depending on map complexity:

- **Manual authoring** (preferred for simple maps): The agent reads the encoder's human-readable summary, then writes a clean mapgen function by hand using keyword constructors. This produces the most readable, editable output. See `src/demo_maps/mapgen_controllingcoldgas.jl` as the reference style.
- **Auto-generation with reformatting** (for complex/procgen maps): When a map has too many uniquely-parameterised components to hand-craft, use the encoder's `.jl` output mode, then clean up the generated code with a reformatting pass.

Both workflows use the same comparison tool to validate the result.

## Workflow Steps

### Step 1: Encode the Original Map
Use the encoding tool to convert the JLD2 map file to readable text:

```bash
# Option 1: Use a map name (looks in maps/ folder)
julia --project=. tools/map_encoder/encode_map.jl <mapname>

# Option 2: Use a relative or absolute path to the .jld2 file
julia --project=. tools/map_encoder/encode_map.jl <path/to/map.jld2>
```

Examples:
```bash
# Map name (backwards compatible - looks in maps/ folder)
julia --project=. tools/map_encoder/encode_map.jl autotest1

# Relative path from project root
julia --project=. tools/map_encoder/encode_map.jl src/demo_maps/basicplumbing.jld2

# Absolute path
julia --project=. tools/map_encoder/encode_map.jl C:/path/to/mymap.jld2
```

This will output the map structure to stdout in a formatted way.

### Step 2: Analyze the Encoded Map
Study the output to understand:
- Component types and their parameters
- Tile positions and rotations  
- Pipe connections and conductances
- Overall map structure and purpose

### Step 3: Choose a Workflow

Based on the map complexity:

- **Simple map** (≤15–20 components, 1–2 ships, components match or are close to const definitions in `src/components.jl`): Proceed with **Manual Authoring** (Step 4a)
- **Complex map** (many unique procgen parameters, multiple ships, 30+ components): Proceed with **Auto-Generation** (Step 4b)

When in doubt, try manual authoring first — it produces much better output.

### Step 4a: Manual Authoring (Simple Maps)
Create a Julia file with a function named `mapgen_<mapname>()` that returns a GameMap.

#### Function Requirements:
- **Function name**: Must be `mapgen_<mapname>()` where `<mapname>` matches the original file
- **Return type**: Must return a `GameMap`
- **Dependencies**: Should use component constructors from the existing codebase
- **Style**: Should follow existing code patterns in the project

#### Component Reference Locations:
To understand how to construct components, examine these files:
- `src/components.jl` - Contains component constant definitions and constructor patterns
- `local_packages/components/HexFlowBasicComponents/src/HexFlowBasicComponents.jl` - Basic component behaviours and fragments
- `local_packages/components/HexFlowTankComponents/src/HexFlowTankComponents.jl` - Tank-related components
- `local_packages/components/HexFlowPumpComponents/src/HexFlowPumpComponents.jl` - Pump and propulsion components
- `local_packages/components/HexFlowNozzleComponents/src/HexFlowNozzleComponents.jl` - Nozzle and thrust components
- `local_packages/components/HexFlowSwitchComponents/src/HexFlowSwitchComponents.jl` - Switch and control components

#### Key Constructor Patterns:
Study `src/components.jl` to see how components are typically constructed:

```julia
# Example patterns from components.jl:
const TurboPump = TurboPumpCompBehav(
   max_pump_voltage = 50.0,
    series_conductance = 1.0,
   max_turbine_conductance = 0.3,
   cycle_efficiency = 0.6,
   max_rpm = 3000.0,
   rotor_inertia = 1000.0,
   friction_coefficient = 0.005,
)

const TriGasTank = ThevininTankCompBehav(GasTankBehavFrag, 3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 200,
    max_voltage = 50,
    initial_charge = 150,
    series_conductance = 5.0
)

# Pressure-fed tank (positional constructor with inner fragment):
const PressureFedLiquidTank = PressureFedTankCompBehav(
    PressureFedTankBehavFrag(
        initial_liquid_charge = 150.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        initial_gas_charge = 0.0,
        max_liquid_charge = 200.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    ),
    (HexFrame.NODE_Q_NEG,),   # liquid_nodes tuple
    5.0,                       # series_conductance
    HexFluids.COLD_GAS,       # gas_fluid
    HexFluids.MONOPROP_LIQUID, # liquid_fluid
    NoRotationBehavFrag()
)

# StandardValveCompBehav takes a switch fragment type and valve size type:
const LargeAdjValve = StandardValveCompBehav(SteppedSwitchBehavFrag, LargeValve;
    max_conductance = 4.0, min_conductance = 0.0,
    growth_factor = calculate_growth_factor(4.0, 0.0, 2.0 / BASE_UPS),
    percentage_step_size = 0.05
)
const LargeOnOffValve = StandardValveCompBehav(BoolSwitchBehavFrag, LargeValve;
    max_conductance = 4.0, min_conductance = 0.0,
    growth_factor = calculate_growth_factor(4.0, 0.0, 2.0 / BASE_UPS)
)

# DecompChamber has no parameters:
const BasicDecompChamber = DecompChamberCompBehav()
```

#### Code Generation Guidelines:

1. **Component Identification**: 
   - Match component types from the encoded structure to constructor patterns in `src/components.jl`
   - Extract parameter values from the tunable information in the encoded data
   - Use appropriate constructor syntax (keyword arguments vs positional)

2. **Constructor Verification** (CRITICAL):
   - For EVERY component type you use in the mapgen function, you MUST examine its constructor definition
   - Location hierarchy for finding constructors:
     1. First check `src/components.jl` for const definitions and reference patterns
     2. Then check the component's source file in `local_packages/components/HexFlow*Components/src/*.jl`
     3. Pay special attention to the constructor's parameter names and their semantic meaning
   
   - **Common Constructor Pitfalls:**
     - `SwitchedNozzleCompBehav`: The `connected_node` parameter specifies the EXTERNAL node that connects to your pipe/tank system, NOT the internal node. The constructor internally creates a switch connecting `connected_node` → `NODE_INTERNAL`, and a nozzle connecting `NODE_INTERNAL` → `GROUND`. Always set `connected_node = HexFrame.NODE_Q_POS` (or appropriate external node based on rotation), never `NODE_INTERNAL`.
     - Multi-stage components: Parameters in the constructor may differ from internal structure shown in encoded output
     - Wrapper components: Constructor parameters may be transformed before being stored in internal fragments
   
   - **Verification Process:**
     1. Identify the component type from encoded output (e.g., `SwitchedNozzleCompBehav`)
     2. Search for its constructor definition: `grep -r "function SwitchedNozzleCompBehav" local_packages/components/`
     3. Read the constructor signature and parameter documentation carefully
     4. Map encoded internal structure back to constructor parameters (reverse-engineer the transformation)
     5. Cross-reference with examples in `src/components.jl` for the same component type
     6. When in doubt, look at the switch/fragment connections in the encoded output to determine the external node

   - **⚠️ CRITICAL: Handling Stateful Components:**
     
     Many components contain mutable state (e.g., switches, tanks, nozzles). **You must create separate instances for each placement** to avoid sharing state between tiles.
     
     **❌ WRONG - Shared References (Bug!):**
     ```julia
     # This causes both nozzles to share the same state object!
     switched_nozzle = SwitchedNozzleCompBehav(...)
map.components[TileCoord(1, 1)] = ComponentOnTile(switched_nozzle, HexFrame.S_POS)
map.components[TileCoord(1, -2)] = ComponentOnTile(switched_nozzle, HexFrame.R_POS)
# Opening one nozzle will open BOTH - they point to the same object!
```

**✅ CORRECT - Separate Instances (Preferred for 2 components):**
```julia
# Create separate instances with descriptive names
switched_nozzle_1 = SwitchedNozzleCompBehav(...)
switched_nozzle_2 = SwitchedNozzleCompBehav(...)
map.components[TileCoord(1, 1)] = ComponentOnTile(switched_nozzle_1, HexFrame.S_POS)
map.components[TileCoord(1, -2)] = ComponentOnTile(switched_nozzle_2, HexFrame.R_POS)
```

**✅ CORRECT - Inline Creation (Best for simple components with few constuctor arguments):**
```julia
# Create directly in ComponentOnTile - no variables needed
map.components[TileCoord(1, 1)] = ComponentOnTile(
    SwitchedNozzleCompBehav(...), HexFrame.S_POS)
map.components[TileCoord(1, -2)] = ComponentOnTile(
    SwitchedNozzleCompBehav(...), HexFrame.R_POS)
```

**✅ CORRECT - Using deepcopy (For 3+ identical components):**
```julia
# Define template and copy for each use
nozzle_template = SwitchedNozzleCompBehav(...)
map.components[TileCoord(1, 1)] = ComponentOnTile(deepcopy(nozzle_template), HexFrame.S_POS)
map.components[TileCoord(1, -2)] = ComponentOnTile(deepcopy(nozzle_template), HexFrame.R_POS)
map.components[TileCoord(2, 0)] = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_POS)
```

**Which approach to use:**
     - **Inline creation**: Best for 1-2 components with simple constructors 
     - **Separate variables**: Good for 2 components with descriptive names (e.g., `left_tank`, `right_tank`)
     - **deepcopy**: Best for 3+ identical components to avoid repeating long parameter lists
     
     **When in doubt, assume a component has state!** Most components with switches, tanks, energy storage, or changing behavior are stateful.
     
     **Note on validation:** The `compare_maps.jl` validation tool includes an identity check that detects shared component references. It uses `isbitstype()` to filter out safe types (like simple pipe behaviors) that contain only primitive data with no references. Any type that isn't `isbitstype` is conservatively flagged if shared, which may produce occasional false positives for truly stateless immutable types - but this is acceptable since the comparison against the original map serves as a validation fallback.
     
     **The comparison tool will detect this error** and report "SHARED COMPONENT REFERENCES DETECTED" with details of which tiles share objects.

#### Map Structure (Multi-Ship example):
   ```julia
   function mapgen_<mapname>()
       # Create ShipMap for the first ship
       ship_primary = ShipMap()
       ship_primary.components[TileCoord(0, 0)] = ComponentOnTile(SomeCompBehav(...), HexFrame.S_POS)
       ship_primary.pipe_behaviors[EdgeCoord(TileCoord(0,0), TileCoord(1,0))] = ScrapPipeBehav()
       ship_primary.ship_tiles = Set([TileCoord(0,0), TileCoord(1,0)])

       # Create another ShipMap for the second ship
       ship_secondary = ShipMap()
       ship_secondary.components[TileCoord(2, 0)] = ComponentOnTile(AnotherCompBehav(...), HexFrame.Q_POS)
       ship_secondary.ship_tiles = Set([TileCoord(2,0), TileCoord(2,1)])

       # Combine into a GameMap
       map = GameMap()
       map.ships[:primary] = ship_primary
       map.ships[:secondary] = ship_secondary

       return map
   end
   ```

3. **Parameter Extraction**:
   - Look for tunable values in the encoded component structures
   - Use reasonable default values for non-tunable parameters
   - Pay attention to state values (tank charges, energy levels) that might need adjustment

4. **Coordinate Handling**:
   - `TileCoord(q, r)` for hex tile positions
   - `EdgeCoord(vertex1, vertex2)` for pipe connections
   - Rotations use `HexFrame.Q_POS`, `HexFrame.Q_NEG`, etc.

5. **Pipe Behaviors**:
   - Edge-based pipes use `PipeBehavior` types like `ScrapPipeBehav()` or `BigPipeBehav()`
   - Default constructors use standard conductance values (ScrapPipeBehav = 2.0 S, BigPipeBehav = 10.0 S)
   - Custom conductance: `ScrapPipeBehav(5.0)` or `BigPipeBehav(15.0)`
   - Tile-based multi-pipe components also exist (for example `single_tile_pipe(HexFrame.Q_POS, ScrapTilePipeBehavFrag())`)

6. **Ship Surface**:
   - The `ship_tiles` field defines where components can be placed
   - It's a `Set{TileCoord}` containing all valid placement locations
   - **Important**: `ShipMap()` defaults to `ship_tiles = Set([TileCoord(0,0)])`. Use direct assignment (`ship.ship_tiles = Set{TileCoord}([...])`) rather than `set_surface_tile!` to avoid keeping the default `(0,0)` tile

## Save Loading Note

The encoder and comparison tools load maps through `src/map_loading.jl` rather than reading raw JLD2 structures directly. That means any reconstruction hooks kept there are part of the supported map-encoding workflow.
   - Components can only be placed on coordinates in the ship surface
   - Pipe endpoints must connect to nodes adjacent to ship surface tiles

## Known Limitations

### Space Maps Are Not Encoded
The `GameMap.space_map` field (which holds encounter systems, manoeuvre data, and velocity state) is **not encoded** into mapgen functions. Generated maps will use the default `SpaceMapEmpty()`. If the original map had a `SpaceMapState` with encounters and manoeuvres, that data is intentionally discarded during encoding.

This is acceptable because these maps are used for tutorials where the space map state is managed separately by the tutorial/learning system.

### Learning System Is Not Encoded
The `GameMap.learning_system` field (which holds tutorial progress, step states, etc.) is **not encoded** into mapgen functions. Generated maps will use the default `NoLearningSystem()`. Tutorial maps have their learning system configuration applied externally via the learning system definitions in `src/tutorials.jl`, not stored in the map itself.

7. **Documentation**:
   - Add comments explaining the purpose of complex components
   - Include a docstring describing what the tutorial teaches
   - Note any interesting patterns or learning objectives

### Step 4b: Auto-Generate and Reformat (Complex Maps)

For maps that are too complex to hand-craft, use the encoder's `.jl` output mode:

```bash
julia --project=. tools/map_encoder/encode_map.jl <path/to/map.jld2> src/demo_maps/mapgen_<mapname>.jl
```

This produces a working but unformatted mapgen function using `repr()` output for all components. The output will pass the comparison tool but is hard to read. Apply a **reformatting pass** to improve readability:

#### Reformatting Checklist

1. **Add a docstring**: Brief description of the map (2–4 lines)
2. **Ship section dividers**: Add `#= ---------- Ship :name ----------- =#` between ships
3. **Blank lines**: Separate components, pipes, and surface tile sections with blank lines
4. **Group components by type**: Reorder components within each ship so that like types are adjacent. Add brief group headers:
   ```julia
   # Gas tanks (10)
   components[TileCoord(...)] = ...
   components[TileCoord(...)] = ...

   # Switched nozzles (4)
   components[TileCoord(...)] = ...
   ```
5. **Do NOT modify constructor calls**: The `repr()` output must remain byte-identical. Only add whitespace, blank lines, and comments around the existing lines.
6. **Verify after reformatting**: Run the comparison tool to confirm nothing was accidentally broken.

### Step 5: Test the Generated Function
Use the comparison tool to validate your generated code:

```bash
# Use a relative or absolute path to the .jld2 file
julia --project=. tools/map_encoder/compare_maps.jl <path/to/map.jld2> <path_to_generated_file.jl>
```

Naming convention:
- The encoder produces a function named `mapgen_<basename>` where `<basename>` is the map file's name without the `.jld2` extension.
- No aggressive sanitization is performed — the basename is used as-is. Ensure the map name is suitable for use as a Julia function identifier.

Examples:
```bash
# Relative path
julia --project=. tools/map_encoder/compare_maps.jl src/demo_maps/basicplumbing.jld2 tutorials/mapgen_basicplumbing.jl

# Multi-ship example (encoder will generate a `mapgen_<basename>` function - ensure basename is suitable)
julia --project=. tools/map_encoder/encode_map.jl src/demo_maps/multiship_example.jld2 src/demo_maps/mapgen_multiship_example.jl
julia --project=. tools/map_encoder/compare_maps.jl src/demo_maps/multiship_example.jld2 src/demo_maps/mapgen_multiship_example.jl

Note: The tool no longer attempts aggressive sanitization. Provide a suitable basename for the generated function (e.g., `multiship_example` → `mapgen_multiship_example`).
```

The comparison tool performs multiple validation checks:
- **Structural comparison**: Verifies tile positions, rotations, pipe placements, and ship surface match
- **Tunable comparison**: Checks that component parameters are within tolerance
- **Identity check**: Detects shared component references (same object used in multiple tiles)
  - **This catches the critical bug where stateful components are reused**
  - Reports which tiles share components so you can fix the code
  - See "Handling Stateful Components" section above for how to fix this
- **Element comparison**: Validates that the electrical/flow circuit elements are identical
  - This catches constructor errors where internal structure is wrong despite matching external structure
  - Example: Using wrong `connected_node` in SwitchedNozzle creates valid structure but broken circuit
  - If element comparison fails but structural comparison passes, you likely have a constructor parameter error

The tool will:
- Load the original map from JLD2
- Execute your generated function
- Compare the results and report differences
- Exit with code 0 if perfect match, 1 if differences found

### Step 6: Iterate if Needed
If the comparison tool reports mismatches:
- Review the specific differences reported
- Adjust parameter values, component types, or coordinates
- Re-test until you achieve a perfect match

## Common Component Types

Based on the project structure, you'll likely encounter:

**Tile-Based Components (15 in `component_list`):**
- **ThevininTankCompBehav**: Thevenin-equivalent fluid storage tanks (gas or liquid) with charge, pressure, and conductance. Const instances: `TriGasTank`, `TriLiquidTank`
- **PressureFedTankCompBehav**: Pressure-fed tanks with separate gas pressurant and liquid storage. Uses `PressureFedTankBehavFrag` inner fragment with positional constructor. Const instance: `PressureFedLiquidTank`
- **BasicNozzleCompBehav**: Thrust nozzles with throat area parameters. Const instances: `TinyNozzle`, `SmallNozzle`, `MediumNozzle`
- **SwitchedNozzleCompBehav**: Nozzles with integrated flow control switches. Const instance: `SwitchedTinyNozzle`
- **DecompChamberCompBehav**: Decomposition chamber nozzle (no constructor parameters). Const instance: `BasicDecompChamber`
- **TurboPumpCompBehav**: Gas-driven turbopumps with voltage, turbine, and inertia parameters. Const instance: `TurboPump`
- **ElectricPumpCompBehav**: Electric pumps (turbopump or transfer pump variants) with energy storage. Const instances: `ElecTurboPump`, `ElecTransferPump`
- **StandardValveCompBehav**: Parameterised valves. Takes a switch fragment type (`SteppedSwitchBehavFrag` for adjustable, `BoolSwitchBehavFrag` for on/off) and a valve size type (`LargeValve` or `TinyValve`). Const instances: `LargeAdjValve`, `TinyAdjValve`, `LargeOnOffValve`, `TinyOnOffValve`
- **MultiPipeTileCompBehav**: Tile-based multi-pipe container holding up to one straight-through fragment on each Q/R/S axis
- **ScrapTilePipeBehavFrag / BigTilePipeBehavFrag**: Tile-pipe fragments inserted into `MultiPipeTileCompBehav` via `single_tile_pipe` or `set_tile_pipe`

**Edge-Based Pipes (PipeBehavior):**
- **ScrapPipeBehav**: Low conductance pipe (2.0 S default)
- **BigPipeBehav**: High conductance pipe (10.0 S default) with fluid-aware rendering

Edge-based pipes are placed on edges between hex tiles, while tile-based components occupy tile positions.

**Note:** `BoolSwitchCompBehav` and `BigAdjustableValveCompBehav` from earlier versions of this document no longer exist. They have been replaced by `StandardValveCompBehav` with appropriate fragment/size type parameters.

## File Organization
Save your generated function as:
- `tutorials/mapgen_<mapname>.jl` (recommended)
- Or any location that's convenient for testing

## Example Usage
```bash
# 1. Encode the map (using a map name)
julia --project=. tools/map_encoder/encode_map.jl simplemap1

# Or encode from a specific path
julia --project=. tools/map_encoder/encode_map.jl src/demo_maps/basicplumbing.jld2

# 2. Create mapgen_<mapname>.jl based on the output

# 3. Test the generated function (map name)
julia --project=. tools/map_encoder/compare_maps.jl simplemap1 tutorials/mapgen_simplemap1.jl

# Or test using path
julia --project=. tools/map_encoder/compare_maps.jl src/demo_maps/basicplumbing.jld2 tutorials/mapgen_basicplumbing.jl
```

## Troubleshooting

**Function not found error**: Ensure your function is named exactly `mapgen_<mapname>`

**Component constructor errors**: Check `src/components.jl` for the correct constructor syntax

**Coordinate mismatches**: Verify that TileCoord and EdgeCoord are constructed correctly

**Parameter mismatches**: Use the comparison tool output to identify which specific values need adjustment

**Element mismatch errors**: The comparison tool reports different circuit elements despite matching structure
- This indicates constructor parameters produce different internal circuit topology
- Review each component constructor carefully - the parameter names may not match internal structure
- For switched/composite components, trace how constructor parameters transform into internal fragments
- Check `src/components.jl` for reference implementations of the same component type
- Look at the specific element details printed (connections, type, value) to identify which component is wrong
- Example: If you see a resistor connecting `NODE_Q_POS` ↔ `NODE_INTERNAL` when it should connect `NODE_INTERNAL` ↔ `GROUND`, you have a switch connection error

## Success Criteria
Your generated function should:
- Compile without errors when included
- Return a GameMap that exactly matches the original (according to the comparison tool)
- Follow existing code style and patterns
- Include helpful comments and documentation