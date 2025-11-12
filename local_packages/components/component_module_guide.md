# Component Module Guide

This guide documents the standardized patterns and conventions for creating new component modules in the HexFlow project. Component modules define the behavior, rendering, and interaction logic for game components (tiles) and pipes (edges).

## Overview

Component modules are organized into packages under `local_packages/components/`:
- **API Package**: `HexComponentsAPI` defines abstract interfaces
- **Implementation Packages**: Provide concrete component and pipe behaviors
- **Fragment Pattern**: Compose behaviors from small, reusable fragments

## Module Structure

### File Organization

```julia
"""
<Brief module purpose>

This module provides concrete implementations of <ComponentBehavior/PipeBehavior> for <domain>:
- <Type1>: <brief description>
- <Type2>: <brief description>

All <components/pipes> follow the <interface> defined in HexComponentsAPI.
"""
module ModuleName

# === Imports ===
using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, RenderEngine, HexFlowRendering
# Additional packages as needed

# ComponentBehavior Mandatories (or PipeBehavior Mandatories)
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional (or PipeBehavior Optional)
import HexComponentsAPI: get_fluidtags, update_flowbehav!, render_map_elem!, on_click!
# Dependencies on other component modules
import HexFlowOtherModule: helper_function

# === Exports ===
# Behavior Fragment Exports (if intended for reuse)
export FragmentType1, FragmentType2
# Helper Function Exports
export helper_function1, helper_function2
# Concrete Behavior Exports
export ConcreteType1, ConcreteType2

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- FragmentName ----------- =#

"Docstring describing the fragment's purpose and behavior"
struct FragmentName
    field1::Type1
    field2::Type2  # inline comment explaining field
end

# Fragment methods...

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- ConcreteBehavName ----------- =#

"Docstring describing the concrete component"
struct ConcreteBehavName <: ComponentBehavior
    fragment1::FragmentType1
    fragment2::FragmentType2
end

# Mandatory interface methods via delegation...
# Optional interface methods...

end # module
```

## Code Conventions

## Code Conventions

### Section Dividers

Use consistent dividers to organize code:

**Major sections** (top-level organization):
```julia
# ===============================================================
# Section Name
# ===============================================================
```

**Minor sections** (individual types):
```julia
#= ---------- TypeName ----------- =#
```

### Import and Export Organization

**Imports**: Group with title-case comments by category:
```julia
# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: get_fluidtags, update_flowbehav!, render_map_elem!
# Dependencies
import HexFlowBasicComponents: StallBehavFrag, stall!
```

**Exports**: Group by type:
```julia
# Behavior Fragment Exports
export MyFragment, MyOtherFragment
# Helper Function Exports
export helper_fn1, helper_fn2
# Concrete Behavior Exports
export MyCompBehav, MyOtherCompBehav
```

### Naming Conventions

Follow consistent naming patterns:
- **Behavior fragments**: `*BehavFrag` (e.g., `NozzleBehavFrag`, `TankBehavFrag`)
- **Tile components**: `*CompBehav` (e.g., `BasicNozzleCompBehav`, `TurboPumpCompBehav`)
- **Pipe behaviors**: `*PipeBehav` (e.g., `ScrapPipeBehav`, `BigPipeBehav`)

### Documentation

**Module docstrings**: Brief purpose statement, list of provided types, reference to API
```julia
"""
Tank component implementations for fluid storage.

This module provides concrete implementations of ComponentBehavior for tanks:
- ThevininTankCompBehav: Tank with series resistor (gas or liquid variants)
- GasTankBehavFrag: Linear charge-voltage relationship

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
```

**Struct docstrings**: Describe the type's purpose and behavior
```julia
"Behavior fragment for shared switch functionality. Missing sprite behavior and behavior to set target_conductance."
struct SwitchBehavFrag
    connection::RelativeElementConnections
    max_conductance::Float64
    min_conductance::Float64
    change_rate::Float64  # inline comment explaining field
    state::SwitchState
end
```

**Function docstrings**: Implementation packages do NOT use function docstrings
- Interface is documented in `HexComponentsAPI`
- Type signatures and parameter names are self-documenting
- Complex algorithms use inline comments within function bodies
- Constructor docstrings are minimal single-line when needed:
  ```julia
  "Keyword constructor for TankBehavFrag with validation."
  function TankBehavFrag(; kwargs...)
  ```

### Field Comments

Use inline comments for field-level documentation:
```julia
struct MyFragment
    max_value::Float64  # Maximum allowed value
    state::MyState      # Mutable state tracker
end
```

## ComponentBehavior Interface

### Mandatory Methods

All tile-based components must implement:

```julia
# Return tuple of RelativeElement instances
produce_rel_elements(behav::MyComp)::NTuple{N, RelativeElement}

# Return tuple of TunableProps for UI
get_tunables(behav::MyComp)::NTuple{N, TunableProps}

# Return new component with updated tunable values
set_tunables(behav::MyComp, tunables::NTuple{N, Real})::MyComp

# Push RenderCommands to queue for base (static) rendering
render_base_elem!(queue::Vector{RenderCommand}, behav::MyComp; 
                  glmap, rotation, position, scale=1.0, transparency=1.0, 
                  render_height_offset::Integer=0, kwargs...)::Nothing
```

### Optional Methods (with defaults)

Override as needed:

```julia
# Dynamic rendering (default: forwards to render_base_elem!)
render_map_elem!(queue, behav; kwargs...)

# Fluid type constraints (default: NodeFluidTags())
get_fluidtags(behav)::NodeFluidTags

# Per-tick update logic (default: no-op)
update_flowbehav!(behav; kwargs...)

# Click handling (default: no-op)
on_click!(behav; kwargs...)

# Thrust calculation (default: 0.0)
get_thrust(behav; kwargs...)::Float64

# Rotation mapping (default: identity)
map_rotation(behav, rotation::HexAxis)::HexAxis

# Move restrictions (default: (true, ""))
can_be_moved(behav; kwargs...)::(Bool, String)

# Particle effects (default: no-op)
collect_effect_particles!(manager, behav; kwargs...)
```

## PipeBehavior Interface

### Mandatory Methods

All edge-based pipes must implement:

```julia
# Return pipe conductance
get_conductance(behav::MyPipe)::Float64

# Return tuple of TunableProps
get_pipe_tunables(behav::MyPipe)::NTuple{N, TunableProps}

# Return new pipe with updated tunables
set_pipe_tunables(behav::MyPipe, tunables::NTuple{N, Real})::MyPipe

# Push RenderCommands for base rendering
render_pipe_base!(queue, behav; glmap, rotation, position, 
                  scale=1.0, transparency=1.0, render_height_offset::Integer=0, 
                  kwargs...)::Nothing
```

### Optional Methods

```julia
# Dynamic rendering (default: forwards to render_pipe_base!)
render_pipe_map!(queue, behav; kwargs...)

# Fluid constraints (default: FluidTags())
get_pipe_fluidtags(behav)::FluidTags

# Move restrictions (default: (true, ""))
can_pipe_be_moved(behav; kwargs...)::(Bool, String)

# Custom element generation (default: creates resistor from conductance)
produce_abs_elements(behav, edge::EdgeCoord)

# Tile-based equivalent (default: nothing)
get_tile_pipe_equivalent(behav)::Union{ComponentBehavior, Nothing}
```

## Common Patterns

### Element Index Constants

When referencing specific elements by index multiple times, define a module-local constant:

```julia
const nozzle_element_index::Int = 1  # Nozzle input element index
const pump_element_index::Int = 1    # Pump resistor element index
```

Place immediately before the relevant struct definition. Do not export.

### Keyword Argument Delegation

**Pure delegation** (forward all kwargs without modification):
```julia
get_thrust(comp::MyComp; kwargs...) = get_thrust(comp.nozzle; kwargs...)
update_flowbehav!(comp::MyComp; kwargs...) = update_flowbehav!(comp.fragment; kwargs...)
```

**Extracting parameters** (only when the function needs them directly):
```julia
function update_flowbehav!(tank::TankBehavFrag; 
                           tile::TileCoord, 
                           mna_state::MNA_State, 
                           kwargs...)
    element_id = ElementID(tile, tank_vsource_element_index)
    # ... use tile and mna_state directly
end
```

**Never re-specify defaults** in delegation signatures - always use `kwargs...`

### Constructors

Use keyword constructors for fragments and concrete behaviors:

```julia
"Keyword constructor with validation."
function MyFragment(;
        param1::Float64,
        param2::Float64,
        optional_param::Float64 = 1.0
    )
    # Validation logic
    param1 > 0.0 || throw(ArgumentError("param1 must be positive"))
    
    # Explicit construction and return
    return MyFragment(param1, param2, optional_param)
end
```

- 4-space indentation for parameters
- Each parameter on its own line
- Include validation in constructor body
- Explicit return statement

### Rendering

**Render heights**: Use constants from `HexFlowRendering` (do not export, qualify with module name):
```julia
# Background elements
HexFlowRendering.RENDER_HEIGHT_BACKGROUND      # -1000

# Pipe layers
HexFlowRendering.RENDER_HEIGHT_PIPE_BASE       # -10 (pipe base sprite)
HexFlowRendering.RENDER_HEIGHT_PIPE            # 0 (fluid mask)

# Component layers
HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND   # 1000 (fluid masks, energy bars)
HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC   # 2000 (main sprite)
HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM     # 3000 (flames, moving parts)

# Overlay layers
HexFlowRendering.RENDER_HEIGHT_NODE            # 100000 (circuit nodes)
HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE    # 101000 (UI overlays)
```

Always add `render_height_offset` parameter to base heights for composability:
```julia
function render_base_elem!(queue, behav; render_height_offset::Integer=0, kwargs...)
    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + 
                    Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :MySprite, rotation, position, 
                                   draw_height = static_height))
    return nothing
end
```

**Fluid colors**: Use `get_fluid_colour` from `HexFlowRendering`:
```julia
# Basic usage (defaults to black for unknown fluids)
colour = get_fluid_colour(fluid)

# Override default
colour = get_fluid_colour(fluid; default = ColourType(1.0, 1.0, 1.0, 1.0))

# Black background for empty fluid masks
black = DEFAULT_EMPTY_FLUID_COLOUR  # exported from HexFlowRendering
```

**Rendering helpers** from `HexFlowRendering`:
```julia
# Tile rendering
render_basic_tile(glmap, sprite, rotation, position; colour, scale, transparency, draw_height)
render_liquid_tile(glmap, sprite, rotation, position, gameticks; ...)
render_gas_tile(glmap, sprite, rotation, position, gameticks; ...)

# Pipe rendering
render_basic_pipe(glmap, sprite, rotation, position; ...)

# Animation helpers
sprite = animation_sprite_picker(sprite_tuple, gameticks, speed_divisor)
offset = animation_vibe_offset(gameticks; speed, magnitude)
rotation_mat = animation_rotate(gameticks, speed)
```

### Using Accessors.jl

Use `@set` macro for immutable updates:
```julia
set_tunables(comp::MyComp, tunables) = @set comp.fragment = set_tunables(comp.fragment, tunables)
```

### Mutable State

When components need mutable state, use a separate mutable struct:
```julia
mutable struct MyState
    value::Float64
    counter::Int
end

struct MyFragment
    config::Float64
    state::MyState  # mutable state holder
end
```

Access state fields directly:
```julia
function update_flowbehav!(frag::MyFragment; kwargs...)
    frag.state.counter += 1  # mutate in place
    return nothing
end
```

## Fragment Composition Pattern

Build complex behaviors by composing small fragments:

```julia
# Define reusable fragments
struct SpriteFrag
    sprite::Symbol
end

struct ElementFrag
    elements::NTuple{N, RelativeElement}
end

# Compose into concrete behavior
struct MyCompBehav <: ComponentBehavior
    sprite::SpriteFrag
    elements::ElementFrag
    custom_data::Float64
end

# Delegate interface methods to fragments
produce_rel_elements(comp::MyCompBehav) = produce_rel_elements(comp.elements)
render_base_elem!(queue, comp::MyCompBehav; kwargs...) = render_base_elem!(queue, comp.sprite; kwargs...)
```

Benefits:
- Reuse common behaviors across components
- Separate concerns (rendering, physics, state management)
- Easier testing and maintenance
- Clear composition in type definitions

## Tips for New Components

1. **Start with fragments**: Identify reusable behaviors (sprite, elements, state)
2. **Check existing fragments**: Reuse from `HexFlowBasicComponents` when possible
3. **Implement mandatories first**: Get basic functionality working
4. **Add optionals as needed**: Override defaults for custom behavior
5. **Test with tunables**: Ensure `get_tunables`/`set_tunables` round-trip correctly
6. **Use delegation**: Forward to fragments, don't reimplement
7. **Follow naming**: `*BehavFrag`, `*CompBehav`, `*PipeBehav` patterns
8. **Document types**: Struct docstrings explain purpose and behavior
9. **Preserve immutability**: Use `@set` for updates, mutable structs only for state

## Example: Simple Component

```julia
module HexFlowExampleComponents

using Accessors
using HexFrame, HexElements, HexComponentsAPI, RenderEngine, HexFlowRendering

import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!

export SimpleCompBehav

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- SimpleCompBehav ----------- =#

"Simple component with one resistor and one sprite."
struct SimpleCompBehav <: ComponentBehavior
    sprite::Symbol
    resistance::Float64
end

function produce_rel_elements(comp::SimpleCompBehav)::NTuple{1, RelativeElement}
    connection = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG)
    conductance = 1.0 / comp.resistance
    element = RelativeElement(connection, conductance, HexElements.CONST_RESISTOR)
    return (element,)
end

function get_tunables(comp::SimpleCompBehav)::NTuple{1, TunableProps}
    return (TunableProps(comp.resistance, "Resistance", "Ω"),)
end

function set_tunables(comp::SimpleCompBehav, tunables::NTuple{1, Real})::SimpleCompBehav
    return SimpleCompBehav(comp.sprite, Float64(tunables[1]))
end

function render_base_elem!(queue::Vector{RenderCommand}, comp::SimpleCompBehav;
                          glmap, rotation, position, render_height_offset::Integer=0, kwargs...)
    height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, comp.sprite, rotation, position, draw_height=height))
    return nothing
end

end # module
```

## References

- **API Documentation**: See `HexComponentsAPI/src/HexComponentsAPI.jl` for complete interface definitions
- **Rendering Guide**: See `src/render_height.md` for layer height conventions
- **Example Implementations**: Review existing component packages for patterns
- **Component Instances**: See `src/components.jl` for usage examples

