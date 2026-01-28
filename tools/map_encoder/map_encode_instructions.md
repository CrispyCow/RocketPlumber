# Map Encoder Instructions for AI Agents

## Overview
This document provides instructions for AI agents to convert encoded GameMap structures into Julia code that recreates the maps. The goal is to create maintainable, human-readable tutorial map generation functions.

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

### Step 3: Generate the Map Creation Function
Create a Julia file with a function named `mapgen_<mapname>()` that returns a GameMap.

#### Function Requirements:
- **Function name**: Must be `mapgen_<mapname>()` where `<mapname>` matches the original file
- **Return type**: Must return a `GameMap`
- **Dependencies**: Should use component constructors from the existing codebase
- **Style**: Should follow existing code patterns in the project

#### Component Reference Locations:
To understand how to construct components, examine these files:
- `src/components.jl` - Contains component constant definitions and constructor patterns
- `src/components/basic_components.jl` - Basic component behaviors and fragments
- `src/components/tank_components.jl` - Tank-related components
- `src/components/pump_components.jl` - Pump and propulsion components  
- `src/components/nozzle_components.jl` - Nozzle and thrust components
- `src/components/switch_components.jl` - Switch and control components

#### Key Constructor Patterns:
Study `src/components.jl` to see how components are typically constructed:

```julia
# Example patterns from components.jl:
const TurboPump = TurboPumpCompBehav(
    pump_voltage = 50.0,
    series_conductance = 1.0,
    turbine_gain = -0.2,
)

const TriGasTank = ThevininTankCompBehav(GasTankBehavFrag, 3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 200,
    max_voltage = 50,
    initial_charge = 150,
    series_conductance = 5.0
)
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
   - Tile-based pipe components also exist (e.g., `ScrapTilePipeCompBehav`)

6. **Ship Surface**:
   - The `ship_tiles` field defines where components can be placed
   - It's a `Set{TileCoord}` containing all valid placement locations
   - Components can only be placed on coordinates in the ship surface
   - Pipe endpoints must connect to nodes adjacent to ship surface tiles

7. **Documentation**:
   - Add comments explaining the purpose of complex components
   - Include a docstring describing what the tutorial teaches
   - Note any interesting patterns or learning objectives

### Step 4: Test the Generated Function
Use the comparison tool to validate your generated code:

```bash
# Option 1: Use a map name (looks in maps/ folder)
julia --project=. tools/map_encoder/compare_maps.jl <mapname> <path_to_generated_file.jl>

# Option 2: Use a relative or absolute path to the .jld2 file
julia --project=. tools/map_encoder/compare_maps.jl <path/to/map.jld2> <path_to_generated_file.jl>
```

Naming convention and sanitization:
- The encoder will produce a function named `mapgen_<basename>` where the basename is sanitized by removing underscores and non-alphanumeric characters and correcting common typos (e.g., `mulit` → `multi`).
- For example, input `mulitship_example.jld2` will generate `mapgen_multishipexample()` and the file `tutorials/mapgen_multishipexample.jl`.

Examples:
```bash
# Map name (backwards compatible)
julia --project=. tools/map_encoder/compare_maps.jl autotest1 tutorials/mapgen_autotest1.jl

# Relative path
julia --project=. tools/map_encoder/compare_maps.jl src/demo_maps/basicplumbing.jld2 tutorials/mapgen_basicplumbing.jl

# Multi-ship example (encoder will generate a `mapgen_<basename>` function - ensure basename is suitable)
julia --project=. tools/map_encoder/encode_map.jl mulitship_example src/demo_maps/mapgen_mulitship_example.jl
julia --project=. tools/map_encoder/compare_maps.jl mulitship_example src/demo_maps/mapgen_mulitship_example.jl

Note: The tool no longer attempts aggressive sanitization. Provide a suitable basename for the generated function (e.g., `mulitship_example` → `mapgen_mulitship_example`).
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

### Step 5: Iterate if Needed
If the comparison tool reports mismatches:
- Review the specific differences reported
- Adjust parameter values, component types, or coordinates
- Re-test until you achieve a perfect match

## Common Component Types

Based on the project structure, you'll likely encounter:

**Tile-Based Components:**
- **BasicCompBehav**: Simple components with basic elements (resistors, sources, etc.)
- **TurboPumpCompBehav**: Propulsion pumps with voltage and turbine parameters
- **BasicNozzleCompBehav**: Thrust nozzles with throat area parameters
- **SwitchedNozzleCompBehav**: Nozzles with integrated flow control switches
- **ThevininTankCompBehav**: Fluid storage tanks with charge and pressure parameters
- **BoolSwitchCompBehav**: On/off switches with conductance parameters
- **BigAdjustableValveCompBehav**: Adjustable flow control valves
- **ElectricPumpCompBehav**: Electric pumps with energy storage
- **ScrapTilePipeCompBehav**: Tile-based pipe connectors (can be placed on tiles)
- **BigTilePipeCompBehav**: Tile-based high-flow pipe connectors

**Edge-Based Pipes (PipeBehavior):**
- **ScrapPipeBehav**: Low conductance pipe (2.0 S default)
- **BigPipeBehav**: High conductance pipe (10.0 S default) with fluid-aware rendering

Edge-based pipes are placed on edges between hex tiles, while tile-based components occupy tile positions.

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