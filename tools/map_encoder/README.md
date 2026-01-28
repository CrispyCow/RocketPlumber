# Map Encoder Tool Suite

A complete toolkit for converting JLD2 GameMap files into maintainable Julia code using AI assistance.

## Tool Overview

### 1. `encode_map.jl` - Map Structure Encoder
Converts JLD2 map files into human-readable text format suitable for AI analysis.

### 2. `compare_maps.jl` - Map Validation Tool  
Compares AI-generated map functions against original JLD2 files to validate accuracy.

### 3. `map_encode_instructions.md` - AI Agent Guide
Comprehensive instructions for AI agents to convert encoded maps into Julia code.

## Complete AI-Assisted Workflow

### Step 1: Encode the Original Map
```bash
julia --project=. tools/map_encoder/encode_map.jl <mapname>
```

**Example:**
```bash
julia --project=. tools/map_encoder/encode_map.jl autotest1
```

This outputs the complete map structure to stdout with proper formatting, showing:
- All ships individually with their `components`, `pipe_behaviors`, and `ship_tiles`
- All components with their types and parameters
- Tile positions and rotations
- Pipe connections and conductances

### Step 2: AI Code Generation
Provide the AI agent with:
1. The encoded map output from Step 1
2. The instructions from `map_encode_instructions.md`
3. Context from the project's component files (referenced in instructions)

The AI will create a function named `mapgen_<mapname>()` that reconstructs the map.

### Step 3: Validate the Generated Code
```bash
julia --project=. tools/map_encoder/compare_maps.jl <mapname> <generated_file.jl>
```

**Example:**
```bash
julia --project=. tools/map_encoder/compare_maps.jl autotest1 tutorials/mapgen_autotest1.jl
```

This will:
- Load the original map from JLD2
- Execute your generated function
- Compare every component, parameter, and pipe
- Report any differences found
- Exit with code 0 for perfect match, 1 for differences

## Tool Specifications

### encode_map.jl
**Usage:** `julia --project=. tools/map_encoder/encode_map.jl <mapname> [output_file]`

**Arguments:**
- `mapname` - Name of map file (without .jld2 extension) in maps/ folder
- `output_file` - Optional: Write output to file instead of just stdout

**Features:**
- Loads maps using existing project infrastructure
- Formats output with proper indentation
- Each component and pipe on separate lines
- Includes all parameter details for AI analysis

### compare_maps.jl
**Usage:** `julia --project=. tools/map_encoder/compare_maps.jl <original_mapname> <generator_file>`

**Arguments:**
- `original_mapname` - Name of original map file (without .jld2 extension)
- `generator_file` - Path to .jl file containing mapgen_<name>() function

**Validation Features:**
- Component type matching
- Parameter value comparison (with floating-point tolerance)
- Rotation verification
- Complete pipe network validation
- Detailed mismatch reporting
- Exit codes for scripting (0=perfect, 1=differences)

## AI Agent Instructions

The `map_encode_instructions.md` file provides comprehensive guidance for AI agents including:

- **Reference locations** for component constructors and patterns
- **Code generation guidelines** following project conventions
- **Parameter extraction** strategies from encoded structures
- **Coordinate system** documentation
- **Common component types** and their constructors
- **Troubleshooting** for typical issues
- **Success criteria** for validation

## Example Complete Workflow

```bash
# 1. Encode a map
julia --project=. tools/map_encoder/encode_map.jl autotest1

# Multi-ship maps
For multi-ship JLD2 files the tool will emit per-ship entries. To generate a `mapgen_*.jl` file write to `src/demo_maps/` with a `.jl` extension (example below). The encoder will use the map basename to name the function, so provide a reasonable basename (e.g., `mulitship_example` → `mapgen_mulitship_example`).

# 2. (AI agent creates mapgen_autotest1.jl from the output and instructions)

# 3. Validate the generated code
julia --project=. tools/map_encoder/compare_maps.jl autotest1 tutorials/mapgen_autotest1.jl
```

**Expected Output for Perfect Match:**
```
============================================================
MAP COMPARISON RESULTS
============================================================
✅ PERFECT MATCH: Generated map exactly matches original!
```

## File Organization

```
tools/map_encoder/
├── encode_map.jl                    # Map encoding tool
├── compare_maps.jl                  # Map comparison/validation tool
├── map_encode_instructions.md       # AI agent instructions
└── README.md                        # This documentation

tutorials/                           # Generated tutorial functions
├── mapgen_autotest1.jl             # Example generated map
└── mapgen_<other_maps>.jl          # Additional tutorials
```

## Integration with Project

The tools are designed to:
- Run from project root with `--project=.` to access all dependencies
- Use existing component constructors and patterns
- Maintain compatibility with current codebase structure
- Support the existing JLD2 → Code migration workflow

## Error Handling

**Common Issues:**

1. **Map file not found** - Verify map exists in `maps/` folder
2. **Function name mismatch** - Ensure function is named `mapgen_<mapname>`
3. **Component constructor errors** - Check `src/components.jl` for correct syntax
4. **Precision mismatches** - Use exact floating-point values from encoded output

**World Age Warnings:** The comparison tool may show Julia 1.12 world age warnings - these are harmless and don't affect functionality.

## Benefits

This toolkit enables:
- **Version-resilient tutorial storage** as Julia code instead of binary JLD2
- **AI-assisted map conversion** reducing manual work
- **Validation and testing** ensuring generated code accuracy
- **Human-readable tutorials** with documentation and comments
- **Easy modification** of tutorial parameters and structure