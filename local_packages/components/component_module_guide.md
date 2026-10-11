# Component Module Guide

This guide documents the standardised structure for component implementation
modules. Component modules define the behaviour, rendering, and interaction
logic for game components (tiles) and pipes (edges).

## Overview

Component modules are organised into packages under `local_packages/components/`:

- **API package**: `HexComponentsAPI` defines abstract interfaces and shared
  wrappers. Its source and tests are authoritative for method names and
  signatures.
- **Implementation packages**: provide concrete component and pipe behaviours.
- **Fragment pattern**: composes concrete behaviours from small, reusable
  fragments.

The examples below describe implementation modules. `HexComponentsAPI` may use
API-specific documentation and sections where this layout does not fit.

## Precompile Workloads

Implementation packages own compilation of API defaults and wrappers
specialised for their supported concrete `ComponentBehavior` and `PipeBehavior`
types. `HexComponentsAPI` owns interface definitions and generic behaviour
contracts; it needs no dedicated workload merely for abstract/default methods.
The root application will later own a small realistic workload for
heterogeneous and runtime-dispatch integration paths.

Place a package workload in `src/precompile_workload.jl` and include it near the
end of the package module, after its behaviour definitions. Add `PrecompileTools`
as a direct dependency and import its needed macros in the workload file.
Construct minimal deterministic fixtures under `@setup_workload` without
executing the API paths being precompiled, then call representative methods
under `@compile_workload`. Multiple compile-workload stages are appropriate
when target calls produce state needed by later target calls.
Prefer executing the methods to explicit `precompile(...)` signatures; document
any path that genuinely cannot be run safely during precompilation.

For each concrete specialisation actually supported or used by the game,
exercise mandatory methods, overridden optional hooks, and important
`PlacedComponent` or `PlacedPipe` paths, including `produce_abs_elements` where
applicable. Cover extra states only when they reach materially different
compilation or runtime dispatch. Tests can supply patterns for the smallest
valid map or solver state, but the workload should not repeat their behavioural
assertions or enumerate every value and action.

Rendering methods that only construct queued commands can use a fake
`GLObjectMap` with sprite metadata, without a display or GL execution. Keep
fixtures internal to the workload file unless repeated implementation needs
justify shared infrastructure. Avoid external I/O and lasting runtime side
effects. When dependencies load GLFW, use `JULIA_GLFW_PLATFORM=null` for
display-free verification rather than setting it in the workload. Update the
workload whenever a new concrete specialisation or materially new API
execution path is added.

## Module Structure

### File Organisation

```julia
#=
Scope: <Concise description of the file's responsibility>
Formatter: Runic
=#

"""
<Brief module purpose>

Exported concrete `<ComponentBehavior/PipeBehavior>` implementations:

- `<ConcreteType1>`: <brief description>
- `<ConcreteType2>`: <brief description>
"""
module ModuleName

using Accessors, StaticArrays
using FlowEngine, FlowMap, HexElements, HexFluids, HexFrame
using HexComponentsAPI, HexFlowBasicComponents
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: produce_rel_fluid_declarations, update_flowbehav, render_map_elem!, on_click, placement_valid
# Behaviour fragment interfaces
import HexFlowBasicComponents: stall, unstall

# Behaviour Fragment Exports
export FragmentType1, FragmentType2
# Helper Function Exports
export helper_function1, helper_function2
# Support Type Exports
export SupportType
# Concrete Component Behaviour Exports
export ConcreteType1, ConcreteType2

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- FragmentName ----------- =#

"Describe the fragment's purpose and important behaviour"
struct FragmentName
    field1::Type1
    field2::Type2  # inline comment explaining field
end

# Fragment methods...

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- ConcreteBehavName ----------- =#

"Describe the concrete component behaviour"
struct ConcreteBehavName <: ComponentBehavior
    fragment1::FragmentType1
    fragment2::FragmentType2
end

# Mandatory interface methods via delegation...
# Optional interface methods...

end # module
```

## Code Conventions

### Runic

The file header declares the formatter policy. Run Runic after editing a file
marked `Formatter: Runic`; do not run it automatically on an unmarked file or
change `Formatter: None` without an explicit decision. Adding a Runic marker to
an existing file is part of a deliberate style migration, not an ordinary
feature edit.

Choose the semantic layout, comments, and whitespace before formatting, then
inspect the complete result. In particular, confirm that imports and rendering
operations still follow the horizontal rules in this guide and that formatting
has not introduced unrelated churn.

### Section Dividers

Use consistent dividers to organise code. The normal major sections are
`Behaviour Fragments` and `Concrete Component Behaviours`, or `Concrete Pipe
Behaviours` for a pipe module.

**Major sections** provide top-level navigation:

```julia
# ===============================================================
# Section Name
# ===============================================================
```

**Minor sections** identify each primary fragment or concrete behaviour:

```julia
#= ---------- TypeName ----------- =#
```

Keep a primary type's closely related state holder, traits, constants, and
methods in its minor section. Use short ordinary comments such as `# Rendering`
and `# Reactivation probes` for method subgroups; do not promote every helper
category to another major section.

### Import and Export Organisation

Use broad `using` statements for types, constants, and functions that are only
called. Selectively import foreign functions whose method tables this module
extends. This makes the extension boundary explicit while keeping interface
definitions readable and unqualified.

Group `using` statements by dependency role in the order shown by the module
template: general third-party packages, simulation and data packages, component
packages, then rendering packages. Omit empty groups and order names
consistently within each group.

Import only methods actually extended by the module. Do not selectively import
types, constants, or functions merely because they are used, and do not
introduce package aliases merely to shorten interface method definitions.

Keep each `using` or `import Package: ...` statement on one physical line. When
a list benefits from separation, use multiple complete statements divided by
semantic role rather than a vertically hanging list of names:

```julia
# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: produce_rel_fluid_declarations, update_flowbehav, render_map_elem!, placement_valid, get_actions, do_action
# Reactivation probe interface
import HexComponentsAPI: get_reactivation_probe, classify_reactivation_probe, commit_reactivation_probe
# Behaviour fragment interfaces
import HexFlowBasicComponents: deactivate, reactivate, is_inactive
```

Do not add decorative `# === Imports ===` or `# === Exports ===` headings; the
dependency and export-category comments provide the useful navigation.

Qualification remains useful for sparse constants and exceptional extensions,
for example `HexComponentsAPI.PROBE_USEFUL` or `Base.convert`. It is not the
default for the component API.

Group exports by role and omit empty groups:

```julia
# Behaviour Fragment Exports
export MyFragment, MyOtherFragment
# Helper Function Exports
export helper_fn1, helper_fn2
# Support Type Exports
export MyState, MyTypeTag
# Concrete Component Behaviour Exports
export MyCompBehav, MyOtherCompBehav
```

### Naming Conventions

Follow consistent naming patterns:

- **Behaviour fragments**: `*BehavFrag` means a reusable composable unit providing
  a meaningful subset of component behaviour or API functionality (e.g.,
  `NozzleBehavFrag`, `DamageStateBehavFrag`). Nesting alone does not qualify.
- **Runtime state**: `*State` means immutable data expected to evolve during
  simulation (e.g., `SwitchState`, `ComponentTemperatureState`). State types are
  support types even when they have semantic transitions or trivial API getters.
- **Configuration/domain support**: ordinary names such as `Rotor` identify
  structures that are neither behaviour fragments nor runtime-state holders.
  Keep fixed parameters separate from related runtime values in a `state` field
  where this clarifies their boundary. State-only semantic fragments may hold a
  direct value, such as `DamageStateBehavFrag.damaged`.
- **Tile components**: `*CompBehav` (e.g., `BasicNozzleCompBehav`, `TurboPumpCompBehav`)
- **Pipe behaviours**: `*PipeBehav` (e.g., `ScrapPipeBehav`, `BigPipeBehav`)

### Documentation

An implementation module docstring contains a brief purpose statement followed
by an inventory of exactly the exported concrete `ComponentBehavior` or
`PipeBehavior` implementations. Do not list behaviour fragments, state types,
traits, helper functions, or application-level instances.

```julia
"""
Tank component behaviours for fluid storage.

Exported concrete `ComponentBehavior` implementations:

- `ThevininTankCompBehav`: Tank with a series resistor for gas or liquid storage
- `PressureFedTankCompBehav`: Coupled liquid-and-pressurant storage
"""
```

Document exported types and internal types whose purpose is not evident. Keep
the description concise and focus on behaviour or an important constraint:

```julia
"Shared conductance state and transition behaviour for switches"
struct SwitchBehavFrag
    connection::RelativeElementConnections
    max_conductance::Float64
    min_conductance::Float64
    change_rate::Float64  # inline comment explaining field
    state::SwitchState
end
```

`HexComponentsAPI` owns the general contract documentation for its interface.
Concrete implementation packages therefore do not need docstrings for
straightforward API implementations, pure delegation, obvious accessors, or
routine rendering methods. Add a concise docstring when it explains a reusable
helper, validation or compatibility behaviour, unusual physics, or another
non-obvious contract. Prefer local comments when the explanation applies to one
calculation inside the implementation.

### Field Comments

Use inline comments for field-level documentation:

```julia
struct MyFragment
    max_value::Float64  # Maximum allowed value
    state::MyState      # Immutable state value
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

# Return replacement reflecting the supplied editor values
set_tunables(behav::MyComp, tunables::NTuple{N, Real})::MyComp

# Push RenderCommands to the queue for base (static) rendering.
# Preserve pos_offset so ship and docking offsets are applied.
render_base_elem!(queue::AbstractVector, behav::MyComp; glmap, rotation, position, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...)::Nothing
```

### Optional Methods (with defaults)

Override as needed:

```julia
# Dynamic rendering (default: forwards to render_base_elem!)
render_map_elem!(queue::AbstractVector, behav::MyComp; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)::Nothing

# Fluid sources, type rules, and constraint rules (default: empty tuple)
produce_rel_fluid_declarations(behav)::Tuple

# Per-tick update returns a replacement (default: unchanged input)
update_flowbehav(behav; kwargs...)

# Click handling returns a replacement (default: unchanged input)
on_click(behav; kwargs...)

# Thrust calculation (default: zero vector)
get_thrust(behav; tile, rotation, mna_state, derivedmapstate, kwargs...)::SVector{2, Float64}

# Component-local temperature display hook (default: nothing)
get_component_temperature(behav; kwargs...)::Union{Nothing, Float64}

# Dry mass contribution. Override this for structural mass.
get_component_dry_mass(behav; kwargs...)::Float64

# Wet mass contribution. Override this for stored fluid mass.
get_component_wet_mass(behav; fluid::Union{FluidType, Nothing} = nothing, kwargs...)::Float64

# Total mass. Prefer overriding dry and/or wet mass rather than this.
get_component_mass(behav; kwargs...)::Float64

# Right-click popup actions. Return a tuple of ActionInfo values.
get_actions(behav; kwargs...)

# Execute a right-click action.
updated_behav, result = do_action(behav, action_id::Symbol; kwargs...)

# Successful action: (updated_behav, ValidRequestResult("message"))
# Expected rejection: (behav, InvalidRequest("reason"))
# Unsupported action IDs must throw ArgumentError.

# Rotation mapping (default: identity)
map_rotation(behav, rotation::HexAxis)::HexAxis

# Move restrictions (default: `ValidRequest()`)
can_be_moved(behav; kwargs...)::RequestStatus

# Placement restrictions beyond the default "must be on ship surface" rule.
placement_valid(behav, coord::TileCoord, gamemap::GameMap;
                rotation::HexAxis, ship_name::Symbol = :primary,
                kwargs...)::RequestStatus

# Particle effects (default: no-op)
collect_effect_particles!(manager, behav; kwargs...)
```

Notes:

- `FlowMap` provides the default `placement_valid(..., gamemap::GameMap, ...)`
  implementation for normal surface placement. Override it only when the
  component has additional constraints, such as nozzles needing to hang off an
  edge.
- Mass queries in ship physics use `get_component_dry_mass` and
  `get_component_wet_mass`, so components that store fluid should normally
  implement the wet-mass hook rather than overriding `get_component_mass`
  directly.
- The action popup UI and calculator action command path use `get_actions` and
  `do_action`, so interactive components should expose actions through those
  hooks rather than bespoke UI logic. The calculator logs exceptions for
  unsupported action IDs as programming failures; they are not player-facing
  action rejections.

`get_tunables` exposes values available to the placement editor and shown
read-only in the runtime inspector. These may include fixed configuration and
selected runtime/initial state, such as tank contents or pump speed.
`set_tunables` returns a replacement reflecting the supplied values.
`PlacedComponent` setters retain rotation, mirroring and ship ownership.

## PipeBehavior Interface

### Mandatory Methods

All pipe-segment behaviours must implement:

```julia
# Return pipe conductance
get_conductance(behav::MyPipe)::Float64

# Return tuple of TunableProps
get_pipe_tunables(behav::MyPipe)::NTuple{N, TunableProps}

# Return new pipe with updated tunables
set_pipe_tunables(behav::MyPipe, tunables::NTuple{N, Real})::MyPipe

# Push RenderCommands for base rendering.
# Preserve pos_offset so ship and docking offsets are applied.
render_pipe_base!(queue::AbstractVector, behav::MyPipe; glmap, rotation, position, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...)::Nothing

# Return half the rendered pipe width in map coordinate units
get_pipe_click_radius(behav::MyPipe)::Float64
```

### Optional Methods

```julia
# Dynamic rendering (default: forwards to render_pipe_base!)
render_pipe_map!(queue::AbstractVector, behav::MyPipe; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)::Nothing

# Move restrictions (default: `ValidRequest()`)
can_pipe_be_moved(behav; kwargs...)::RequestStatus

# Custom element generation (default: creates resistor from conductance)
produce_abs_elements(behav, pipe::PipeCoord)
```

## Common Patterns

### Element Index Constants

When referencing specific elements by index multiple times, define a module-local constant:

```julia
const nozzle_element_index::Int = 1  # Nozzle input element index
const pump_element_index::Int = 1    # Pump resistor element index
```

Keep these constants near the behaviour they support and before their first
use. They need not be immediately adjacent to the struct when a constructor or
related definitions make another order clearer. Do not export them.

### Keyword Argument Delegation

**Pure delegation** (forward all kwargs without modification):

```julia
get_thrust(comp::MyComp; kwargs...) = get_thrust(comp.nozzle; kwargs...)
update_flowbehav(comp::MyComp; kwargs...) = @set comp.fragment = update_flowbehav(comp.fragment; kwargs...)
```

**Extracting parameters** (only when the function needs them directly):

```julia
function update_flowbehav(tank::TankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    element_id = ElementID(tile, tank_vsource_element_index)
    # ... use tile and mna_state to calculate updated_charge
    return @set tank.charge = updated_charge
end
```

Pure delegation should forward `kwargs...` instead of restating defaults.
Render delegation may explicitly forward required visual arguments such as
`glmap`, `rotation`, `pos_offset`, and `render_height_offset` when doing so
protects the render-offset contract or prevents unrelated keywords from being
passed further down.

### Constructors

Prefer keyword constructors when callers configure several tunable values or
when names materially improve the call site. Positional constructors remain
appropriate for compact value-like types, dispatch, state reconstruction, and
compatibility with established call sites.

Lay constructor signatures out according to the normal semantic line-layout
guidance; do not require one parameter per line. Validate real invariants and
return the constructed value explicitly from long-form constructors:

```julia
"Keyword constructor with validation."
function MyFragment(; param1::Float64, param2::Float64, optional_param::Float64 = 1.0)
    param1 > 0.0 || throw(ArgumentError("param1 must be positive"))

    return MyFragment(param1, param2, optional_param)
end
```

### Rendering

**Render heights**: Use constants from `HexFlowRendering` (do not export, qualify with module name):

```julia
# Background elements
HexFlowRendering.RENDER_HEIGHT_BACKGROUND      # -1000

# Pipe layers
HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER # 10 (rank-band spacing)

# Component layers
HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND   # 1000 (fluid masks, energy bars)
HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC   # 2000 (main sprite)
HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM     # 3000 (flames, moving parts)

# Overlay layers
HexFlowRendering.RENDER_HEIGHT_NODE            # 100000 (circuit nodes)
HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE    # 101000 (UI overlays)
```

Every rendering-function signature and every call representing one rendering
operation stays on one physical line, regardless of length. This includes
nested operations such as `push!(queue, render_basic_tile(...))`. Keeping each
visual operation horizontal makes the render sequence easier to follow; setup
calculations and control flow inside the function still use normal semantic
layout.

Always add `render_height_offset` to base heights for composability, and
preserve `pos_offset` when forwarding to render helpers:

```julia
function render_base_elem!(queue::AbstractVector, behav; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :MySprite, rotation, position; draw_height = static_height, pos_offset = pos_offset))

    return nothing
end
```

The renderer passes `pos_offset` during normal map rendering to account for
per-ship render offsets, so custom render methods and delegation wrappers
should thread it through rather than dropping it.

**Fluid colours**: Use `get_fluid_colour` from `HexFlowRendering`:

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

### Immutable State

All state beneath a `ComponentBehavior` is immutable. Keep state holders and
fragment composition, with transitions at the lowest layer that owns the rules:

```julia
struct MyState
    value::Float64
    counter::Int
end

struct MyFragment
    config::Float64
    state::MyState
end

advance(state::MyState) = @set state.counter += 1

function update_flowbehav(frag::MyFragment; kwargs...)
    return @set frag.state = advance(frag.state)
end
```

Callers propagate replacements through enclosing fragments and `PlacedComponent`.
The mutable map boundary stores them with `set_component!`; a discarded return
value discards the state change. Transition names omit `!`, while operations
that mutate maps, rendering queues or particle managers retain it.

`do_action` returns `(updated_behaviour, result)`. Successful actions carry a
valid request result, expected rejections carry the unchanged input and an
invalid result, and unsupported IDs throw. Reactivation classification remains
pure; `commit_reactivation_probe` returns the replacement that the calculator
stores after accepting a useful probe. Existing calculator transactions handle
rejection and rollback on disposable working maps.

## Fragment Composition Pattern

Build complex behaviours by composing small fragments:

```julia
# Define reusable fragments
struct SpriteFrag
    sprite::Symbol
end

struct ElementFrag
    elements::NTuple{N, RelativeElement}
end

# Compose into concrete behaviour
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

- Reuse common behaviours across components
- Separate concerns (rendering, physics, state management)
- Easier testing and maintenance
- Clear composition in type definitions

## Tips for New Components

1. **Start with fragments**: Identify reusable behaviours (sprite, elements, state)
2. **Check existing fragments**: Reuse from `HexFlowBasicComponents` when possible
3. **Implement mandatory methods first**: Get basic functionality working
4. **Add optional overrides as needed**: Use a default only when its semantics are correct
5. **Test with tunables**: Ensure `get_tunables`/`set_tunables` round-trip correctly
6. **Use delegation**: Forward to fragments, don't reimplement
7. **Follow naming**: `*BehavFrag`, `*CompBehav`, `*PipeBehav` patterns
8. **Document types**: Struct docstrings explain purpose and behaviour
9. **Preserve immutability**: Use replacement transitions and immutable state throughout component fragments
10. **Preserve render offsets**: If you override `render_base_elem!`,
    `render_map_elem!`, `render_pipe_base!`, or `render_pipe_map!`, thread
    `pos_offset` through every helper and delegate call
11. **Use the mass hooks deliberately**: Override `get_component_dry_mass` and `get_component_wet_mass` when the component contributes structural or stored-fluid mass
12. **Use action hooks for interactions**: Expose right-click actions through `get_actions` and `do_action` instead of inventing ad-hoc UI paths
13. **Maintain precompile coverage**: Add supported concrete specialisations and materially new API paths to the package workload

## Example: Simple Component

```julia
#=
Scope: Example component behaviour and rendering
Formatter: Runic
=#

"""
Simple component behaviour for a fixed resistor tile.

Exported concrete `ComponentBehavior` implementations:

- `SimpleCompBehav`: Fixed resistor with a configurable sprite
"""
module HexFlowExampleComponents

using Accessors
using HexComponentsAPI, HexElements, HexFrame
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!

# Concrete Component Behaviour Exports
export SimpleCompBehav

# ===============================================================
# Concrete Component Behaviours
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

function render_base_elem!(queue::AbstractVector, comp::SimpleCompBehav; glmap, rotation, position, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...)
    height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, comp.sprite, rotation, position; scale = scale, transparency = transparency, draw_height = height, pos_offset = pos_offset))

    return nothing
end

end # module
```

## References

- **API Documentation**: See `HexComponentsAPI/src/HexComponentsAPI.jl` for complete interface definitions
- **Rendering Guide**: See `../../src/render_height.md` for layer height conventions
- **Example Implementations**: Review existing component packages for patterns
- **Component Instances**: See `../../src/components.jl` for usage examples
