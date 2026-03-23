"""
Nozzle component implementations for thrust generation.

This module provides concrete implementations of ComponentBehavior for nozzles:
- BasicNozzleCompBehav: Simple nozzle with thrust generation
- SwitchedNozzleCompBehav: Nozzle with adjustable flow control
- DecompChamberCompBehav: Decompression chamber converting liquid to gas with animated effects

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowNozzleComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering
using StaticArrays
using HexFlowBasicComponents
using HexFlowSwitchComponents


# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: get_fluidtags, on_click!, get_thrust, update_flowbehav!, render_map_elem!, placement_valid, collect_effect_particles!, get_actions, do_action!
# Behavior Fragment Dependencies
import HexFlowBasicComponents: stall!, unstall!, is_stalled
import HexFlowSwitchComponents: get_switch_percentage

# Behavior Fragment Exports
export NozzleBehavFrag
# Concrete Component Behavior Exports
export BasicNozzleCompBehav, SwitchedNozzleCompBehav, DecompChamberCompBehav

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- NozzleBehavFrag ----------- =#

"Behavior fragment for nozzle components providing thrust generation and fluid exhaust"
struct NozzleBehavFrag
    connected_node::NodePos
    throat_area::Float64
    stallstate::StallBehavFrag
end

const nozzle_element_index::Int = 1 # Nozzle resistor is always at index 1

is_stalled(nozzle::NozzleBehavFrag) = is_stalled(nozzle.stallstate)
stall!(nozzle::NozzleBehavFrag) = stall!(nozzle.stallstate)
unstall!(nozzle::NozzleBehavFrag) = unstall!(nozzle.stallstate)

function produce_rel_elements(nozzle::NozzleBehavFrag)::NTuple{1, RelativeElement}
    is_active::Bool = !is_stalled(nozzle)
    node = nozzle.connected_node
    throat_area = nozzle.throat_area

    conductance = throat_area^2
    relconnection = RelativeElementConnections(node, HexFrame.GROUND)
    rel_elem = RelativeElement(relconnection, conductance, HexElements.CONST_RESISTOR; active = is_active)
    return (rel_elem,)
end

function get_tunables(nozzle::NozzleBehavFrag)::NTuple{1, TunableProps}
    throat_props = TunableProps(
        nozzle.throat_area,
        "Nozzle Throat Area",
        "sqrt(conductance)"
    )

    return (throat_props,)
end

function set_tunables(nozzle::NozzleBehavFrag, tunables::NTuple{1, T})::NozzleBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)

    newnozzle = NozzleBehavFrag(
        nozzle.connected_node,
        float_vals[1], # throat area
        nozzle.stallstate
    )
    return newnozzle
end

function get_thrust(nozzle::NozzleBehavFrag; tile::TileCoord, rotation::HexAxis, mna_state::MNA_State, derivedmapstate::DerivedMapState, kwargs...)
    # Get nozzle state
    nozzle_throat_area = nozzle.throat_area
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    nozzle_input_pressure = get(mna_state.node_voltages, nozzle_input_node, 0.0)
    nozzle_conductance = first(produce_rel_elements(nozzle)).value
    nozzle_flow = nozzle_input_pressure * nozzle_conductance

    # Look up the fluid at the nozzle's input node
    fluid = get(derivedmapstate.nodeactualfluids, nozzle_input_node, HexFluids.NONE)
    density = lookup_fluid_density(fluid)
    exhaust_velocity = lookup_fluid_exhaust_velocity(fluid)

    # If density or exhaust velocity is unknown, there's either no fluid connected or a new
    # fluid type was added without defining its physical properties
    if isnothing(density) || isnothing(exhaust_velocity)
        # If there's significant flow but no fluid properties, something is wrong
        if abs(nozzle_flow) > 1e-6
            error("Nozzle at tile $tile has significant flow ($nozzle_flow) but fluid properties could not be found for fluid tag '$fluid'. Ensure lookup_fluid_density and lookup_fluid_exhaust_velocity are defined for this fluid.")
        end
        return SVector{2, Float64}(0.0, 0.0)
    end

    nozzle_area_gain = 1.0

    # Thrust components: momentum thrust = mass flow rate × exhaust velocity
    momentum_component = density * nozzle_flow * exhaust_velocity
    # Pressure thrust = nozzle throat area × pressure at nozzle input
    pressure_component = nozzle_throat_area * nozzle_input_pressure * nozzle_area_gain
    # Total thrust magnitude is the sum of the momentum and pressure components
    thrust_magnitude = momentum_component + pressure_component

    # Calculate thrust direction based on component rotation.
    # NOTE: This assumes all nozzles produce thrust in the Q_POS direction in their local frame,
    # which is then rotated by the component's rotation parameter. This matches the current
    # component definitions where all nozzles have connected_node = NODE_Q_POS (or equivalent)
    # and works correctly for switched nozzles that use NODE_INTERNAL.
    rotation_matrix = hex_rotmats[rotation]
    base_vector = SVector{2, Float64}(1.0, 0.0)  # Unit vector in Q_POS direction (right)
    direction_vector = rotation_matrix * base_vector

    return thrust_magnitude * direction_vector # Scale by magnitude and return thrust vector
end

function on_click!(nozzle::NozzleBehavFrag; kwargs...)
    do_action!(nozzle, :unstall)
    return nothing
end

get_actions(nozzle::NozzleBehavFrag; kwargs...) = get_actions(nozzle.stallstate; kwargs...)
do_action!(nozzle::NozzleBehavFrag, action_id::Symbol; kwargs...) = do_action!(nozzle.stallstate, action_id; kwargs...)

function update_flowbehav!(nozzle::NozzleBehavFrag; rotation::HexAxis, tile::TileCoord, mna_state::MNA_State, kwargs...)
    # Get the voltage at the nozzle's connected node
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    nozzle_input_pressure = get(mna_state.node_voltages, nozzle_input_node, 0.0)

    # If the voltage is negative, current will be flowing backwards, so stall the nozzle
    if nozzle_input_pressure < 0.0
        stall!(nozzle)
    end
    return nothing
end

render_map_elem!(queue::Vector{RenderCommand}, nozzle::NozzleBehavFrag; kwargs...) = render_map_elem!(queue, nozzle.stallstate; kwargs...)

function placement_valid(nozzle::NozzleBehavFrag, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    # Nozzles must hang off ship edges - their input node must be on surface, but the nozzle tile itself must not be
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Nozzle must be placed off the ship surface (hanging off an edge)")
    end

    # Check that the input node IS connected to the ship surface
    input_node_abs = map_element(nozzle.connected_node, coord, rotation)
    if !is_node_on_ship_surface(input_node_abs, gamemap; ship_name = ship_name)
        return (false, "Nozzle input node is not connected to ship surface")
    end

    return (true, "")
end

function collect_effect_particles!(
        manager,
        nozzle::NozzleBehavFrag;
        tile::TileCoord,
        rotation::HexAxis,
        derivedmapstate::DerivedMapState,
        mna_state::MNA_State,
        gameticks::Int64,
        pos_offset = nothing,
        kwargs...
    )
    # Particle spawning parameters controlling the visual behavior of particle exhaust
    max_particles_per_tick = 25
    x90_current_factor = 6.0  # Matches flame saturation behavior

    # Spawn area (elliptical - narrower horizontally)
    spawn_radius_vertical_px = sqrt(nozzle.throat_area) * 120.0  # pixels per sqrt(throat_area)
    spawn_radius_horizontal_px = spawn_radius_vertical_px / 3.0   # 3x narrower horizontally

    # Velocity parameters
    base_velocity_magnitude = 0.05  # hex units per tick
    horizontal_velocity_randomness = 0.02  # randomness in exhaust direction
    perpendicular_velocity_randomness = 0.03  # randomness perpendicular to exhaust

    # Particle lifetime
    particle_lifetime = Int(2 * BASE_UPS)  # ticks (2 seconds at BASE_UPS)

    # Returns a smooth curve for x ≥ 0 that rises toward 1.0 and reaches 90% at x90
    exp_sat(x::Real, x90_sat::Real)::Float64 = 1 - exp(-log(10) * x / x90_sat)

    # Get nozzle flow state
    nozzle_rel_element = produce_rel_elements(nozzle)[nozzle_element_index]
    nozzle_abs_element = map_element(nozzle_rel_element, tile, nozzle_element_index, rotation)
    nozzle_current = something(abs_element_get_current(nozzle_abs_element, derivedmapstate, mna_state), 0.0)
    nozzle_current = max(nozzle_current, 0.0)

    # Calculate particle count
    ramp = exp_sat(nozzle_current, sqrt(nozzle.throat_area) * x90_current_factor)
    num_particles = floor(Int, ramp * max_particles_per_tick)

    if num_particles <= 0
        return nothing
    end

    # Get thrust direction (opposite of thrust force)
    rotation_matrix = hex_rotmats[rotation]
    base_vector = SVector{2, Float64}(1.0, 0.0)  # Unit vector in Q_POS direction (right)
    thrust_direction = rotation_matrix * base_vector
    exhaust_direction = SVector{2, Float64}(-thrust_direction[1], thrust_direction[2]) # Particles move opposite to thrust (negate Y to fix inversion)
    perpendicular_direction = SVector{2, Float64}(-exhaust_direction[2], exhaust_direction[1]) # Perpendicular direction for randomness (rotated 90 degrees)

    # Get fluid color
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, nozzle_input_node, HexFluids.NONE)
    fluid_colour_full = get_fluid_colour(fluid; default = ColourType(1.0, 1.0, 1.0, 1.0))
    particle_colour = SVector{4, Float32}(fluid_colour_full[1], fluid_colour_full[2], fluid_colour_full[3], 0.5f0) # Set alpha to 50%

    # Batch generate particles
    positions = Vector{SVector{2, Float32}}(undef, num_particles)
    velocities = Vector{SVector{2, Float64}}(undef, num_particles)

    tile_pos = glvec(tile)
    # Apply position offset if provided
    if !isnothing(pos_offset)
        offset_vec = glvec(pos_offset)
        tile_pos = tile_pos .+ offset_vec
    end

    # Convert spawn radii to hex units
    spawn_radius_vertical_hex = spawn_radius_vertical_px / HexFlowRendering.hex_size_pixels
    spawn_radius_horizontal_hex = spawn_radius_horizontal_px / HexFlowRendering.hex_size_pixels

    for i in 1:num_particles
        # Random position within elliptical spawn area
        angle = rand() * 2π
        radius_factor = sqrt(rand())  # sqrt for uniform distribution in circle

        # Offset in local coordinates (horizontal = along exhaust, vertical = perpendicular)
        local_horizontal = radius_factor * cos(angle) * spawn_radius_horizontal_hex
        local_vertical = radius_factor * sin(angle) * spawn_radius_vertical_hex

        # Transform to world coordinates using exhaust and perpendicular directions
        offset_vec = exhaust_direction .* local_horizontal .+ perpendicular_direction .* local_vertical
        offset = SVector{2, Float32}(Float32(offset_vec[1]), Float32(offset_vec[2]))
        positions[i] = tile_pos .+ offset

        # Velocity: base direction + randomness in both directions
        horizontal_component = (rand() - 0.5) * 2.0 * horizontal_velocity_randomness
        perp_component = (rand() - 0.5) * 2.0 * perpendicular_velocity_randomness
        velocities[i] = exhaust_direction .* (base_velocity_magnitude + horizontal_component) .+ perpendicular_direction .* perp_component
    end

    # Spawn particles with color
    spawn_particles!(manager, positions, velocities, gameticks, gameticks + particle_lifetime; colour = particle_colour)

    return nothing
end

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- BasicNozzleCompBehav ----------- =#

"Basic nozzle component with simple sprite and thrust generation"
struct BasicNozzleCompBehav <: ComponentBehavior
    nozzle::NozzleBehavFrag
    sprite::PlainSpriteBehavFrag
    fluid::FluidTagBehavFrag
end

function BasicNozzleCompBehav(;
        connected_node::NodePos,
        throat_area::Float64,
        sprite::Symbol
    )
    nozzlefrag = NozzleBehavFrag(connected_node, throat_area, StallBehavFrag())
    spritefrag = PlainSpriteBehavFrag(sprite)
    fluidnt = (; Symbol(connected_node) => HexFluids.ANY_GAS)
    fluidfrag = FluidTagBehavFrag(NodeFluidTags(; fluidnt...))

    return BasicNozzleCompBehav(nozzlefrag, spritefrag, fluidfrag)
end

produce_rel_elements(comp::BasicNozzleCompBehav) = produce_rel_elements(comp.nozzle)
get_tunables(comp::BasicNozzleCompBehav) = get_tunables(comp.nozzle)
set_tunables(comp::BasicNozzleCompBehav, tunables::NTuple{1, Real}) = @set comp.nozzle = set_tunables(comp.nozzle, tunables)
get_fluidtags(comp::BasicNozzleCompBehav) = get_fluidtags(comp.fluid)
get_thrust(comp::BasicNozzleCompBehav; kwargs...) = get_thrust(comp.nozzle; kwargs...)
on_click!(comp::BasicNozzleCompBehav; kwargs...) = on_click!(comp.nozzle; kwargs...)
get_actions(comp::BasicNozzleCompBehav; kwargs...) = get_actions(comp.nozzle; kwargs...)
do_action!(comp::BasicNozzleCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.nozzle, action_id; kwargs...)
update_flowbehav!(comp::BasicNozzleCompBehav; kwargs...) = update_flowbehav!(comp.nozzle; kwargs...)
render_base_elem!(queue::Vector{RenderCommand}, behav::BasicNozzleCompBehav; kwargs...) = render_base_elem!(queue, behav.sprite; kwargs...)
collect_effect_particles!(manager, comp::BasicNozzleCompBehav; kwargs...) = collect_effect_particles!(manager, comp.nozzle; kwargs...)
placement_valid(comp::BasicNozzleCompBehav, coord::TileCoord, gamemap::GameMap; kwargs...) = placement_valid(comp.nozzle, coord, gamemap; kwargs...)


function render_map_elem!(queue::Vector{RenderCommand}, behav::BasicNozzleCompBehav; kwargs...)
    render_base_elem!(queue, behav.sprite; kwargs...) # Render base sprite
    render_map_elem!(queue, behav.nozzle; kwargs...) # Delegate to nozzle for stall overlay
    return nothing
end

#= ---------- SwitchedNozzleCompBehav ----------- =#

"Nozzle component with a switch to control flow, allowing precise thrust control"
struct SwitchedNozzleCompBehav <: ComponentBehavior
    nozzle::NozzleBehavFrag
    switch::BoolSwitchBehavFrag
    fluid::FluidTagBehavFrag
end

function SwitchedNozzleCompBehav(;
        throat_area::Float64,
        connected_node::NodePos,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64
    )
    # Nozzle connects internal node to ground
    nozzlefrag = NozzleBehavFrag(HexFrame.NODE_INTERNAL, throat_area, StallBehavFrag())

    # Switch connects external node to internal node
    switch_connection = RelativeElementConnections(connected_node, HexFrame.NODE_INTERNAL)
    switchfrag = BoolSwitchBehavFrag(
        connection = switch_connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = min_conductance, # Start closed/off
        current_conductance = min_conductance
    )

    # Fluid tags for both connected node and internal node
    fluidnt = (;
        Symbol(connected_node) => HexFluids.ANY_GAS,
        Symbol(HexFrame.NODE_INTERNAL) => HexFluids.ANY_GAS,
    )
    fluidfrag = FluidTagBehavFrag(NodeFluidTags(; fluidnt...))

    return SwitchedNozzleCompBehav(nozzlefrag, switchfrag, fluidfrag)
end

# Combine elements from both switch and nozzle (nozzle first, then switch)
function produce_rel_elements(comp::SwitchedNozzleCompBehav)::NTuple{2, RelativeElement}
    switch_elements = produce_rel_elements(comp.switch)
    nozzle_elements = produce_rel_elements(comp.nozzle) # Nozzle at index 1 for particle spawning
    return (nozzle_elements[1], switch_elements[1])
end

# Combine tunables from both fragments (throat area + 3 switch tunables)
function get_tunables(comp::SwitchedNozzleCompBehav)::NTuple{4, TunableProps}
    nozzle_tunables = get_tunables(comp.nozzle)
    switch_tunables = get_tunables(comp.switch)
    return (nozzle_tunables[1], switch_tunables[1], switch_tunables[2], switch_tunables[3])
end

function set_tunables(comp::SwitchedNozzleCompBehav, tunables::NTuple{4, Real})::SwitchedNozzleCompBehav
    # First tunable is throat area, remaining 3 are switch tunables
    nozzle_tunables = (tunables[1],)
    switch_tunables = (tunables[2], tunables[3], tunables[4])

    new_nozzle = set_tunables(comp.nozzle, nozzle_tunables)
    new_switch = set_tunables(comp.switch, switch_tunables)

    return SwitchedNozzleCompBehav(new_nozzle, new_switch, comp.fluid)
end

get_fluidtags(comp::SwitchedNozzleCompBehav) = get_fluidtags(comp.fluid)
get_thrust(comp::SwitchedNozzleCompBehav; kwargs...) = get_thrust(comp.nozzle; kwargs...)
collect_effect_particles!(manager, comp::SwitchedNozzleCompBehav; kwargs...) = collect_effect_particles!(manager, comp.nozzle; kwargs...)

function on_click!(comp::SwitchedNozzleCompBehav; kwargs...)
    # If stalled, unstall the nozzle; otherwise toggle the switch
    if is_stalled(comp.nozzle)
        do_action!(comp.nozzle, :unstall)
    else
        on_click!(comp.switch; kwargs...) 
    end
    return nothing
end

function get_actions(comp::SwitchedNozzleCompBehav; kwargs...)
    switch_actions = get_actions(comp.switch)
    nozzle_actions = get_actions(comp.nozzle)
    return (switch_actions..., nozzle_actions...)
end

function do_action!(comp::SwitchedNozzleCompBehav, action_id::Symbol; kwargs...)
    # Try switch actions first
    if action_id in (:open_valve, :close_valve)
        return do_action!(comp.switch, action_id)
    end
    # Then nozzle actions
    return do_action!(comp.nozzle, action_id)
end

function update_flowbehav!(comp::SwitchedNozzleCompBehav; kwargs...)
    update_flowbehav!(comp.nozzle; kwargs...) # Update both fragments
    update_flowbehav!(comp.switch; kwargs...)
    return nothing
end

function placement_valid(comp::SwitchedNozzleCompBehav, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    # For switched nozzles, check the switch's external connection node (v1).
    # The switch connects external node (v1) to internal node (v2), and nozzle connects internal to ground.
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Nozzle must be placed off the ship surface (hanging off an edge)")
    end

    # Check that the input node IS connected to the ship surface
    input_node_pos = comp.switch.switch.connection.v1  # External node from switch
    input_node_abs = map_element(input_node_pos, coord, rotation)
    if !is_node_on_ship_surface(input_node_abs, gamemap; ship_name = ship_name)
        return (false, "Nozzle input node is not connected to ship surface")
    end

    return (true, "")
end

# Render valve sprite just under the main background sprite
function render_base_elem!(queue::Vector{RenderCommand}, comp::SwitchedNozzleCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    bkg_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_bkg, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = bkg_height, pos_offset = pos_offset))

    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_valve, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = valve_height, pos_offset = pos_offset))
    return nothing
end

function render_map_elem!(queue::Vector{RenderCommand}, comp::SwitchedNozzleCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Get the connected external node for fluid lookup
    connected_node_pos = comp.switch.switch.connection.v1 # External node from switch connection
    connected_node = map_element(connected_node_pos, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, connected_node, HexFluids.NONE)

    # Render fluidmask with fluid color (defaulting to black)
    fluidmask_colour = get_fluid_colour(fluid)
    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_fluidmask, rotation, position; colour = fluidmask_colour, draw_height = fluidmask_height, pos_offset = pos_offset))

    # Render valve with position offset based on switch state (0% = no offset, 100% = 30px Y offset)
    switch_percentage = get_switch_percentage(comp.switch)
    valve_offset = SVector{2, Float32}(0.0, 30.0 * switch_percentage)
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_valve, rotation, position; sprite_offset_tweak_px = valve_offset, draw_height = valve_height, pos_offset = pos_offset))

    # Render background sprite on top
    bkg_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_bkg, rotation, position; draw_height = bkg_height, pos_offset = pos_offset))

    # Delegate to nozzle fragment for stall overlay (particles handled separately via collect_effect_particles!)
    render_map_elem!(queue, comp.nozzle; glmap = glmap, rotation = rotation, position = position, render_height_offset = render_height_offset, pos_offset = pos_offset)

    return nothing
end

#= ---------- DecompChamberCompBehav ----------- =#

const decomp_voltage_element_index::Int = 1  # Voltage source element index for current detection

"Decomposition chamber that converts liquid to gas with animated fluid effects. Expansion factor is derived from fluid density ratio."
struct DecompChamberCompBehav <: ComponentBehavior end

function produce_rel_elements(comp::DecompChamberCompBehav)::NTuple{2, RelativeElement}
    # Compute expansion factor from density ratio (liquid density / gas density)
    # to maintain constant mass flow through the decomposition process
    liquid_density = lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    gas_density = lookup_fluid_density(HexFluids.MONOPROP_GAS)::Float64
    expansion_factor = liquid_density / gas_density

    # Voltage-dependent voltage source from liquid input to ground
    voltage_elem = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND),
        1.0, HexElements.V_DEP_VOLTAGE; dependent_index = 2
    )

    # Current-dependent current source from gas output to ground
    current_elem = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_Q_NEG, HexFrame.GROUND),
        -expansion_factor, HexElements.C_DEP_CURRENT; dependent_index = 1
    )

    return (voltage_elem, current_elem)
end

function get_fluidtags(comp::DecompChamberCompBehav)::NodeFluidTags
    return NodeFluidTags(
        NODE_Q_POS = HexFluids.MONOPROP_LIQUID,
        NODE_Q_NEG = HexFluids.MONOPROP_GAS
    )
end

get_tunables(::DecompChamberCompBehav)::Tuple{} = ()

set_tunables(comp::DecompChamberCompBehav, ::Tuple{})::DecompChamberCompBehav = comp

function render_base_elem!(queue::Vector{RenderCommand}, comp::DecompChamberCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render gas fluidmask in black as background
    gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_gas_fluidmask, rotation, position; colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = gas_height, pos_offset = pos_offset))

    # Render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_frame, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{RenderCommand}, comp::DecompChamberCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    # Detect current flow through the voltage source element
    voltage_element_current = get(mna_state.vsource_currents, ElementID(position, decomp_voltage_element_index), 0.0)
    non_trivial_current = abs(voltage_element_current) > 0.02

    # Get liquid fluid colour from NODE_Q_POS
    liquid_node = map_element(HexFrame.NODE_Q_POS, position, rotation)
    liquid_fluid = get(derivedmapstate.nodeactualfluids, liquid_node, HexFluids.NONE)
    liquid_colour = get_fluid_colour(liquid_fluid)

    # Get gas fluid colour from NODE_Q_NEG
    gas_node = map_element(HexFrame.NODE_Q_NEG, position, rotation)
    gas_fluid = get(derivedmapstate.nodeactualfluids, gas_node, HexFluids.NONE)
    gas_colour = get_fluid_colour(gas_fluid)

    # Always render gas fluidmask with basic shader (static background)
    low_gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_gas_tile(glmap, :DecompChamber1_gas_fluidmask, rotation, position, gameticks; colour = gas_colour, scale = scale, transparency = transparency, draw_height = low_gas_height, pos_offset = pos_offset))

    # Conditionally render animated liquid fluidmask if current is flowing, and add a transparent gas effect on top
    if non_trivial_current
        liquid_sprites = (:DecompChamber1_liquid_fluidmask_1, :DecompChamber1_liquid_fluidmask_2, :DecompChamber1_liquid_fluidmask_3, :DecompChamber1_liquid_fluidmask_4)
        liquid_sprite = animation_sprite_picker(liquid_sprites, gameticks, 4)

        liquid_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + Int32(render_height_offset)
        push!(queue, render_liquid_tile(glmap, liquid_sprite, rotation, position, gameticks; colour = liquid_colour, scale = scale, transparency = transparency, draw_height = liquid_height, pos_offset = pos_offset))

        high_gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 200) + Int32(render_height_offset)
        push!(queue, render_gas_tile(glmap, :DecompChamber1_gas_fluidmask, rotation, position, gameticks; colour = gas_colour, scale = scale, transparency = transparency*0.2, draw_height = high_gas_height, pos_offset = pos_offset))
    end

    # Always render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_frame, rotation, position; scale = scale, transparency = transparency, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

end # module HexFlowNozzleComponents
