#=
Scope: Nozzle, chamber, and exhaust-particle behaviours for propulsion components
Formatter: Runic
=#
"""
Nozzle and chamber component behaviours for thrust-generating propulsion systems.

Exported concrete `ComponentBehavior` implementations:

- `BasicNozzleCompBehav`: Fixed-sprite nozzle with thermal protection
- `SwitchedNozzleCompBehav`: Nozzle with an inlet switch for thrust control
- `DecompChamberCompBehav`: Monopropellant decomposition chamber
- `BipropChamberCompBehav`: Bipropellant combustion chamber
"""
module HexFlowNozzleComponents

using Accessors, StaticArrays
using FlowEngine, FlowMap, HexElements, HexFluids, HexFrame
using HexComponentsAPI, HexFlowBasicComponents, HexFlowSwitchComponents
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!

# `ComponentBehavior` optional methods
import HexComponentsAPI: on_click!, get_thrust, get_component_temperature, update_flowbehav!, render_map_elem!
import HexComponentsAPI: placement_valid, collect_effect_particles!, get_actions, do_action!
import HexComponentsAPI: produce_rel_fluid_declarations, map_mirroring

# Reactivation probe interface
import HexComponentsAPI: get_reactivation_probe, classify_reactivation_probe, commit_reactivation_probe!

# Behaviour fragment interfaces
import HexFlowBasicComponents: deactivate!, reactivate!, is_inactive, damage!, undamage!, is_damaged
import HexFlowBasicComponents: get_overheat_percentage, get_overheat_tint

# Behaviour Fragment Exports
export NozzleBehavFrag
# Concrete Component Behaviour Exports
export BasicNozzleCompBehav, SwitchedNozzleCompBehav, DecompChamberCompBehav, BipropChamberCompBehav

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- NozzleBehavFrag ----------- =#

"Nozzle fragment handling thrust, auto-deactivation, and overheat state"
struct NozzleBehavFrag
    connected_node::NodePos
    throat_area::Float64
    deactivation::AutoDeactivationBehavFrag
    overheat::OverheatLimitBehavFrag
end

# Nozzle thermal and probe tuning
const nozzle_element_index::Int = 1 # Nozzle resistor is always at index 1
const probe_tol = 1.0e-9 # Tolerance for probe current acceptance and deactivation detection
const DEFAULT_NOZZLE_LIMIT_TEMPERATURE_K = 3000.0
const SWITCHED_NOZZLE_LIMIT_TEMPERATURE_K = 400.0

default_nozzle_relative_scale(throat_area::Real)::Float64 = Float64(throat_area) / 0.2
default_nozzle_heat_loss_factor(throat_area::Real)::Float64 = 5.0 * default_nozzle_relative_scale(throat_area)
default_nozzle_thermal_mass(throat_area::Real)::Float64 = 2.0 * default_nozzle_relative_scale(throat_area)^(3 / 2)

"""
Build the default nozzle overheat fragment from throat area, with optional
thermal-model overrides for concrete nozzle behaviours.
"""
function default_nozzle_overheat(
        throat_area::Real;
        limit_temperature_k::Real = DEFAULT_NOZZLE_LIMIT_TEMPERATURE_K,
        thermal_mass::Union{Nothing, Real} = nothing,
        heat_loss_factor::Union{Nothing, Real} = nothing,
        temperature::ComponentTemperatureBehavFrag = ComponentTemperatureBehavFrag(),
        damage::DamageStateBehavFrag = DamageStateBehavFrag()
    )
    thermal_mass_f = isnothing(thermal_mass) ? default_nozzle_thermal_mass(throat_area) : Float64(thermal_mass)
    heat_loss_factor_f = isnothing(heat_loss_factor) ? default_nozzle_heat_loss_factor(throat_area) : Float64(heat_loss_factor)
    return OverheatLimitBehavFrag(limit_temperature_k, thermal_mass_f, heat_loss_factor_f; temperature = temperature, damage = damage)
end

function NozzleBehavFrag(connected_node::NodePos, throat_area::Real, deactivation::AutoDeactivationBehavFrag, overheat::OverheatLimitBehavFrag)
    return NozzleBehavFrag(connected_node, Float64(throat_area), deactivation, overheat)
end

function NozzleBehavFrag(connected_node::NodePos, throat_area::Real, overheat::OverheatLimitBehavFrag)
    return NozzleBehavFrag(connected_node, Float64(throat_area), AutoDeactivationBehavFrag(), overheat)
end

function NozzleBehavFrag(connected_node::NodePos, throat_area::Real)
    throat_area_f = Float64(throat_area)
    return NozzleBehavFrag(connected_node, throat_area_f, AutoDeactivationBehavFrag(), default_nozzle_overheat(throat_area_f))
end

is_inactive(nozzle::NozzleBehavFrag) = is_inactive(nozzle.deactivation)
deactivate!(nozzle::NozzleBehavFrag) = deactivate!(nozzle.deactivation)
reactivate!(nozzle::NozzleBehavFrag) = reactivate!(nozzle.deactivation)
is_damaged(nozzle::NozzleBehavFrag) = is_damaged(nozzle.overheat)
damage!(nozzle::NozzleBehavFrag) = damage!(nozzle.overheat)
undamage!(nozzle::NozzleBehavFrag) = undamage!(nozzle.overheat)
get_component_temperature(nozzle::NozzleBehavFrag)::Float64 = get_component_temperature(nozzle.overheat)
get_overheat_percentage(nozzle::NozzleBehavFrag)::Float64 = get_overheat_percentage(nozzle.overheat)
get_overheat_tint(nozzle::NozzleBehavFrag)::ColourType = get_overheat_tint(nozzle.overheat)

function produce_rel_elements(nozzle::NozzleBehavFrag)::NTuple{1, RelativeElement}
    is_active::Bool = !is_inactive(nozzle) && !is_damaged(nozzle)
    node = nozzle.connected_node
    throat_area = nozzle.throat_area

    conductance = throat_area^2
    relconnection = RelativeElementConnections(node, HexFrame.GROUND)
    rel_elem = RelativeElement(relconnection, conductance, HexElements.CONST_RESISTOR; active = is_active)
    return (rel_elem,)
end

function get_tunables(nozzle::NozzleBehavFrag)::NTuple{4, TunableProps}
    throat_props = TunableProps(
        nozzle.throat_area,
        "Nozzle Throat Area",
        "sqrt(conductance)"
    )

    overheat_tunables = get_tunables(nozzle.overheat)
    return (throat_props, overheat_tunables[1], overheat_tunables[2], overheat_tunables[3])
end

function set_tunables(nozzle::NozzleBehavFrag, tunables::NTuple{4, T})::NozzleBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    new_overheat = set_tunables(nozzle.overheat, (float_vals[2], float_vals[3], float_vals[4]))
    return NozzleBehavFrag(
        nozzle.connected_node,
        float_vals[1], # throat area
        nozzle.deactivation,
        new_overheat
    )
end

"""
Resolve nozzle thrust from solved inlet pressure, flow, and fluid properties.

Nozzles always thrust along local `Q_POS`; component rotation maps that local
direction into world space.
"""
function get_thrust(nozzle::NozzleBehavFrag; tile::TileCoord, rotation::HexAxis, mna_state::MNA_State, derivedmapstate::DerivedMapState, kwargs...)
    if is_inactive(nozzle) || is_damaged(nozzle)
        return SVector{2, Float64}(0.0, 0.0)
    end

    # Solve the inlet state
    nozzle_throat_area = nozzle.throat_area
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    nozzle_input_pressure = get(mna_state.node_voltages, nozzle_input_node, 0.0)
    nozzle_conductance = first(produce_rel_elements(nozzle)).value
    nozzle_flow = nozzle_input_pressure * nozzle_conductance

    # Look up the inlet fluid and thermal state
    fluid = get(derivedmapstate.nodeactualfluids, nozzle_input_node, nothing)
    density = !isnothing(fluid) ? lookup_fluid_density(fluid) : nothing
    fluid_temperature_k = get(derivedmapstate.node_temperatures, nozzle_input_node, THERMAL_AMBIENT_TEMPERATURE_K)
    exhaust_velocity = !isnothing(fluid) ? lookup_fluid_exhaust_velocity(fluid, fluid_temperature_k) : nothing

    # Reject missing fluid properties
    if isnothing(density) || isnothing(exhaust_velocity)
        if abs(nozzle_flow) > 1.0e-6
            error("Nozzle at tile $tile has significant flow ($nozzle_flow) but fluid properties could not be found for fluid '$fluid'. Ensure lookup_fluid_density and lookup_fluid_exhaust_velocity are defined for this fluid.")
        end
        return SVector{2, Float64}(0.0, 0.0)
    end

    # Combine the pressure and momentum contributions
    momentum_component = density * nozzle_flow * exhaust_velocity
    pressure_component = nozzle_throat_area * nozzle_input_pressure
    thrust_magnitude = momentum_component + pressure_component

    # Calculate thrust direction based on component rotation.
    # NOTE: This assumes all nozzles produce thrust in the Q_POS direction in their local frame,
    # which is then rotated by the component's rotation parameter. This matches the current
    # component definitions where all nozzles have connected_node = NODE_Q_POS (or equivalent)
    # and works correctly for switched nozzles that use NODE_INTERNAL_1.
    rotation_matrix = hex_rotmats[rotation]
    base_vector = SVector{2, Float64}(1.0, 0.0)
    direction_vector = rotation_matrix * base_vector

    return thrust_magnitude * direction_vector
end

get_actions(nozzle::NozzleBehavFrag; kwargs...) = get_actions(nozzle.overheat; kwargs...)

function do_action!(nozzle::NozzleBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :repair_component
        return do_action!(nozzle.overheat, action_id; kwargs...)
    end
    throw(ArgumentError("Action :$(action_id) not recognised by NozzleBehavFrag"))
end

"Return a one-element probe for the speculative reactivation scheduler, or `nothing` if already active or damaged."
function get_reactivation_probe(nozzle::NozzleBehavFrag; kwargs...)
    is_inactive(nozzle) || return nothing
    is_damaged(nozzle) && return nothing
    node = nozzle.connected_node
    conductance = nozzle.throat_area^2
    probe_elem = RelativeElement(
        RelativeElementConnections(node, HexFrame.GROUND),
        conductance,
        HexElements.CONST_RESISTOR;
        active = true
    )
    return ReactivationProbe((probe_elem,))
end

"""
Classify nozzle reactivation from speculative flow.
Positive non-trivial flow is useful, reverse flow is harmful, and zero or pruned flow is neutral.
"""
function classify_reactivation_probe(nozzle::NozzleBehavFrag; tile::TileCoord, rotation::HexAxis, derivedmapstate::DerivedMapState, mna_state, kwargs...)
    probe_rel_elem = RelativeElement(
        RelativeElementConnections(nozzle.connected_node, HexFrame.GROUND),
        nozzle.throat_area^2,
        HexElements.CONST_RESISTOR;
        active = true
    )
    probe_abs_elem = map_element(probe_rel_elem, tile, nozzle_element_index, rotation)
    probe_current = abs_element_get_current(probe_abs_elem, derivedmapstate, mna_state)
    isnothing(probe_current) && return HexComponentsAPI.PROBE_NEUTRAL
    probe_current > probe_tol && return HexComponentsAPI.PROBE_USEFUL
    probe_current < -probe_tol && return HexComponentsAPI.PROBE_HARMFUL
    return HexComponentsAPI.PROBE_NEUTRAL
end

function commit_reactivation_probe!(nozzle::NozzleBehavFrag; kwargs...)
    reactivate!(nozzle)
    return nothing
end

function update_flowbehav!(nozzle::NozzleBehavFrag; rotation::HexAxis, tile::TileCoord, mna_state::MNA_State, derivedmapstate::DerivedMapState, kwargs...)
    # Get the voltage at the nozzle's connected node
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    nozzle_input_pressure = get(mna_state.node_voltages, nozzle_input_node, 0.0)

    # Thermal state uses the previous solved tick's flow and temperature fields.
    fluid_temperature_k = get(derivedmapstate.node_temperatures, nozzle_input_node, THERMAL_AMBIENT_TEMPERATURE_K)
    fluid = get(derivedmapstate.nodeactualfluids, nozzle_input_node, nothing)
    mass_flow_rate = 0.0
    if !isnothing(fluid)
        nozzle_rel_element = produce_rel_elements(nozzle)[nozzle_element_index]
        nozzle_abs_element = map_element(nozzle_rel_element, tile, nozzle_element_index, rotation)
        nozzle_current = something(abs_element_get_current(nozzle_abs_element, derivedmapstate, mna_state), 0.0)
        fluid_density = something(lookup_fluid_density(fluid), 0.0)
        mass_flow_rate = max(nozzle_current, 0.0) * fluid_density
    end
    update_overheat_state!(nozzle.overheat; fluid_temperature_k = fluid_temperature_k, mass_flow_rate = mass_flow_rate)

    # Deactivate when reverse flow is detected; the reactivation scheduler will restore it once safe.
    if nozzle_input_pressure < -probe_tol
        deactivate!(nozzle)
    end
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, nozzle::NozzleBehavFrag; kwargs...)
    render_map_elem!(queue, nozzle.overheat; kwargs...)
    return nothing
end

function placement_valid(nozzle::NozzleBehavFrag, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    # Nozzles must hang off ship edges - their input node must be on surface, but the nozzle tile itself must not be
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return InvalidRequest("Nozzles must be placed on a ship edge with their input connected to the surface")
    end

    # Check that the input node IS connected to the ship surface
    input_node_abs = map_element(nozzle.connected_node, coord, rotation)
    if !is_node_on_ship_surface(input_node_abs, gamemap; ship_name = ship_name)
        return InvalidRequest("Nozzles must be placed on a ship edge with their input connected to the surface")
    end

    return ValidRequest()
end

function collect_effect_particles!(
        manager,
        nozzle::NozzleBehavFrag;
        tile::TileCoord,
        rotation::HexAxis,
        derivedmapstate::DerivedMapState,
        mna_state::MNA_StateSnapshot,
        gameticks::Int64,
        pos_offset = nothing,
        kwargs...
    )
    # Particle spawning parameters controlling the visual behaviour of particle exhaust
    max_particles_per_tick = 25
    x90_current_factor = 6.0  # Matches flame saturation behaviour

    # Spawn area (elliptical - narrower horizontally)
    spawn_radius_vertical_px = sqrt(nozzle.throat_area) * 120.0  # pixels per sqrt(throat_area)
    spawn_radius_horizontal_px = spawn_radius_vertical_px / 3.0   # 3x narrower horizontally

    # Velocity parameters
    base_velocity_magnitude = 0.05  # hex units per tick
    horizontal_velocity_randomness = 0.02  # randomness in exhaust direction
    perpendicular_velocity_randomness = 0.03  # randomness perpendicular to exhaust

    # Particle lifetime
    particle_lifetime = Int(2 * BASE_UPS)  # ticks (2 seconds at BASE_UPS)

    # Returns a smooth curve for x >= 0 that rises towards 1.0 and reaches 90% at x90.
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
    exhaust_direction = SVector{2, Float64}(-thrust_direction[1], thrust_direction[2]) # Particles move opposite to thrust (negate X for screen-space convention)
    perpendicular_direction = SVector{2, Float64}(-exhaust_direction[2], exhaust_direction[1]) # Perpendicular direction for randomness (rotated 90 degrees)

    # Get fluid colour
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, nozzle_input_node, nothing)
    temperature = get(derivedmapstate.node_temperatures, nozzle_input_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    fluid_colour_full = get_fluid_colour(fluid, temperature; default = ColourType(1.0, 1.0, 1.0, 1.0))
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

    # Spawn particles with colour
    spawn_particles!(manager, positions, velocities, gameticks, gameticks + particle_lifetime; colour = particle_colour)

    return nothing
end

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- BasicNozzleCompBehav ----------- =#

"Basic nozzle component with a fixed sprite and nozzle fragment"
struct BasicNozzleCompBehav <: ComponentBehavior
    nozzle::NozzleBehavFrag
    sprite::PlainSpriteBehavFrag
end

function BasicNozzleCompBehav(;
        connected_node::NodePos,
        throat_area::Float64,
        sprite::Symbol,
        limit_temperature_k::Float64 = DEFAULT_NOZZLE_LIMIT_TEMPERATURE_K,
        thermal_mass::Union{Nothing, Float64} = nothing,
        heat_loss_factor::Union{Nothing, Float64} = nothing
    )
    nozzlefrag = NozzleBehavFrag(
        connected_node,
        throat_area,
        AutoDeactivationBehavFrag(),
        default_nozzle_overheat(
            throat_area;
            limit_temperature_k = limit_temperature_k,
            thermal_mass = thermal_mass,
            heat_loss_factor = heat_loss_factor
        )
    )
    spritefrag = PlainSpriteBehavFrag(sprite)
    return BasicNozzleCompBehav(nozzlefrag, spritefrag)
end

produce_rel_elements(comp::BasicNozzleCompBehav) = produce_rel_elements(comp.nozzle)
get_tunables(comp::BasicNozzleCompBehav) = get_tunables(comp.nozzle)
set_tunables(comp::BasicNozzleCompBehav, tunables::NTuple{4, Real}) = @set comp.nozzle = set_tunables(comp.nozzle, tunables)
function produce_rel_fluid_declarations(comp::BasicNozzleCompBehav)
    return (RelativeFluidDeclaration(comp.nozzle.connected_node, HexFluids.FluidConstraintRule(HexFluids.IS_GAS)),)
end
get_thrust(comp::BasicNozzleCompBehav; kwargs...) = get_thrust(comp.nozzle; kwargs...)
get_component_temperature(comp::BasicNozzleCompBehav; kwargs...) = get_component_temperature(comp.nozzle)
get_actions(comp::BasicNozzleCompBehav; kwargs...) = get_actions(comp.nozzle; kwargs...)
do_action!(comp::BasicNozzleCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.nozzle, action_id; kwargs...)
update_flowbehav!(comp::BasicNozzleCompBehav; kwargs...) = update_flowbehav!(comp.nozzle; kwargs...)
get_reactivation_probe(comp::BasicNozzleCompBehav; kwargs...) = get_reactivation_probe(comp.nozzle; kwargs...)
classify_reactivation_probe(comp::BasicNozzleCompBehav; kwargs...) = classify_reactivation_probe(comp.nozzle; kwargs...)
commit_reactivation_probe!(comp::BasicNozzleCompBehav; kwargs...) = commit_reactivation_probe!(comp.nozzle; kwargs...)
render_base_elem!(queue::Vector{<:RenderCommand}, behav::BasicNozzleCompBehav; kwargs...) = render_base_elem!(queue, behav.sprite; kwargs...)
collect_effect_particles!(manager, comp::BasicNozzleCompBehav; kwargs...) = collect_effect_particles!(manager, comp.nozzle; kwargs...)
placement_valid(comp::BasicNozzleCompBehav, coord::TileCoord, gamemap::GameMap; kwargs...) = placement_valid(comp.nozzle, coord, gamemap; kwargs...)

function render_map_elem!(queue::Vector{<:RenderCommand}, behav::BasicNozzleCompBehav; kwargs...)
    render_base_elem!(queue, behav.sprite; kwargs...) # Render base sprite
    render_map_elem!(queue, behav.nozzle; kwargs...) # Delegate to nozzle for stall overlay
    return nothing
end

#= ---------- SwitchedNozzleCompBehav ----------- =#

"Nozzle component with an inlet switch for fine thrust control"
struct SwitchedNozzleCompBehav <: ComponentBehavior
    nozzle::NozzleBehavFrag
    switch::BoolSwitchBehavFrag
end

function SwitchedNozzleCompBehav(;
        throat_area::Float64,
        connected_node::NodePos,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64,
        limit_temperature_k::Float64 = SWITCHED_NOZZLE_LIMIT_TEMPERATURE_K,
        thermal_mass::Float64 = 1.0,
        heat_loss_factor::Float64 = 0.3
    )
    # Nozzle connects internal node to ground
    nozzlefrag = NozzleBehavFrag(
        HexFrame.NODE_INTERNAL_1,
        throat_area,
        AutoDeactivationBehavFrag(),
        default_nozzle_overheat(
            throat_area;
            limit_temperature_k = limit_temperature_k,
            thermal_mass = thermal_mass,
            heat_loss_factor = heat_loss_factor
        )
    )

    # Switch connects external node to internal node
    switch_connection = RelativeElementConnections(connected_node, HexFrame.NODE_INTERNAL_1)
    switchfrag = BoolSwitchBehavFrag(
        connection = switch_connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = min_conductance, # Start closed/off
        current_conductance = min_conductance
    )

    return SwitchedNozzleCompBehav(nozzlefrag, switchfrag)
end

# Combine elements from both switch and nozzle (nozzle first, then switch)
function produce_rel_elements(comp::SwitchedNozzleCompBehav)::NTuple{2, RelativeElement}
    switch_elements = produce_rel_elements(comp.switch)
    nozzle_elements = produce_rel_elements(comp.nozzle) # Nozzle at index 1 for particle spawning
    return (nozzle_elements[1], switch_elements[1])
end

# Combine tunables from both fragments (throat area + 3 overheat tunables + 3 switch tunables)
function get_tunables(comp::SwitchedNozzleCompBehav)::NTuple{7, TunableProps}
    nozzle_tunables = get_tunables(comp.nozzle)
    switch_tunables = get_tunables(comp.switch)
    return (
        nozzle_tunables[1],
        nozzle_tunables[2],
        nozzle_tunables[3],
        nozzle_tunables[4],
        switch_tunables[1],
        switch_tunables[2],
        switch_tunables[3],
    )
end

function set_tunables(comp::SwitchedNozzleCompBehav, tunables::NTuple{7, Real})::SwitchedNozzleCompBehav
    # Tunable order: throat area, temperature limit, thermal mass, heat loss factor, max conductance, min conductance, growth factor.
    nozzle_tunables = (tunables[1], tunables[2], tunables[3], tunables[4])
    switch_tunables = (tunables[5], tunables[6], tunables[7])

    new_nozzle = set_tunables(comp.nozzle, nozzle_tunables)
    new_switch = set_tunables(comp.switch, switch_tunables)

    return SwitchedNozzleCompBehav(new_nozzle, new_switch)
end

function produce_rel_fluid_declarations(comp::SwitchedNozzleCompBehav)
    connected_node = comp.switch.switch.connection.v1
    return (
        RelativeFluidDeclaration(connected_node, HexFluids.FluidConstraintRule(HexFluids.IS_GAS)),
        RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, HexFluids.FluidConstraintRule(HexFluids.IS_GAS)),
    )
end
get_thrust(comp::SwitchedNozzleCompBehav; kwargs...) = get_thrust(comp.nozzle; kwargs...)
get_component_temperature(comp::SwitchedNozzleCompBehav; kwargs...) = get_component_temperature(comp.nozzle)
collect_effect_particles!(manager, comp::SwitchedNozzleCompBehav; kwargs...) = collect_effect_particles!(manager, comp.nozzle; kwargs...)

function on_click!(comp::SwitchedNozzleCompBehav; kwargs...)
    # Always toggle the switch; auto-deactivation does not require manual reset.
    on_click!(comp.switch; kwargs...)
    return nothing
end

function get_actions(comp::SwitchedNozzleCompBehav; kwargs...)
    switch_actions = get_actions(comp.switch)
    nozzle_actions = get_actions(comp.nozzle)  # damage repair only (no unstall action)
    return (switch_actions..., nozzle_actions...)
end

function do_action!(comp::SwitchedNozzleCompBehav, action_id::Symbol; kwargs...)
    # Try switch actions first
    if action_id in (:open_valve, :close_valve)
        return do_action!(comp.switch, action_id)
    end
    # Then nozzle actions (damage repair)
    return do_action!(comp.nozzle, action_id)
end

function update_flowbehav!(comp::SwitchedNozzleCompBehav; kwargs...)
    update_flowbehav!(comp.nozzle; kwargs...) # Update both fragments
    update_flowbehav!(comp.switch; kwargs...)
    return nothing
end

get_reactivation_probe(comp::SwitchedNozzleCompBehav; kwargs...) = get_reactivation_probe(comp.nozzle; kwargs...)
classify_reactivation_probe(comp::SwitchedNozzleCompBehav; kwargs...) = classify_reactivation_probe(comp.nozzle; kwargs...)
commit_reactivation_probe!(comp::SwitchedNozzleCompBehav; kwargs...) = commit_reactivation_probe!(comp.nozzle; kwargs...)

function placement_valid(comp::SwitchedNozzleCompBehav, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    # For switched nozzles, check the switch's external connection node (v1).
    # The switch connects external node (v1) to internal node (v2), and nozzle connects internal to ground.
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return InvalidRequest("Nozzles must be placed on a ship edge with their input connected to the surface")
    end

    # Check that the input node IS connected to the ship surface
    input_node_pos = comp.switch.switch.connection.v1  # External node from switch
    input_node_abs = map_element(input_node_pos, coord, rotation)
    if !is_node_on_ship_surface(input_node_abs, gamemap; ship_name = ship_name)
        return InvalidRequest("Nozzles must be placed on a ship edge with their input connected to the surface")
    end

    return ValidRequest()
end

# Render valve sprite just under the main background sprite
function render_base_elem!(queue::Vector{<:RenderCommand}, comp::SwitchedNozzleCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    nozzle_tint = get_overheat_tint(comp.nozzle)
    base_colour = multiply_colours(colour, nozzle_tint)

    bkg_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_bkg, rotation, position; scale = scale, transparency = transparency, colour = base_colour, draw_height = bkg_height, pos_offset = pos_offset))

    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_valve, rotation, position; scale = scale, transparency = transparency, colour = base_colour, draw_height = valve_height, pos_offset = pos_offset))
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::SwitchedNozzleCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Get the connected external node for fluid lookup
    connected_node_pos = comp.switch.switch.connection.v1 # External node from switch connection
    connected_node = map_element(connected_node_pos, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, connected_node, nothing)
    temperature = get(derivedmapstate.node_temperatures, connected_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)

    # Render fluidmask with fluid colour (defaulting to black)
    fluidmask_colour = get_fluid_colour(fluid, temperature)
    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_fluidmask, rotation, position; colour = fluidmask_colour, draw_height = fluidmask_height, pos_offset = pos_offset))

    nozzle_tint = get_overheat_tint(comp.nozzle)

    # Render valve with position offset based on switch state (0% = no offset, 100% = 30px Y offset)
    switch_percentage = get_switch_percentage(comp.switch)
    valve_offset = SVector{2, Float32}(0.0, 30.0 * switch_percentage)
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_valve, rotation, position; colour = nozzle_tint, sprite_offset_tweak_px = valve_offset, draw_height = valve_height, pos_offset = pos_offset))

    # Render background sprite on top
    bkg_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :AllNozzles_SwitchedTinyNozzle_bkg, rotation, position; colour = nozzle_tint, draw_height = bkg_height, pos_offset = pos_offset))

    # Delegate to nozzle fragment for stall overlay (particles handled separately via collect_effect_particles!)
    render_map_elem!(queue, comp.nozzle; glmap = glmap, rotation = rotation, position = position, render_height_offset = render_height_offset, pos_offset = pos_offset)

    return nothing
end

#= ---------- DecompChamberCompBehav ----------- =#

const decomp_voltage_element_index::Int = 1  # Voltage source element index for current detection

"Decomposition chamber that expands monopropellant liquid into gas with animated fluid overlays"
struct DecompChamberCompBehav <: ComponentBehavior
    output_temperature::Float64
end

DecompChamberCompBehav() = DecompChamberCompBehav(800.0)

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

function produce_rel_fluid_declarations(comp::DecompChamberCompBehav)
    return (
        RelativeFluidDeclaration(HexFrame.NODE_Q_POS, HexFluids.FluidTypeRule(HexFluids.MONOPROP_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, HexFluids.FluidSource(HexFluids.MONOPROP_GAS, comp.output_temperature)),
    )
end

function get_tunables(comp::DecompChamberCompBehav)::NTuple{1, TunableProps}
    output_temp_props = TunableProps(comp.output_temperature, "Output Temperature", "K")
    return (output_temp_props,)
end

function set_tunables(::DecompChamberCompBehav, tunables::NTuple{1, T})::DecompChamberCompBehav where {T <: Real}
    return DecompChamberCompBehav(Float64(tunables[1]))
end

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::DecompChamberCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render gas fluidmask in black as background
    gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_gas_fluidmask, rotation, position; colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = gas_height, pos_offset = pos_offset))

    # Render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_frame, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::DecompChamberCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    # Detect current flow through the voltage source element
    voltage_element_current = get(mna_state.vsource_currents, ElementID(position, decomp_voltage_element_index), 0.0)
    non_trivial_current = abs(voltage_element_current) > 0.02

    # Get liquid fluid colour from NODE_Q_POS
    liquid_node = map_element(HexFrame.NODE_Q_POS, position, rotation)
    liquid_fluid = get(derivedmapstate.nodeactualfluids, liquid_node, nothing)
    liquid_temperature = get(derivedmapstate.node_temperatures, liquid_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    liquid_colour = get_fluid_colour(liquid_fluid, liquid_temperature)

    # Get gas fluid colour from NODE_Q_NEG
    gas_node = map_element(HexFrame.NODE_Q_NEG, position, rotation)
    gas_fluid = get(derivedmapstate.nodeactualfluids, gas_node, nothing)
    gas_temperature = get(derivedmapstate.node_temperatures, gas_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    gas_colour = get_fluid_colour(gas_fluid, gas_temperature)

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
        push!(queue, render_gas_tile(glmap, :DecompChamber1_gas_fluidmask, rotation, position, gameticks; colour = gas_colour, scale = scale, transparency = transparency * 0.2, draw_height = high_gas_height, pos_offset = pos_offset))
    end

    # Always render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :DecompChamber1_frame, rotation, position; scale = scale, transparency = transparency, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

#= ---------- BipropChamberCompBehav ----------- =#

const biprop_fuel_vcvs_index::Int = 1      # Fuel VCVS element index
const biprop_oxid_vcvs_index::Int = 2      # Oxidiser VCVS element index
const backflow_tolerance::Float64 = 0.02   # Tolerance for flow detection and backflow guard
const biprop_flow_threshold::Float64 = 1.0e-9  # Total-flow threshold guarding the limiting-reactant divide
const BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K::Float64 = 50.0  # Minimum temperature for unmixed propellants

"Mutable state for bipropellant chamber temperature and auto-deactivation"
mutable struct BipropChamberState
    output_temperature_state::Float64
    auto_deactivation::AutoDeactivationBehavFrag
end

"Bipropellant chamber with injector orifices feeding a shared exhaust output"
struct BipropChamberCompBehav <: ComponentBehavior
    fuel_conductance::Float64
    oxid_conductance::Float64
    r_optimal::Float64
    state::BipropChamberState
end

"""
Build a bipropellant chamber with fuel and oxidiser injector conductances plus
an optimal oxidiser-to-fuel flow ratio.

At equal upstream pressures, the nominal volumetric ratio is
`oxid_conductance / fuel_conductance`. The default values preserve the existing
2.5 ratio and keep the injector restriction below ordinary pipe conductance so
the orifice dominates inlet impedance.
"""
function BipropChamberCompBehav(; fuel_conductance::Float64 = 0.4, oxid_conductance::Float64 = 1.0, r_optimal::Float64 = 2.5)
    state = BipropChamberState(BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K, AutoDeactivationBehavFrag())
    return BipropChamberCompBehav(fuel_conductance, oxid_conductance, r_optimal, state)
end

"""
Build the chamber's six relative elements for either the live stamp or a
reactivation probe.

Keeping the stamp assembly in one place prevents the speculative trial solve
and the live component from drifting apart.
"""
function _build_biprop_elements(comp::BipropChamberCompBehav, active::Bool)::NTuple{6, RelativeElement}
    fuel_density = lookup_fluid_density(HexFluids.FUEL_LIQUID)::Float64
    oxid_density = lookup_fluid_density(HexFluids.OXIDISER_LIQUID)::Float64
    exhaust_density = lookup_fluid_density(HexFluids.BIPROP_EXHAUST)::Float64
    fuel_expansion_factor = fuel_density / exhaust_density
    oxid_expansion_factor = oxid_density / exhaust_density

    # Element 1: Fuel VCVS (NODE_INTERNAL_1 → GROUND), depends on element 3 (fuel CCCS)
    fuel_vcvs = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND),
        1.0, HexElements.V_DEP_VOLTAGE; dependent_index = 3, active = active,
    )

    # Element 2: Oxidiser VCVS (NODE_INTERNAL_2 → GROUND), depends on element 4 (oxid CCCS)
    oxid_vcvs = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_2, HexFrame.GROUND),
        1.0, HexElements.V_DEP_VOLTAGE; dependent_index = 4, active = active,
    )

    # Element 3: Fuel CCCS (PORT_OUT → GROUND), depends on element 1 (fuel VCVS)
    fuel_cccs = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_Q_NEG, HexFrame.GROUND),
        -fuel_expansion_factor, HexElements.C_DEP_CURRENT; dependent_index = 1, active = active,
    )

    # Element 4: Oxidiser CCCS (PORT_OUT → GROUND), depends on element 2 (oxid VCVS)
    oxid_cccs = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_Q_NEG, HexFrame.GROUND),
        -oxid_expansion_factor, HexElements.C_DEP_CURRENT; dependent_index = 2, active = active,
    )

    # Element 5: Fuel orifice resistor (PORT_FUEL → NODE_INTERNAL_1)
    fuel_orifice = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_R_NEG, HexFrame.NODE_INTERNAL_1),
        comp.fuel_conductance, HexElements.CONST_RESISTOR; active = active,
    )

    # Element 6: Oxidiser orifice resistor (PORT_OXID → NODE_INTERNAL_2)
    oxid_orifice = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_S_NEG, HexFrame.NODE_INTERNAL_2),
        comp.oxid_conductance, HexElements.CONST_RESISTOR; active = active,
    )

    return (fuel_vcvs, oxid_vcvs, fuel_cccs, oxid_cccs, fuel_orifice, oxid_orifice)
end

function produce_rel_elements(comp::BipropChamberCompBehav)::NTuple{6, RelativeElement}
    is_active::Bool = !is_inactive(comp.state.auto_deactivation)
    return _build_biprop_elements(comp, is_active)
end

function produce_rel_fluid_declarations(comp::BipropChamberCompBehav)
    return (
        RelativeFluidDeclaration(HexFrame.NODE_R_NEG, HexFluids.FluidTypeRule(HexFluids.FUEL_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_S_NEG, HexFluids.FluidTypeRule(HexFluids.OXIDISER_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, HexFluids.FluidSource(HexFluids.BIPROP_EXHAUST, comp.state.output_temperature_state)),
    )
end

function get_tunables(comp::BipropChamberCompBehav)::NTuple{3, TunableProps}
    fuel_cond_props = TunableProps(comp.fuel_conductance, "Fuel Conductance", "s²")
    oxid_cond_props = TunableProps(comp.oxid_conductance, "Oxidiser Conductance", "s²")
    r_optimal_props = TunableProps(comp.r_optimal, "Optimal Flow Ratio", "")
    return (fuel_cond_props, oxid_cond_props, r_optimal_props)
end

function set_tunables(comp::BipropChamberCompBehav, tunables::NTuple{3, T})::BipropChamberCompBehav where {T <: Real}
    fuel_cond = Float64(tunables[1])
    oxid_cond = Float64(tunables[2])
    r_opt = Float64(tunables[3])
    return BipropChamberCompBehav(fuel_cond, oxid_cond, r_opt, comp.state)
end

function update_flowbehav!(comp::BipropChamberCompBehav; rotation::HexAxis, tile::TileCoord, mna_state::MNA_State, derivedmapstate::DerivedMapState, kwargs...)
    t_min = BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K

    # Inactive chamber must not retain its previous combustion temperature
    if is_inactive(comp.state.auto_deactivation)
        comp.state.output_temperature_state = t_min
        return nothing
    end

    # Read VCVS currents to detect propellant flow rates
    fuel_current = get(mna_state.vsource_currents, ElementID(tile, biprop_fuel_vcvs_index), 0.0)
    oxid_current = get(mna_state.vsource_currents, ElementID(tile, biprop_oxid_vcvs_index), 0.0)

    # Deactivate on backflow (negative current beyond tolerance) on either leg
    if fuel_current < -backflow_tolerance || oxid_current < -backflow_tolerance
        deactivate!(comp.state.auto_deactivation)
        comp.state.output_temperature_state = t_min
        return nothing
    end

    # Combustion chamber temperature range: 50K (cold unmixed propellants) to 2300K (stoichiometric combustion)
    t_max_lookup = HexFluids.lookup_fluid_reference_temperature(HexFluids.BIPROP_EXHAUST)
    t_max = isnothing(t_max_lookup) ? t_min : t_max_lookup

    # Limiting-reactant combustion model on volumetric flows. Either flow at zero gives zero combustion.
    fuel_flow = max(fuel_current, 0.0)
    oxid_flow = max(oxid_current, 0.0)
    total_flow = fuel_flow + oxid_flow

    if total_flow < biprop_flow_threshold
        comp.state.output_temperature_state = t_min
        return nothing
    end

    combustible_fuel = min(fuel_flow, oxid_flow / comp.r_optimal)
    combusted_flow = combustible_fuel * (1.0 + comp.r_optimal)
    combustion_fraction = combusted_flow / total_flow
    comp.state.output_temperature_state = t_min + combustion_fraction * (t_max - t_min)

    return nothing
end

"""
Return a six-element probe for the speculative reactivation scheduler, or `nothing`
when the chamber is currently active.

The probe rebuilds the full chamber stamp (2 VCVS, 2 CCCS, 2 orifice resistors) so the
trial solve sees the same network the chamber would produce on its first live tick after
reactivation. Classification is decided in `classify_reactivation_probe` based on both legs
flowing forward.
"""
function get_reactivation_probe(comp::BipropChamberCompBehav; kwargs...)
    is_inactive(comp.state.auto_deactivation) || return nothing
    return ReactivationProbe(_build_biprop_elements(comp, true))
end

map_mirroring(::BipropChamberCompBehav, mirrored::Bool) = mirrored

"""
Classify chamber reactivation from speculative VCVS currents on both inlet legs.

This mirrors the live backflow guard in `update_flowbehav!`: either leg below
`-backflow_tolerance` is harmful, and missing speculative currents are neutral.
"""
function classify_reactivation_probe(comp::BipropChamberCompBehav; tile::TileCoord, rotation::HexAxis, derivedmapstate::DerivedMapState, mna_state, kwargs...)
    fuel_current = get(mna_state.vsource_currents, ElementID(tile, biprop_fuel_vcvs_index), nothing)
    oxid_current = get(mna_state.vsource_currents, ElementID(tile, biprop_oxid_vcvs_index), nothing)

    # If either VCVS was pruned out of the trial solve, currents won't be in the dict.
    # Treat that as neutral - we cannot prove forward flow.
    isnothing(fuel_current) && return HexComponentsAPI.PROBE_NEUTRAL
    isnothing(oxid_current) && return HexComponentsAPI.PROBE_NEUTRAL

    fuel_current < -backflow_tolerance && return HexComponentsAPI.PROBE_HARMFUL
    oxid_current < -backflow_tolerance && return HexComponentsAPI.PROBE_HARMFUL
    return HexComponentsAPI.PROBE_USEFUL
end

function commit_reactivation_probe!(comp::BipropChamberCompBehav; kwargs...)
    reactivate!(comp.state.auto_deactivation)
    return nothing
end

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::BipropChamberCompBehav; glmap::GLObjectMap, rotation::HexAxis, mirrored::Bool = false, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render gas fluidmask as black background
    gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :CombustionChamber1_gas_fluidmask, rotation, position; mirrored = mirrored, colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = gas_height, pos_offset = pos_offset))

    # Render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :CombustionChamber1_frame, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = colour, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::BipropChamberCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gameticks::Int64, rotation::HexAxis, mirrored::Bool = false, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    # Detect current flow through both VCVS elements
    fuel_current = get(mna_state.vsource_currents, ElementID(position, biprop_fuel_vcvs_index), 0.0)
    oxid_current = get(mna_state.vsource_currents, ElementID(position, biprop_oxid_vcvs_index), 0.0)
    non_trivial_fuel_current = abs(fuel_current) > backflow_tolerance
    non_trivial_oxid_current = abs(oxid_current) > backflow_tolerance

    # Get output gas colour from NODE_Q_NEG
    output_node = map_element(HexFrame.NODE_Q_NEG, position, rotation, mirrored)
    output_fluid = get(derivedmapstate.nodeactualfluids, output_node, nothing)
    output_temperature = get(derivedmapstate.node_temperatures, output_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    gas_colour = get_fluid_colour(output_fluid, output_temperature)

    # Get fuel and oxidiser colours from their input nodes
    fuel_node = map_element(HexFrame.NODE_R_NEG, position, rotation, mirrored)
    fuel_fluid = get(derivedmapstate.nodeactualfluids, fuel_node, nothing)
    fuel_temperature = get(derivedmapstate.node_temperatures, fuel_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    fuel_colour = get_fluid_colour(fuel_fluid, fuel_temperature)

    oxid_node = map_element(HexFrame.NODE_S_NEG, position, rotation, mirrored)
    oxid_fluid = get(derivedmapstate.nodeactualfluids, oxid_node, nothing)
    oxid_temperature = get(derivedmapstate.node_temperatures, oxid_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    oxid_colour = get_fluid_colour(oxid_fluid, oxid_temperature)

    # Always render gas fluidmask with basic shader (static background)
    low_gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_gas_tile(glmap, :CombustionChamber1_gas_fluidmask, rotation, position, gameticks; mirrored = mirrored, colour = gas_colour, scale = scale, transparency = transparency, draw_height = low_gas_height, pos_offset = pos_offset))

    # Render animated fuel fluidmask if fuel is flowing
    if non_trivial_fuel_current
        fuel_sprites = (:CombustionChamber1_fuel_fluidmask_1, :CombustionChamber1_fuel_fluidmask_2, :CombustionChamber1_fuel_fluidmask_3, :CombustionChamber1_fuel_fluidmask_4)
        fuel_sprite = animation_sprite_picker(fuel_sprites, gameticks, 4)
        fuel_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + Int32(render_height_offset)
        push!(queue, render_liquid_tile(glmap, fuel_sprite, rotation, position, gameticks; mirrored = mirrored, colour = fuel_colour, scale = scale, transparency = transparency, draw_height = fuel_height, pos_offset = pos_offset))
    end

    # Render animated oxidiser fluidmask if oxidiser is flowing (offset above fuel layer to avoid z-fighting)
    if non_trivial_oxid_current
        oxid_sprites = (:CombustionChamber1_ox_fluidmask_1, :CombustionChamber1_ox_fluidmask_2, :CombustionChamber1_ox_fluidmask_3, :CombustionChamber1_ox_fluidmask_4)
        oxid_sprite = animation_sprite_picker(oxid_sprites, gameticks, 4)
        oxid_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 110) + Int32(render_height_offset)
        push!(queue, render_liquid_tile(glmap, oxid_sprite, rotation, position, gameticks; mirrored = mirrored, colour = oxid_colour, scale = scale, transparency = transparency, draw_height = oxid_height, pos_offset = pos_offset))
    end

    # Render translucent gas overlay (combustion happening effect) if either liquid is flowing
    if non_trivial_fuel_current || non_trivial_oxid_current
        high_gas_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 200) + Int32(render_height_offset)
        push!(queue, render_gas_tile(glmap, :CombustionChamber1_gas_fluidmask, rotation, position, gameticks; mirrored = mirrored, colour = gas_colour, scale = scale, transparency = transparency * 0.2, draw_height = high_gas_height, pos_offset = pos_offset))
    end

    # Always render frame on top
    frame_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :CombustionChamber1_frame, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, draw_height = frame_height, pos_offset = pos_offset))

    return nothing
end

include("precompile_workload.jl")

end # module HexFlowNozzleComponents
