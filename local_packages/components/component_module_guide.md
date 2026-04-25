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
import HexComponentsAPI: produce_rel_fluid_declarations, update_flowbehav!, render_map_elem!, on_click!, placement_valid 
import HexComponentsAPI: get_component_temperature, get_component_wet_mass, get_actions, do_action!, collect_effect_particles!
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
import HexComponentsAPI: get_fluidtags, update_flowbehav!, render_map_elem!, placement_valid, get_actions, do_action!
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

**Function docstrings**: Implementation packages usually do not need them
- Do not add function docstrings by default; the interface is already documented in `HexComponentsAPI`
- Add a function docstring only when it explains a novel behaviour, non-obvious contract, or reusable pattern that would be hard to infer from the signature and body
- Prefer inline comments inside complex bodies when the explanation is local to one implementation
- Constructor docstrings are optional and should only be added when validation or usage is not obvious:
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

# Push RenderCommands to queue for base (static) rendering.
# Preserve pos_offset so ship render offsets and docking offsets are applied.
render_base_elem!(queue::AbstractVector, behav::MyComp;
                  glmap, rotation, position, pos_offset = nothing,
                  scale = 1.0, transparency = 1.0,
                  render_height_offset::Integer = 0, kwargs...)::Nothing
```

### Optional Methods (with defaults)

Override as needed:

```julia
# Dynamic rendering (default: forwards to render_base_elem!)
render_map_elem!(queue::AbstractVector, behav::MyComp;
                 glmap, rotation, position, pos_offset = nothing,
                 kwargs...)::Nothing

# Fluid type constraints (default: NodeFluidTags())
get_fluidtags(behav)::NodeFluidTags

# Per-tick update logic (default: no-op)
update_flowbehav!(behav; kwargs...)

# Click handling (default: no-op)
on_click!(behav; kwargs...)

# Thrust calculation (default: zero vector)
get_thrust(behav; tile, rotation, mna_state, derivedmapstate, kwargs...)::SVector{2, Float64}

# Component-local temperature display hook (default: nothing)
get_component_temperature(behav; kwargs...)::Union{Nothing, Float64}

# Dry mass contribution. Override this for structural mass.
get_component_dry_mass(behav; kwargs...)::Float64

# Wet mass contribution. Override this for stored fluid mass.
get_component_wet_mass(behav; fluid::Union{FluidTags, Nothing} = nothing, kwargs...)::Float64

# Total mass. Prefer overriding dry and/or wet mass rather than this.
get_component_mass(behav; kwargs...)::Float64

# Right-click popup actions. Return a tuple of ActionInfo values.
get_actions(behav; kwargs...)

# Execute a right-click action. Return (success, message).
do_action!(behav, action_id::Symbol; kwargs...)::Tuple{Bool, String}

# Rotation mapping (default: identity)
map_rotation(behav, rotation::HexAxis)::HexAxis

# Move restrictions (default: (true, ""))
can_be_moved(behav; kwargs...)::(Bool, String)

# Placement restrictions beyond the default "must be on ship surface" rule.
placement_valid(behav, coord::TileCoord, gamemap::GameMap;
                rotation::HexAxis, ship_name::Symbol = :primary,
                kwargs...)::(Bool, String)

# Particle effects (default: no-op)
collect_effect_particles!(manager, behav; kwargs...)
```

Notes:
- `FlowMap` provides the default `placement_valid(..., gamemap::GameMap, ...)` implementation for normal surface placement. Override it only when the component has additional constraints, such as nozzles needing to hang off an edge.
- Mass queries in ship physics use `get_component_dry_mass` and `get_component_wet_mass`, so components that store fluid should normally implement the wet-mass hook rather than overriding `get_component_mass` directly.
- The action popup UI and calculator action command path use `get_actions` and `do_action!`, so interactive components should expose actions through those hooks rather than bespoke UI logic.

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

# Push RenderCommands for base rendering.
# Preserve pos_offset so ship render offsets and docking offsets are applied.
render_pipe_base!(queue::AbstractVector, behav::MyPipe;
                  glmap, rotation, position, pos_offset = nothing,
                  scale = 1.0, transparency = 1.0,
                  render_height_offset::Integer = 0, kwargs...)::Nothing
```

### Optional Methods

```julia
# Dynamic rendering (default: forwards to render_pipe_base!)
render_pipe_map!(queue::AbstractVector, behav::MyPipe;
                 glmap, rotation, position, pos_offset = nothing,
                 kwargs...)::Nothing

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

Always add `render_height_offset` to base heights for composability, and preserve `pos_offset` when forwarding to render helpers:
```julia
function render_base_elem!(queue::AbstractVector, behav;
        glmap, rotation, position, pos_offset = nothing,
        render_height_offset::Integer = 0, kwargs...)
    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) +
                    Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :MySprite, rotation, position;
                                   draw_height = static_height,
                                   pos_offset = pos_offset))
    return nothing
end
```

The renderer passes `pos_offset` during normal map rendering to account for per-ship render offsets, so custom render methods and delegation wrappers should thread it through rather than dropping it.

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
render_basic_tile(glmap, sprite, rotation, position; colour, scale, transparency, draw_height, pos_offset)
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
10. **Preserve render offsets**: If you override `render_base_elem!`, `render_map_elem!`, `render_pipe_base!`, or `render_pipe_map!`, thread `pos_offset` through every helper and delegate call
11. **Use the mass hooks deliberately**: Override `get_component_dry_mass` and `get_component_wet_mass` when the component contributes structural or stored-fluid mass
12. **Use action hooks for interactions**: Expose right-click actions through `get_actions` and `do_action!` instead of inventing ad-hoc UI paths

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

function render_base_elem!(queue::AbstractVector, comp::SimpleCompBehav;
                          glmap, rotation, position, pos_offset = nothing,
                          scale = 1.0, transparency = 1.0,
                          render_height_offset::Integer = 0, kwargs...)
    height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, comp.sprite, rotation, position;
                                   scale = scale,
                                   transparency = transparency,
                                   draw_height = height,
                                   pos_offset = pos_offset))
    return nothing
end

end # module
```

## References

- **API Documentation**: See `HexComponentsAPI/src/HexComponentsAPI.jl` for complete interface definitions
- **Rendering Guide**: See `src/render_height.md` for layer height conventions
- **Example Implementations**: Review existing component packages for patterns
- **Component Instances**: See `src/components.jl` for usage examples

