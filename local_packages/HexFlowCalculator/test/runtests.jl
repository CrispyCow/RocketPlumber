using Test
using HexFlowCalculator
using FlowMap
using HexFrame
using HexFrame: Q_POS
using HexComponentsAPI
using HexFlowControl
using FlowEngine
using HexElements
using HexFlowProcGen
using HexFluids
using StaticArrays
using LinearAlgebra

include(joinpath(@__DIR__, "..", "..", "..", "src", "timelapse.jl"))
include(joinpath(@__DIR__, "..", "..", "..", "src", "map_loading.jl"))

"Minimal encounter config for tests that only need a SpaceMapState."
const _test_enc_config = EncounterSystemConfig()

"Minimal encounter config for tests that need a valid generated encounter ship."
function make_trigger_test_encounter_config()
    class_config = EncounterClassConfig(
        NoScaling(1.0),
        HullSizeConfig(LinearScaling(2.0, 0.0), LinearScaling(2.0, 0.0)),
        LinearScaling(0.0, 0.0),
        FluidTaggedEncounterComponents(Dict{FluidType, FuelTagConfig}(
            HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), WeightedComponentSet[]),
        )),
        PipeSpawnOptions[],
        NoScaling(1.0),
    )

    return EncounterSystemConfig(
        n_points = 1,
        encounter_class_configs = Dict(ENCOUNTER_SHIP => class_config),
    )
end

"Minimal encounter point for calculator-thread trigger tests."
function make_trigger_test_encounter_point()
    return EncounterPoint(
        index = 1,
        base_velocity = 100.0,
        position = SVector(500.0, 0.0),
        velocity = SVector(-100.0, 0.0),
        spawn_time = 0.0,
        ship_type_seed = UInt32(0x1234),
        encounter_class = ENCOUNTER_SHIP,
        fuel_tag = HexFluids.COLD_GAS,
        display_name = "Test Vessel",
        richness = 1.0,
    )
end

"Return the indexed side-span pipe bordering a tile."
side_pipe(tile::TileCoord, index::Integer = 1) = get_side_pipes(tile)[index]

# ===============================================================
# Mock Implementations
# ===============================================================

"""Minimal mock component for command-processing tests. Implements all mandatory
ComponentBehavior methods so sandbox validation (update_map!/update_mna!) succeeds."""
struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(::MockCompBehav, ::NTuple{0, Real}) = MockCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MockCompBehav; kwargs...) = nothing

struct FixedThrustCompBehav <: ComponentBehavior
    thrust::SVector{2, Float64}
end
HexComponentsAPI.produce_rel_elements(::FixedThrustCompBehav) = ()
HexComponentsAPI.get_tunables(::FixedThrustCompBehav) = ()
HexComponentsAPI.set_tunables(comp::FixedThrustCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::FixedThrustCompBehav; kwargs...) = nothing
HexComponentsAPI.get_component_dry_mass(::FixedThrustCompBehav) = 0.0
HexComponentsAPI.get_thrust(comp::FixedThrustCompBehav; kwargs...) = comp.thrust

"Minimal component carrying cold gas for calculator-owned delta-V cache tests."
struct DeltaVEstimateCompBehav <: ComponentBehavior
    dry_mass::Float64
    cold_gas_mass::Float64
end
HexComponentsAPI.produce_rel_elements(::DeltaVEstimateCompBehav) = ()
HexComponentsAPI.get_tunables(::DeltaVEstimateCompBehav) = ()
HexComponentsAPI.set_tunables(comp::DeltaVEstimateCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::DeltaVEstimateCompBehav; kwargs...) = nothing
HexComponentsAPI.get_component_dry_mass(comp::DeltaVEstimateCompBehav; kwargs...) = comp.dry_mass
function HexComponentsAPI.get_component_wet_mass(
        comp::DeltaVEstimateCompBehav;
        fluid::Union{Nothing, FluidType} = nothing,
        kwargs...,
    )::Float64
    return isnothing(fluid) || fluid == HexFluids.COLD_GAS ? comp.cold_gas_mass : 0.0
end

struct DerivedStateCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::DerivedStateCompBehav) = ()
HexComponentsAPI.get_tunables(::DerivedStateCompBehav) = ()
HexComponentsAPI.set_tunables(::DerivedStateCompBehav, ::NTuple{0, Real}) = DerivedStateCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::DerivedStateCompBehav; kwargs...) = nothing
function HexComponentsAPI.update_flowbehav!(::DerivedStateCompBehav; tile::TileCoord, derivedmapstate::DerivedMapState, kwargs...)
    derivedmapstate.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_INTERNAL_1)] = HexFluids.COLD_GAS
    return nothing
end

"""Minimal mock pipe for command-processing tests."""
struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::MockPipeBehav, ::NTuple{0, Real}) = MockPipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::MockPipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::MockPipeBehav) = 0.1

struct InvalidFluidBridgeCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::InvalidFluidBridgeCompBehav) = (
    RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 1.0, HexElements.CONST_RESISTOR),
    RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND), 1.0, HexElements.CONST_RESISTOR),
    RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_NEG, HexFrame.GROUND), 1.0, HexElements.CONST_RESISTOR),
)
HexComponentsAPI.produce_rel_fluid_declarations(::InvalidFluidBridgeCompBehav) = (
    RelativeFluidDeclaration(HexFrame.NODE_Q_POS, HexFluids.FluidSource(HexFluids.MONOPROP_GAS, 800.0)),
    RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID)),
)
HexComponentsAPI.get_tunables(::InvalidFluidBridgeCompBehav) = ()
HexComponentsAPI.set_tunables(::InvalidFluidBridgeCompBehav, ::NTuple{0, Real}) = InvalidFluidBridgeCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::InvalidFluidBridgeCompBehav; kwargs...) = nothing

struct GroundedAnchorCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::GroundedAnchorCompBehav) = (
    RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), 1.0, HexElements.CONST_RESISTOR),
)
HexComponentsAPI.get_tunables(::GroundedAnchorCompBehav) = ()
HexComponentsAPI.set_tunables(::GroundedAnchorCompBehav, ::NTuple{0, Real}) = GroundedAnchorCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::GroundedAnchorCompBehav; kwargs...) = nothing

mutable struct SingularProbeCompBehav <: ComponentBehavior
    accepted::Bool
end
HexComponentsAPI.produce_rel_elements(::SingularProbeCompBehav) = ()
HexComponentsAPI.get_tunables(::SingularProbeCompBehav) = ()
HexComponentsAPI.set_tunables(comp::SingularProbeCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::SingularProbeCompBehav; kwargs...) = nothing
function HexComponentsAPI.get_reactivation_probe(::SingularProbeCompBehav; kwargs...)
    return ReactivationProbe((
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), 1.0, HexElements.V_DEP_VOLTAGE; dependent_index = 2),
        RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND), -1.0, HexElements.C_DEP_CURRENT; dependent_index = 1),
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS), 1.0, HexElements.CONST_RESISTOR),
    ))
end
function HexComponentsAPI.classify_reactivation_probe(comp::SingularProbeCompBehav; kwargs...)
    return PROBE_USEFUL
end
function HexComponentsAPI.commit_reactivation_probe!(comp::SingularProbeCompBehav; kwargs...)
    comp.accepted = true
    return nothing
end

mutable struct BootstrapProbeCompBehav <: ComponentBehavior
    charge::Float64
    probe_voltage::Float64
    accepted::Bool
    force_active::Bool
end

function HexComponentsAPI.produce_rel_elements(comp::BootstrapProbeCompBehav)
    is_active = comp.charge > 0.0 || comp.force_active
    return (
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), comp.probe_voltage, HexElements.CONST_VOLTAGE; active = is_active),
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), 1.0, HexElements.CONST_RESISTOR; active = is_active),
    )
end

HexComponentsAPI.get_tunables(::BootstrapProbeCompBehav) = ()
HexComponentsAPI.set_tunables(comp::BootstrapProbeCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::BootstrapProbeCompBehav; kwargs...) = nothing

function HexComponentsAPI.get_reactivation_probe(comp::BootstrapProbeCompBehav; kwargs...)
    comp.charge > 0.0 && return nothing
    return ReactivationProbe((
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), comp.probe_voltage, HexElements.CONST_VOLTAGE),
        RelativeElement(RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND), 1.0, HexElements.CONST_RESISTOR),
    ))
end

function HexComponentsAPI.classify_reactivation_probe(comp::BootstrapProbeCompBehav;
        tile::TileCoord,
        rotation::HexAxis = HexFrame.Q_POS,
        derivedmapstate::DerivedMapState,
        mna_state,
        kwargs...)
    probe = get_reactivation_probe(comp)
    isnothing(probe) && return PROBE_HARMFUL

    abs_vsource = map_element(probe.rel_elements[1], tile, 1, rotation)
    current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
    return !isnothing(current) && abs(current) > 1e-9 ? PROBE_USEFUL : PROBE_NEUTRAL
end

function HexComponentsAPI.commit_reactivation_probe!(comp::BootstrapProbeCompBehav; kwargs...)
    comp.accepted = true
    comp.force_active = true
    return nothing
end

function HexComponentsAPI.update_flowbehav!(comp::BootstrapProbeCompBehav; tile::TileCoord, mna_state::MNA_State, kwargs...)
    vsource_id = ElementID(tile, 1)
    if !haskey(mna_state.vsources, vsource_id)
        comp.force_active = false
        return nothing
    end
    current = get(mna_state.vsource_currents, vsource_id, 0.0)
    comp.charge += abs(current) / BASE_UPS
    comp.force_active = false
    return nothing
end

mutable struct GroupedNeutralProbeCompBehav <: ComponentBehavior
    required_probe_count::Int
    committed::Bool
    active::Bool
    always_neutral::Bool
end

function HexComponentsAPI.produce_rel_elements(comp::GroupedNeutralProbeCompBehav)
    return (
        RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND),
            1.0,
            HexElements.CONST_RESISTOR;
            active = comp.active
        ),
    )
end

HexComponentsAPI.get_tunables(::GroupedNeutralProbeCompBehav) = ()
HexComponentsAPI.set_tunables(comp::GroupedNeutralProbeCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::GroupedNeutralProbeCompBehav; kwargs...) = nothing

function HexComponentsAPI.get_reactivation_probe(comp::GroupedNeutralProbeCompBehav; kwargs...)
    comp.active && return nothing
    return ReactivationProbe((
        RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND),
            1.0,
            HexElements.CONST_RESISTOR;
            active = true
        ),
    ))
end

function HexComponentsAPI.classify_reactivation_probe(comp::GroupedNeutralProbeCompBehav; derivedmapstate::DerivedMapState, kwargs...)
    comp.always_neutral && return PROBE_NEUTRAL
    return length(derivedmapstate.primaryelements) >= comp.required_probe_count ? PROBE_USEFUL : PROBE_NEUTRAL
end

function HexComponentsAPI.commit_reactivation_probe!(comp::GroupedNeutralProbeCompBehav; kwargs...)
    comp.committed = true
    comp.active = true
    return nothing
end

mutable struct HarmfulGroupedProbeCompBehav <: ComponentBehavior
    committed::Bool
end

HexComponentsAPI.produce_rel_elements(::HarmfulGroupedProbeCompBehav) = ()
HexComponentsAPI.get_tunables(::HarmfulGroupedProbeCompBehav) = ()
HexComponentsAPI.set_tunables(comp::HarmfulGroupedProbeCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::HarmfulGroupedProbeCompBehav; kwargs...) = nothing
function HexComponentsAPI.get_reactivation_probe(::HarmfulGroupedProbeCompBehav; kwargs...)
    return ReactivationProbe((
        RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND),
            1.0,
            HexElements.CONST_RESISTOR;
            active = true
        ),
    ))
end
HexComponentsAPI.classify_reactivation_probe(::HarmfulGroupedProbeCompBehav; kwargs...) = PROBE_HARMFUL
function HexComponentsAPI.commit_reactivation_probe!(comp::HarmfulGroupedProbeCompBehav; kwargs...)
    comp.committed = true
    return nothing
end

#= ---------- Additional Mock for DoActionCommand ----------- =#

# external counter for action execution
const action_count = Ref(0)

mutable struct ActionCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::ActionCompBehav) = ()
HexComponentsAPI.get_tunables(::ActionCompBehav) = ()
HexComponentsAPI.set_tunables(::ActionCompBehav, ::NTuple{0, Real}) = ActionCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::ActionCompBehav; kwargs...) = nothing
import HexComponentsAPI: get_actions, do_action!, placement_valid
function get_actions(comp::ActionCompBehav; kwargs...)
    return (ActionInfo(id = :flip, label = "Flip", enabled = true, tooltip = "Flip state"),)
end
function do_action!(comp::ActionCompBehav, action_id::Symbol; kwargs...)
    if action_id === :flip
        action_count[] += 1
        return ValidRequestResult("Flipped")
    end
    throw(ArgumentError("Unknown action"))
end

mutable struct StatefulActionCompBehav <: ComponentBehavior
    activations::Int
end
HexComponentsAPI.produce_rel_elements(::StatefulActionCompBehav) = ()
HexComponentsAPI.get_tunables(::StatefulActionCompBehav) = ()
HexComponentsAPI.set_tunables(comp::StatefulActionCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::StatefulActionCompBehav; kwargs...) = nothing
HexComponentsAPI.get_actions(::StatefulActionCompBehav; kwargs...) =
    (ActionInfo(id = :activate, label = "Activate", enabled = true, tooltip = "Activate action"),)
function HexComponentsAPI.do_action!(comp::StatefulActionCompBehav, ::Symbol; kwargs...)
    comp.activations += 1
    return ValidRequestResult("Activated")
end

mutable struct ActionValidationFailCompBehav <: ComponentBehavior
    activations::Int
end
HexComponentsAPI.produce_rel_elements(::ActionValidationFailCompBehav) = ()
HexComponentsAPI.get_tunables(::ActionValidationFailCompBehav) = ()
HexComponentsAPI.set_tunables(comp::ActionValidationFailCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::ActionValidationFailCompBehav; kwargs...) = nothing
HexComponentsAPI.get_actions(::ActionValidationFailCompBehav; kwargs...) =
    (ActionInfo(id = :activate, label = "Activate", enabled = true, tooltip = "Activate action"),)
function HexComponentsAPI.do_action!(comp::ActionValidationFailCompBehav, ::Symbol; kwargs...)
    comp.activations += 1
    return ValidRequestResult("Activated")
end
HexComponentsAPI.update_flowbehav!(::ActionValidationFailCompBehav; kwargs...) = error("candidate validation failed")

"Test-only expected candidate validation failure for exercising the warning policy."
struct ExpectedCandidateValidationError <: ExpectedMapValidationError end

"Render the test-only expected candidate validation explanation."
Base.showerror(io::IO, ::ExpectedCandidateValidationError) = print(io, "expected candidate validation failure")

struct ExpectedValidationFailCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::ExpectedValidationFailCompBehav) = ()
HexComponentsAPI.get_tunables(::ExpectedValidationFailCompBehav) = ()
HexComponentsAPI.set_tunables(
    ::ExpectedValidationFailCompBehav, ::NTuple{0, Real},
) = ExpectedValidationFailCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::ExpectedValidationFailCompBehav; kwargs...) = nothing
HexComponentsAPI.update_flowbehav!(::ExpectedValidationFailCompBehav; kwargs...) = throw(ExpectedCandidateValidationError())

struct ThrowingActionCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::ThrowingActionCompBehav) = ()
HexComponentsAPI.get_tunables(::ThrowingActionCompBehav) = ()
HexComponentsAPI.set_tunables(::ThrowingActionCompBehav, ::NTuple{0, Real}) = ThrowingActionCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::ThrowingActionCompBehav; kwargs...) = nothing
HexComponentsAPI.get_actions(::ThrowingActionCompBehav; kwargs...) =
    (ActionInfo(id = :activate, label = "Activate", enabled = true, tooltip = "Activate action"),)
HexComponentsAPI.do_action!(::ThrowingActionCompBehav, ::Symbol; kwargs...) = error("action execution failed")
function placement_valid(comp::ActionCompBehav, coord::TileCoord, gamemap::GameMap; kwargs...)
    return ValidRequest()
end

struct ResultActionCompBehav{T} <: ComponentBehavior
    result::T
end
HexComponentsAPI.produce_rel_elements(::ResultActionCompBehav) = ()
HexComponentsAPI.get_tunables(::ResultActionCompBehav) = ()
HexComponentsAPI.set_tunables(comp::ResultActionCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::ResultActionCompBehav; kwargs...) = nothing
HexComponentsAPI.get_actions(::ResultActionCompBehav; kwargs...) =
    (ActionInfo(id = :run, label = "Run", enabled = true, tooltip = "Run action"),)
HexComponentsAPI.do_action!(comp::ResultActionCompBehav, ::Symbol; kwargs...) = comp.result

mutable struct ValidationMutationCompBehav <: ComponentBehavior
    updates::Int
end
HexComponentsAPI.produce_rel_elements(::ValidationMutationCompBehav) = ()
HexComponentsAPI.get_tunables(::ValidationMutationCompBehav) = ()
HexComponentsAPI.set_tunables(comp::ValidationMutationCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::ValidationMutationCompBehav; kwargs...) = nothing
function HexComponentsAPI.update_flowbehav!(comp::ValidationMutationCompBehav; kwargs...)
    comp.updates += 1
    return nothing
end

struct RotationSensitiveCompBehav{N} <: ComponentBehavior
    valid_rotations::NTuple{N, HexAxis}
end
HexComponentsAPI.produce_rel_elements(::RotationSensitiveCompBehav) = ()
HexComponentsAPI.get_tunables(::RotationSensitiveCompBehav) = ()
HexComponentsAPI.set_tunables(comp::RotationSensitiveCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::RotationSensitiveCompBehav; kwargs...) = nothing
function placement_valid(comp::RotationSensitiveCompBehav, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return InvalidRequest("Not on ship surface")
    end
    if rotation ∉ comp.valid_rotations
        return InvalidRequest("Rotation invalid")
    end
    return ValidRequest()
end

struct MirrorableCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MirrorableCompBehav) = ()
HexComponentsAPI.get_tunables(::MirrorableCompBehav) = ()
HexComponentsAPI.set_tunables(::MirrorableCompBehav, ::NTuple{0, Real}) = MirrorableCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MirrorableCompBehav; kwargs...) = nothing
HexComponentsAPI.map_mirroring(::MirrorableCompBehav, mirrored::Bool) = mirrored
function placement_valid(::MirrorableCompBehav, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...)
    return is_on_surface_tile(coord, gamemap; ship_name = ship_name) ? ValidRequest() : InvalidRequest("Not on ship surface")
end

struct MirroringRequiredCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MirroringRequiredCompBehav) = ()
HexComponentsAPI.get_tunables(::MirroringRequiredCompBehav) = ()
HexComponentsAPI.set_tunables(::MirroringRequiredCompBehav, ::NTuple{0, Real}) = MirroringRequiredCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MirroringRequiredCompBehav; kwargs...) = nothing
HexComponentsAPI.map_mirroring(::MirroringRequiredCompBehav, mirrored::Bool) = mirrored
function placement_valid(::MirroringRequiredCompBehav, coord::TileCoord, gamemap::GameMap;
        mirrored::Bool = false, ship_name::Symbol = :primary, kwargs...)
    is_on_surface_tile(coord, gamemap; ship_name = ship_name) || return InvalidRequest("Not on ship surface")
    mirrored || return InvalidRequest("Mirroring required")
    return ValidRequest()
end

struct ImmovableCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::ImmovableCompBehav) = ()
HexComponentsAPI.get_tunables(::ImmovableCompBehav) = ()
HexComponentsAPI.set_tunables(::ImmovableCompBehav, ::NTuple{0, Real}) = ImmovableCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::ImmovableCompBehav; kwargs...) = nothing
HexComponentsAPI.can_be_moved(::ImmovableCompBehav; kwargs...) = InvalidRequest("Test component is fixed")

struct ImmovablePipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::ImmovablePipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::ImmovablePipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::ImmovablePipeBehav, ::NTuple{0, Real}) = ImmovablePipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::ImmovablePipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::ImmovablePipeBehav) = 0.1
HexComponentsAPI.can_pipe_be_moved(::ImmovablePipeBehav; kwargs...) = InvalidRequest("Test pipe is fixed")

struct DestinationInvalidCompBehav <: ComponentBehavior
    invalid_coord::TileCoord
end


struct PlacementRestrictedCompBehav <: ComponentBehavior
    invalid_coord::TileCoord
end
HexComponentsAPI.produce_rel_elements(::PlacementRestrictedCompBehav) = ()
HexComponentsAPI.get_tunables(::PlacementRestrictedCompBehav) = ()
HexComponentsAPI.set_tunables(comp::PlacementRestrictedCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::PlacementRestrictedCompBehav; kwargs...) = nothing
function placement_valid(comp::PlacementRestrictedCompBehav, coord::TileCoord, gamemap::GameMap;
        ship_name::Symbol = :primary, kwargs...)
    coord == comp.invalid_coord && return InvalidRequest("Restricted destination")
    return is_on_surface_tile(coord, gamemap; ship_name) ? ValidRequest() : InvalidRequest("Not on ship surface")
end
HexComponentsAPI.produce_rel_elements(::DestinationInvalidCompBehav) = ()
HexComponentsAPI.get_tunables(::DestinationInvalidCompBehav) = ()
HexComponentsAPI.set_tunables(comp::DestinationInvalidCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::DestinationInvalidCompBehav; kwargs...) = nothing
function HexComponentsAPI.update_flowbehav!(comp::DestinationInvalidCompBehav; tile::TileCoord, kwargs...)
    tile == comp.invalid_coord && error("Invalid destination reached")
    return nothing
end

#= ---------- Test Helpers ----------- =#

"No-op console sink — captures nothing"
silent_console(::String) = nothing

"Console sink that captures all messages"
function make_log_console()
    logs = String[]
    push_fn = (msg::String) -> push!(logs, msg)
    return logs, push_fn
end

"Shorthand: process a command and return the log messages"
function process_and_log!(cmd, gamemap)
    logs, console = make_log_console()
    HexFlowCalculator.process_command!(cmd, gamemap, console)
    return logs
end

"Minimal FlowCalculatorIPC for unit tests that call update_manoeuvre_phase! directly."
function make_test_ipc(
        ;
        shared_state::FlowCalculatorSharedState = FlowCalculatorSharedState(),
        console_push::Function = silent_console,
    )
    return FlowCalculatorIPC(
        shared_state = shared_state,
        command_queue = create_command_queue(),
        publish_snapshot = (args...) -> nothing,
        get_snapshot = () -> FlowCalculatorSnapshot(),
        console_push = console_push,
        console_see = () -> String[],
    )
end

"Build a deterministic encounter point for manoeuvre tests."
function make_test_encounter_point(
        index::Int;
        base_velocity::Float64,
        position::SVector{2, Float64},
        velocity::SVector{2, Float64},
        spawn_time::Float64 = 0.0,
    )::EncounterPoint
    return EncounterPoint(index = index, base_velocity = base_velocity, position = position, velocity = velocity, spawn_time = spawn_time)
end

"Return the halfway coast state for a planned intercept." 
function make_midcoast_state(
        player_pos_0::SVector{2, Float64},
        player_vel_0::SVector{2, Float64},
        plan::ManoeuvreData;
        velocity_offset::SVector{2, Float64} = SVector(0.0, 0.0),
    )::Tuple{Float64, SVector{2, Float64}, SVector{2, Float64}}
    coast_velocity = player_vel_0 + plan.approach_burn_dv
    current_time = plan.intercept_time / 2.0
    player_pos_mid = player_pos_0 + coast_velocity * current_time
    return current_time, player_pos_mid, coast_velocity + velocity_offset
end

"Create a basic game map with a primary surface tile at the origin."
function make_gamemap()
    gm = GameMap()
    set_surface_tile!(gm, TileCoord(0, 0); ship_name = :primary)
    return gm
end

"Build a normal galactic map whose historical estimate has unlocked galaxy escape."
function make_galaxy_escape_ready_map(
        ; velocity::SVector{2, Float64} = SVector(10.0, 0.0), time_years::Float64 = 0.0,
    )::GameMap
    gamemap = make_gamemap()
    initialise_spacemap!(gamemap, UInt32(0x1234), _test_enc_config, velocity)
    set_time_years!(gamemap, time_years)
    record_peak_estimated_delta_v!(gamemap, GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V)
    return gamemap
end

"Create a two-ship GameMap for multi-ship routing tests.
:primary has surface at (0,0); :asteroid has surface at (20,0)."
function make_two_ship_map()
    gm = make_gamemap()
    add_ship!(gm, :asteroid, ShipState())
    set_surface_tile!(gm, Set(TileCoord(20, r) for r in -1:1); ship_name = :asteroid)
    return gm
end

"Build a minimal encounter blueprint for AddEncounterShipCommand tests."
function make_encounter_test_blueprint(; include_component::Bool = true, include_pipe::Bool = true)
    blueprint = ShipBlueprint(ship_tiles = Set([TileCoord(0, 0), TileCoord(1, 0)]))

    if include_component
        blueprint.components[TileCoord(0, 0)] = PlacedComponent(MockCompBehav(), Q_POS, :_blueprint)
    end

    if include_pipe
        pipe = PipeCoord(VertexCoord(TileCoord(0, 0), Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))
        blueprint.pipe_behaviors[pipe] = MockPipeBehav()
    end

    return blueprint
end

"Assert that exactly one new ship was added and that its merged contents match the blueprint counts."
function assert_encounter_ship_added!(gamemap::GameMap, blueprint::ShipBlueprint, before_ships::Set{Symbol})
    after_ships = Set(get_all_ship_names(gamemap))
    new_ships = setdiff(after_ships, before_ships)

    @test length(after_ships) == length(before_ships) + 1
    @test length(new_ships) == 1

    new_ship = only(new_ships)
    @test count_surface_tiles(gamemap; ship_name = new_ship) == length(blueprint.ship_tiles)
    @test count_components(gamemap; ship_name = new_ship) == length(blueprint.components)
    @test count_pipes(gamemap; ship_name = new_ship) == length(blueprint.pipe_behaviors)
    @test all(c -> c.ship == new_ship, each_component_of_ship(gamemap, new_ship))
    @test all(p -> p.ship == new_ship, each_pipe_of_ship(gamemap, new_ship))

    return new_ship
end

"Build a rectangular tile set for surface setup in tests."
surface_rect_tiles(qmin::Int, rmin::Int, qmax::Int, rmax::Int) = Set(TileCoord(q, r) for q in qmin:qmax for r in rmin:rmax)

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowCalculator Map Edit Commands" begin
    cq = create_command_queue(16)

    #= ---------- SetTileCommand ----------- =#
    @testset "SetTileCommand" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)  # on :primary surface by default

        cmd = create_set_tile_command(cq, coord, MockCompBehav(), Q_POS)
        logs = process_and_log!(cmd, gamemap)

        @test !isnothing(get_component(gamemap, coord))
        @test isempty(logs)
    end

    @testset "SetTileCommand — supports derived-state-aware updates" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        logs = process_and_log!(
            create_set_tile_command(cq, coord, DerivedStateCompBehav(), Q_POS),
            gamemap
        )

        @test !isnothing(get_component(gamemap, coord))
        @test !any(contains(log, "Invalid map edit") for log in logs)
    end

    @testset "SetTileCommand — rejects off-surface" begin
        gamemap = GameMap()
        off_surface = TileCoord(10, 10)  # not on any ship surface

        logs = process_and_log!(
            create_set_tile_command(cq, off_surface, MockCompBehav(), Q_POS),
            gamemap
        )

        @test isnothing(get_component(gamemap, off_surface))
        @test logs == ["Cannot place component: Place components on a ship surface"]
    end

    @testset "SetTileCommand — explains occupied destinations" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)
        process_and_log!(create_set_tile_command(cq, coord, MockCompBehav(), Q_POS), gamemap)

        logs = process_and_log!(create_set_tile_command(cq, coord, MockCompBehav(), Q_POS), gamemap)

        @test logs == ["Cannot place component: a component already occupies the destination tile"]
        @test get_component(gamemap, coord).component isa MockCompBehav
    end

    @testset "SetTileCommand — rejects component-crossing destinations before candidate validation" begin
        gamemap = make_gamemap()
        destination = TileCoord(0, 1)
        set_surface_tile!(gamemap, destination)
        crossing_pipe = get_pipe_segments(destination)[7]
        set_pipe!(gamemap, crossing_pipe, PlacedPipe(MockPipeBehav(), :primary))
        original_hash = hash(gamemap)
        response = Channel{CommandStatus}(1)
        logs, console = make_log_console()
        command = create_set_tile_command(cq, destination, MockCompBehav(), Q_POS; response_channel = response)

        HexFlowCalculator.process_command!(command, gamemap, console; throw_errors = false)

        @test take!(response) == INVALID
        @test !isready(response)
        @test logs == ["Cannot place component: a pipe segment crosses the destination tile"]
        @test hash(gamemap) == original_hash
        @test isnothing(get_component(gamemap, destination))
    end

    @testset "SetTileCommand — allows compatible side pipes" begin
        gamemap = make_gamemap()
        destination = TileCoord(0, 1)
        set_surface_tile!(gamemap, destination)
        set_pipe!(gamemap, side_pipe(destination), PlacedPipe(MockPipeBehav(), :primary))
        response = Channel{CommandStatus}(1)
        logs, console = make_log_console()
        command = create_set_tile_command(cq, destination, MockCompBehav(), Q_POS; response_channel = response)

        HexFlowCalculator.process_command!(command, gamemap, console; throw_errors = false)

        @test take!(response) == APPLIED
        @test !isready(response)
        @test isempty(logs)
        @test has_component(gamemap, destination)
    end

    @testset "SetTileCommand — routes to correct ship" begin
        gamemap = make_two_ship_map()
        set_surface_tile!(gamemap, TileCoord(1, 0); ship_name = :asteroid)

        process_and_log!(
            create_set_tile_command(cq, TileCoord(1, 0), MockCompBehav(), Q_POS),
            gamemap
        )

        # Should land on :asteroid (the only ship with that surface tile)
        placed = get_component(gamemap, TileCoord(1, 0))
        @test !isnothing(placed)
        @test placed.ship === :asteroid
    end

    @testset "SetTileCommand — stores mirrored state after map_mirroring" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, MirrorableCompBehav(), Q_POS, true),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test placed.mirrored
    end

    @testset "SetTileCommand — clears mirror for non-mirrorable components" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS, true),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test !placed.mirrored
    end

    #= ---------- SetPipeBehaviorCommand ----------- =#
    @testset "SetPipeBehaviorCommand" begin
        gamemap = make_gamemap()
        pipe = side_pipe(TileCoord(0, 0), 1)

        cmd = create_set_pipe_behavior_command(cq, pipe, MockPipeBehav())
        process_and_log!(cmd, gamemap)

        @test !isnothing(get_pipe(gamemap, pipe))
    end

    @testset "SetPipeBehaviorCommand rejects component-crossing pipe segments" begin
        for pipe in (
                PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.S_POS)),
                PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)),
            )
            gamemap = make_gamemap()
            set_component!(gamemap, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))

            logs = process_and_log!(create_set_pipe_behavior_command(cq, pipe, MockPipeBehav()), gamemap)

            @test isnothing(get_pipe(gamemap, pipe))
            @test logs == ["Cannot place pipe: the segment crosses a component tile"]
        end
    end

    @testset "SetPipeBehaviorCommand rejects a detached pipe with feedback" begin
        gamemap = make_gamemap()
        pipe = side_pipe(TileCoord(50, 50))
        response = Channel{CommandStatus}(1)
        command = create_set_pipe_behavior_command(
            cq, pipe, MockPipeBehav(); response_channel = response,
        )

        logs = process_and_log!(command, gamemap)

        @test take!(response) == INVALID
        @test !has_pipe(gamemap, pipe)
        @test logs == ["Cannot place pipe: connect it to a ship surface or an attached pipe network"]
    end

    #= ---------- MoveCommand{TileCoord} ----------- =#
    @testset "MoveCommand{TileCoord}" begin
        gamemap = make_gamemap()
        src = TileCoord(0, 0)
        dst = TileCoord(0, 1)
        set_surface_tile!(gamemap, dst; ship_name = :primary)

        # Place a component first
        process_and_log!(
            create_set_tile_command(cq, src, MockCompBehav(), Q_POS),
            gamemap
        )
        @test !isnothing(get_component(gamemap, src))

        # Move it
        cmd = create_move_command(cq, src, dst, Q_POS)
        process_and_log!(cmd, gamemap)

        @test isnothing(get_component(gamemap, src))
        @test !isnothing(get_component(gamemap, dst))
    end

    @testset "MoveCommand{TileCoord} — rejects missing source" begin
        gamemap = GameMap()
        set_surface_tile!(gamemap, TileCoord(0, 1); ship_name = :primary)

        logs = process_and_log!(
            create_move_command(cq, TileCoord(0, 0), TileCoord(0, 1), Q_POS),
            gamemap
        )

        # No component at source — destination should remain empty
        @test isnothing(get_component(gamemap, TileCoord(0, 1)))
    end

    @testset "MoveCommand{TileCoord} — rejects immovable source" begin
        gamemap = make_gamemap()
        source = TileCoord(0, 0)
        destination = TileCoord(0, 1)
        set_surface_tile!(gamemap, destination; ship_name = :primary)
        set_component!(gamemap, source, PlacedComponent(ImmovableCompBehav(), Q_POS, :primary))
        original_hash = hash(gamemap)
        response = Channel{CommandStatus}(1)

        logs = process_and_log!(
            create_move_command(cq, source, destination, Q_POS; response_channel = response), gamemap,
        )

        @test take!(response) == INVALID
        @test logs == ["Cannot move component: Test component is fixed"]
        @test hash(gamemap) == original_hash
        @test get_component(gamemap, source).component isa ImmovableCompBehav
        @test isnothing(get_component(gamemap, destination))
    end

    @testset "MoveCommand{TileCoord} — rejects invalid in-place rotation" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, RotationSensitiveCompBehav((Q_POS,)), Q_POS),
            gamemap
        )

        logs = process_and_log!(
            create_move_command(cq, coord, coord, HexFrame.R_POS),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test placed.rotation == Q_POS
        @test any(contains(l, "Cannot rotate in place") || contains(l, "Rotation invalid") for l in logs)
    end

    @testset "MoveCommand{TileCoord} — allows valid in-place rotation" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, RotationSensitiveCompBehav((Q_POS, HexFrame.R_POS)), Q_POS),
            gamemap
        )

        logs = process_and_log!(
            create_move_command(cq, coord, coord, HexFrame.R_POS),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test placed.rotation == HexFrame.R_POS
        @test isempty(logs)
    end

    @testset "MoveCommand{TileCoord} — applies mirror delta with xor semantics" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, MirrorableCompBehav(), Q_POS),
            gamemap
        )

        process_and_log!(
            create_move_command(cq, coord, coord, Q_POS, true),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test placed.mirrored

        process_and_log!(
            create_move_command(cq, coord, coord, Q_POS, true),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test !placed.mirrored
    end

    @testset "MoveCommand{TileCoord} — rejects invalid in-place flip" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, MirroringRequiredCompBehav(), Q_POS, true),
            gamemap
        )

        logs = process_and_log!(
            create_move_command(cq, coord, coord, Q_POS, true),
            gamemap
        )

        placed = get_component(gamemap, coord)
        @test !isnothing(placed)
        @test placed.mirrored
        @test any(contains(l, "Cannot rotate in place") || contains(l, "Mirroring required") for l in logs)
    end

    @testset "MoveCommand{TileCoord} — reports occupied destination" begin
        gamemap = make_two_ship_map()
        src = TileCoord(0, 0)
        dst = TileCoord(0, 1)
        set_surface_tile!(gamemap, dst; ship_name = :primary)

        process_and_log!(
            create_set_tile_command(cq, src, MockCompBehav(), Q_POS),
            gamemap
        )
        set_component!(gamemap, dst, PlacedComponent(MockCompBehav(), Q_POS, :asteroid))

        logs = process_and_log!(
            create_move_command(cq, src, dst, Q_POS),
            gamemap
        )

        @test logs == ["Cannot move component: a component already occupies the destination tile"]
        @test get_component(gamemap, src).ship === :primary
        @test get_component(gamemap, dst).ship === :asteroid
    end

    @testset "MoveCommand{TileCoord} — rejects component-crossing destination" begin
        gamemap = make_gamemap()
        src = TileCoord(0, 0)
        dst = TileCoord(0, 1)
        set_surface_tile!(gamemap, dst; ship_name = :primary)
        process_and_log!(create_set_tile_command(cq, src, MockCompBehav(), Q_POS), gamemap)
        crossing_pipe = get_pipe_segments(dst)[7]
        set_pipe!(gamemap, crossing_pipe, PlacedPipe(MockPipeBehav(), :primary))

        logs = process_and_log!(create_move_command(cq, src, dst, Q_POS), gamemap)

        @test logs == ["Cannot move component: a pipe segment crosses the destination tile"]
        @test has_component(gamemap, src)
        @test !has_component(gamemap, dst)
    end

    @testset "MoveCommand{TileCoord} — retains ownership for in-place rotation" begin
        gamemap = make_two_ship_map()
        coord = TileCoord(20, 0)
        set_component!(gamemap, coord, PlacedComponent(ActionCompBehav(), Q_POS, :asteroid))

        logs = process_and_log!(create_move_command(cq, coord, coord, HexFrame.R_POS), gamemap)

        @test isempty(logs)
        @test get_component(gamemap, coord).ship === :asteroid
    end

    #= ---------- TranslateElementsCommand ----------- =#
    @testset "TranslateElementsCommand" begin
        @testset "constructor owns and validates its source set" begin
            sources = Set([TileCoord(0, 0)])
            command = create_translate_elements_command(cq, sources, TileCoord(1, 0))
            empty!(sources)

            @test command.component_coords == Set([TileCoord(0, 0)])
            @test isempty(command.pipe_coords)
            @test_throws ArgumentError create_translate_elements_command(cq, Set{TileCoord}(), TileCoord(1, 0))
            @test_throws ArgumentError create_translate_elements_command(cq, Set([TileCoord(0, 0)]), TileCoord(0, 0))
        end

        @testset "translates one or several components" begin
            for sources in (Set([TileCoord(0, 0)]), Set([TileCoord(0, 0), TileCoord(1, 0)]))
                gamemap = make_gamemap()
                destinations = Set(source + TileCoord(0, 1) for source in sources)
                set_surface_tile!(gamemap, union(sources, destinations))
                for source in sources
                    set_component!(gamemap, source, PlacedComponent(MockCompBehav(), Q_POS, :primary))
                end

                process_and_log!(create_translate_elements_command(cq, sources, TileCoord(0, 1)), gamemap)

                @test all(destination -> has_component(gamemap, destination), destinations)
                @test all(source -> !has_component(gamemap, source), setdiff(sources, destinations))
                @test count_components(gamemap) == length(sources)
            end
        end

        @testset "translates pipes and mixed element sets" begin
            gamemap = make_gamemap()
            translation = TileCoord(0, 1)
            component_source = TileCoord(0, 0)
            pipe_source = side_pipe(TileCoord(1, 0))
            pipe_destination = offset_by_tile(pipe_source, translation)
            set_surface_tile!(gamemap, Set([
                component_source,
                component_source + translation,
                TileCoord(1, 0),
                TileCoord(1, 1),
            ]))
            set_component!(gamemap, component_source, PlacedComponent(MockCompBehav(), Q_POS, :primary))
            pipe_behaviour = MockPipeBehav()
            set_pipe!(gamemap, pipe_source, PlacedPipe(pipe_behaviour, :primary))

            command = create_translate_elements_command(
                cq, Set([component_source]), Set([pipe_source]), translation,
            )
            process_and_log!(command, gamemap)

            @test has_component(gamemap, component_source + translation)
            @test !has_component(gamemap, component_source)
            @test has_pipe(gamemap, pipe_destination)
            @test !has_pipe(gamemap, pipe_source)
            @test get_pipe(gamemap, pipe_destination).pipe === pipe_behaviour
        end

        @testset "requires a non-empty source type" begin
            @test_throws ArgumentError create_translate_elements_command(
                cq, Set{TileCoord}(), Set{PipeCoord}(), TileCoord(1, 0),
            )
        end

        @testset "uses simultaneous occupancy semantics" begin
            gamemap = make_gamemap()
            sources = Set([TileCoord(0, 0), TileCoord(0, 1)])
            set_surface_tile!(gamemap, Set([TileCoord(0, 0), TileCoord(0, 1), TileCoord(0, 2)]))
            for source in sources
                set_component!(gamemap, source, PlacedComponent(MockCompBehav(), Q_POS, :primary))
            end

            process_and_log!(create_translate_elements_command(cq, sources, TileCoord(0, 1)), gamemap)

            @test !has_component(gamemap, TileCoord(0, 0))
            @test has_component(gamemap, TileCoord(0, 1))
            @test has_component(gamemap, TileCoord(0, 2))
        end

        @testset "rolls back source and occupancy failures" begin
            gamemap = make_gamemap()
            source = TileCoord(0, 0)
            missing = TileCoord(1, 0)
            destination = TileCoord(0, 1)
            set_surface_tile!(gamemap, Set([source, missing, destination, TileCoord(1, 1)]))
            set_component!(gamemap, source, PlacedComponent(MockCompBehav(), Q_POS, :primary))
            original_hash = hash(gamemap)

            process_and_log!(
                create_translate_elements_command(cq, Set([source, missing]), TileCoord(0, 1)),
                gamemap,
            )
            @test hash(gamemap) == original_hash

            set_component!(gamemap, missing, PlacedComponent(ImmovableCompBehav(), Q_POS, :primary))
            original_hash = hash(gamemap)
            logs = process_and_log!(
                create_translate_elements_command(cq, Set([source, missing]), TileCoord(0, 1)),
                gamemap,
            )
            @test logs == ["Cannot move selection: Test component is fixed"]
            @test hash(gamemap) == original_hash

            external_destination = TileCoord(0, 1)
            set_component!(gamemap, external_destination, PlacedComponent(MockCompBehav(), Q_POS, :primary))
            original_hash = hash(gamemap)
            logs = process_and_log!(create_translate_elements_command(cq, Set([source]), TileCoord(0, 1)), gamemap)
            @test logs == ["Cannot move selection: a component already occupies the destination tile"]
            @test hash(gamemap) == original_hash
        end

        @testset "rejects an occupied external pipe destination" begin
            gamemap = make_gamemap()
            translation = TileCoord(0, 1)
            source = side_pipe(TileCoord(0, 0))
            destination = offset_by_tile(source, translation)
            set_pipe!(gamemap, source, PlacedPipe(MockPipeBehav(), :primary))
            set_pipe!(gamemap, destination, PlacedPipe(MockPipeBehav(), :primary))
            original_hash = hash(gamemap)

            logs = process_and_log!(create_translate_elements_command(cq, Set{TileCoord}(), Set([source]), translation), gamemap)

            @test logs == ["Cannot move selection: clear the occupied destination edge first"]
            @test hash(gamemap) == original_hash
        end

        @testset "rejects an immovable pipe atomically" begin
            gamemap = make_gamemap()
            translation = TileCoord(0, 1)
            source = side_pipe(TileCoord(0, 0))
            destination = offset_by_tile(source, translation)
            set_pipe!(gamemap, source, PlacedPipe(ImmovablePipeBehav(), :primary))
            original_hash = hash(gamemap)

            logs = process_and_log!(
                create_translate_elements_command(cq, Set{TileCoord}(), Set([source]), translation), gamemap,
            )

            @test logs == ["Cannot move selection: Test pipe is fixed"]
            @test hash(gamemap) == original_hash
            @test get_pipe(gamemap, source).pipe isa ImmovablePipeBehav
            @test isnothing(get_pipe(gamemap, destination))
        end

        @testset "enforces pipe and component placement rules" begin
            source = TileCoord(0, 0)
            destination = TileCoord(0, 1)

            gamemap = make_gamemap()
            set_surface_tile!(gamemap, destination)
            set_component!(gamemap, source, PlacedComponent(MockCompBehav(), Q_POS, :primary))
            crossing_pipe = get_pipe_segments(destination)[7]
            set_pipe!(gamemap, crossing_pipe, PlacedPipe(MockPipeBehav(), :primary))
            original_hash = hash(gamemap)
            process_and_log!(create_translate_elements_command(cq, Set([source]), TileCoord(0, 1)), gamemap)
            @test hash(gamemap) == original_hash

            delete_pipe!(gamemap, crossing_pipe)
            set_pipe!(gamemap, side_pipe(destination), PlacedPipe(MockPipeBehav(), :primary))
            process_and_log!(create_translate_elements_command(cq, Set([source]), TileCoord(0, 1)), gamemap)
            @test has_component(gamemap, destination)

            restricted_map = make_gamemap()
            set_surface_tile!(restricted_map, destination)
            set_component!(restricted_map, source,
                PlacedComponent(PlacementRestrictedCompBehav(destination), Q_POS, :primary))
            original_hash = hash(restricted_map)
            process_and_log!(
                create_translate_elements_command(cq, Set([source]), TileCoord(0, 1)),
                restricted_map,
            )
            @test hash(restricted_map) == original_hash
        end

        @testset "preserves orientation and resolves each destination ship" begin
            gamemap = GameMap()
            add_ship!(gamemap, :middle, ShipState())
            add_ship!(gamemap, :destination, ShipState())
            source_a = TileCoord(0, 0)
            source_b = TileCoord(10, 0)
            destination_b = TileCoord(20, 0)
            set_surface_tile!(gamemap, source_a; ship_name = :primary)
            set_surface_tile!(gamemap, source_b; ship_name = :middle)
            set_surface_tile!(gamemap, destination_b; ship_name = :destination)
            set_component!(gamemap, source_a, PlacedComponent(MirrorableCompBehav(), HexFrame.R_NEG, true, :primary))
            set_component!(gamemap, source_b, PlacedComponent(MockCompBehav(), HexFrame.S_POS, false, :middle))

            process_and_log!(
                create_translate_elements_command(cq, Set([source_a, source_b]), TileCoord(10, 0)),
                gamemap,
            )

            moved_a = get_component(gamemap, source_b)
            moved_b = get_component(gamemap, destination_b)
            @test moved_a.ship === :middle
            @test moved_a.rotation === HexFrame.R_NEG
            @test moved_a.mirrored
            @test moved_b.ship === :destination
            @test moved_b.rotation === HexFrame.S_POS
            @test !moved_b.mirrored
        end

        @testset "final candidate validation rolls back the complete move" begin
            gamemap = make_gamemap()
            source = TileCoord(0, 0)
            destination = TileCoord(0, 1)
            set_surface_tile!(gamemap, destination)
            set_component!(gamemap, source,
                PlacedComponent(DestinationInvalidCompBehav(destination), Q_POS, :primary))
            original_hash = hash(gamemap)
            response = Channel{CommandStatus}(1)
            command = create_translate_elements_command(
                cq,
                Set([source]),
                TileCoord(0, 1);
                response_channel = response,
            )

            HexFlowCalculator.process_command!(command, gamemap, silent_console; throw_errors = false)

            @test take!(response) == REJECTED
            @test !isready(response)
            @test hash(gamemap) == original_hash
        end

        @testset "reports one status for applied and invalid commands" begin
            for (source_exists, expected_status) in ((true, APPLIED), (false, INVALID))
                gamemap = make_gamemap()
                destination = TileCoord(0, 1)
                set_surface_tile!(gamemap, destination)
                source_exists && set_component!(gamemap, TileCoord(0, 0),
                    PlacedComponent(MockCompBehav(), Q_POS, :primary))
                response = Channel{CommandStatus}(1)
                command = create_translate_elements_command(
                    cq,
                    Set([TileCoord(0, 0)]),
                    TileCoord(0, 1);
                    response_channel = response,
                )

                HexFlowCalculator.process_command!(command, gamemap, silent_console; throw_errors = false)

                @test take!(response) == expected_status
                @test !isready(response)
            end
        end
    end

    #= ---------- MoveCommand{PipeCoord} ----------- =#
    @testset "MoveCommand{PipeCoord}" begin
        gamemap = make_gamemap()
        set_surface_tile!(gamemap, TileCoord(0, 1); ship_name = :primary)

        src_pipe = side_pipe(TileCoord(0, 0), 1)
        dst_pipe = side_pipe(TileCoord(0, 1), 1)

        # Place a pipe first
        process_and_log!(
            create_set_pipe_behavior_command(cq, src_pipe, MockPipeBehav()),
            gamemap
        )
        @test !isnothing(get_pipe(gamemap, src_pipe))

        # Move it
        cmd = create_move_command(cq, src_pipe, dst_pipe, Q_POS)
        process_and_log!(cmd, gamemap)

        @test isnothing(get_pipe(gamemap, src_pipe))
        @test !isnothing(get_pipe(gamemap, dst_pipe))

    end

    @testset "MoveCommand{PipeCoord} — rejects immovable source" begin
        gamemap = make_gamemap()
        source = side_pipe(TileCoord(0, 0))
        destination = offset_by_tile(source, TileCoord(0, 1))
        set_pipe!(gamemap, source, PlacedPipe(ImmovablePipeBehav(), :primary))
        original_hash = hash(gamemap)
        response = Channel{CommandStatus}(1)

        logs = process_and_log!(
            create_move_command(cq, source, destination, Q_POS; response_channel = response), gamemap,
        )

        @test take!(response) == INVALID
        @test logs == ["Cannot move pipe: Test pipe is fixed"]
        @test hash(gamemap) == original_hash
        @test get_pipe(gamemap, source).pipe isa ImmovablePipeBehav
        @test isnothing(get_pipe(gamemap, destination))
    end

    @testset "MoveCommand{PipeCoord} — re-tags pipe on cross-ship move" begin
        gamemap = make_two_ship_map()

        src_pipe = side_pipe(TileCoord(0, 0), 1)
        dst_pipe = side_pipe(TileCoord(20, 0), 1)

        process_and_log!(
            create_set_pipe_behavior_command(cq, src_pipe, MockPipeBehav()),
            gamemap
        )

        source_pipe = get_pipe(gamemap, src_pipe)
        @test !isnothing(source_pipe)
        @test source_pipe.ship === :primary

        logs = process_and_log!(
            create_move_command(cq, src_pipe, dst_pipe, Q_POS),
            gamemap
        )

        moved_pipe = get_pipe(gamemap, dst_pipe)
        @test isnothing(get_pipe(gamemap, src_pipe))
        @test !isnothing(moved_pipe)
        @test moved_pipe.ship === :asteroid
        @test isempty(logs)
    end

    @testset "MoveCommand{PipeCoord} rejects component-crossing destinations" begin
        blocked_destinations = (
            PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.S_POS)),
            PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)),
        )

        for dst_pipe in blocked_destinations
            gamemap = make_gamemap()
            set_surface_tile!(gamemap, TileCoord(1, 0); ship_name = :primary)
            src_pipe = side_pipe(TileCoord(1, 0), 1)
            set_pipe!(gamemap, src_pipe, PlacedPipe(MockPipeBehav(), :primary))
            set_component!(gamemap, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))

            logs = process_and_log!(create_move_command(cq, src_pipe, dst_pipe, Q_POS), gamemap)

            @test !isnothing(get_pipe(gamemap, src_pipe))
            @test isnothing(get_pipe(gamemap, dst_pipe))
            @test logs == ["Cannot move pipe: the destination segment crosses a component tile"]
        end
    end

    #= ---------- Singleton component deletion ----------- =#
    @testset "DeleteElementsCommand singleton component" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        # Place then delete
        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS),
            gamemap
        )
        @test !isnothing(get_component(gamemap, coord))

        cmd = create_delete_elements_command(cq, coord)
        @test cmd isa DeleteElementsCommand
        @test cmd.component_coords == Set([coord])
        @test isempty(cmd.pipe_coords)

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_component(gamemap, coord))
        @test isempty(logs)
    end

    #= ---------- DoActionCommand tests ----------- =#

    @testset "DoActionCommand" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        # place the action component
        process_and_log!(create_set_tile_command(cq, coord, ActionCompBehav(), Q_POS), gamemap)
        @test !isnothing(get_component(gamemap, coord))  # ensure placement succeeded
        @test action_count[] == 0

        # sanity check: manual invocation should work
        wrapped = get_component(gamemap, coord)
        do_action!(wrapped, :flip)
        @test action_count[] == 1
        # reset for command test
        action_count[] = 0

        # The action is applied once to the working map and is not replayed after validation.
        cmd = create_do_action_command(cq, coord, :flip)
        logs = process_and_log!(cmd, gamemap)
        @test action_count[] == 1
        @test logs == ["Flipped"]

        # A stale action target is an expected silent rejection.
        gamemap2 = GameMap()
        logs2 = process_and_log!(create_do_action_command(cq, TileCoord(5, 5), :flip), gamemap2)
        @test isempty(logs2)

        # A changed action state remains an actionable player rejection.
        gamemap3 = make_gamemap()
        set_component!(gamemap3, coord, PlacedComponent(
            ResultActionCompBehav(InvalidRequest("Action is no longer available")), Q_POS, :primary,
        ))
        @test process_and_log!(create_do_action_command(cq, coord, :run), gamemap3) == ["Action is no longer available"]

        # A component returning a valid request without a String result is a programming failure.
        gamemap4 = make_gamemap()
        set_component!(gamemap4, coord, PlacedComponent(ResultActionCompBehav(ValidRequest()), Q_POS, :primary))
        logs4, console4 = make_log_console()
        action_command = create_do_action_command(cq, coord, :run)
        logger4 = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(logger4) do
            HexFlowCalculator.process_command!(
                action_command, gamemap4, console4; throw_errors = false,
            )
        end
        @test isempty(logs4)
        command_log = only(filter(log -> log.message == "Map edit command threw an exception", logger4.logs))
        command_context = command_log.kwargs[:command_context]
        @test command_context.type == :DoActionCommand
        @test command_context.id == action_command.id
        @test command_context.coord == coord
        @test command_context.action_id == :run
        @test !isempty(command_log.kwargs[:exception][2])
    end

    @testset "stale map edits resolve once without console output or warnings" begin
        cq_stale = create_command_queue(16)
        stale_factories = [
            response -> create_move_command(cq_stale, TileCoord(0, 0), TileCoord(1, 0), Q_POS; response_channel = response),
            response -> create_move_command(cq_stale, side_pipe(TileCoord(0, 0)), side_pipe(TileCoord(1, 0)), Q_POS; response_channel = response),
            response -> create_translate_elements_command(cq_stale, Set([TileCoord(0, 0)]), TileCoord(1, 0); response_channel = response),
            response -> create_delete_elements_command(cq_stale, TileCoord(0, 0); response_channel = response),
            response -> create_do_action_command(cq_stale, TileCoord(0, 0), :run; response_channel = response),
            response -> create_redock_ship_command(cq_stale, :missing_ship, TileCoord(1, 0); response_channel = response),
        ]
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        for factory in stale_factories
            response = Channel{CommandStatus}(1)
            logs, console = make_log_console()
            Base.CoreLogging.with_logger(logger) do
                HexFlowCalculator.process_command!(factory(response), GameMap(), console; throw_errors = false)
            end
            @test take!(response) == INVALID
            @test !isready(response)
            @test isempty(logs)
        end
        @test isempty(logger.logs)
    end

    @testset "diagnostics retain compact command context" begin
        cq_diag = create_command_queue(16)
        translation = create_translate_elements_command(
            cq_diag, Set([TileCoord(0, 0), TileCoord(1, 0)]), Set([side_pipe(TileCoord(0, 0))]), TileCoord(2, 0),
        )
        translation_context = HexFlowCalculator.command_diagnostic(translation)
        @test translation_context.component_count == 2
        @test translation_context.pipe_count == 1
        @test !hasproperty(translation_context, :component_coords)
        @test !hasproperty(translation_context, :pipe_coords)
        @test !hasproperty(translation_context, :response_channel)

        deletion = create_delete_elements_command(
            cq_diag, Set([TileCoord(0, 0), TileCoord(1, 0)]), Set([side_pipe(TileCoord(0, 0))]),
        )
        deletion_context = HexFlowCalculator.command_diagnostic(deletion)
        @test deletion_context.component_count == 2
        @test deletion_context.pipe_count == 1
        @test !hasproperty(deletion_context, :component_coords)
        @test !hasproperty(deletion_context, :pipe_coords)
        @test !hasproperty(deletion_context, :response_channel)

        replacement = create_map_override_command(cq_diag, GameMap())
        replacement_context = HexFlowCalculator.command_diagnostic(replacement)
        @test replacement_context.replacement_map == HexFlowCalculator.map_diagnostic(replacement.new_map)
        @test !hasproperty(replacement_context, :new_map)
        @test !hasproperty(replacement_context, :response_channel)

        start_escape = create_start_galaxy_escape_command(cq_diag)
        start_context = HexFlowCalculator.command_diagnostic(start_escape)
        @test start_context == (type = :StartGalaxyEscapeCommand, id = start_escape.id)
        @test !hasproperty(start_context, :response_channel)
    end

    @testset "DeleteElementsCommand singleton missing component" begin
        gamemap = GameMap()
        logs = process_and_log!(
            create_delete_elements_command(cq, TileCoord(0, 0)),
            gamemap
        )

        @test isempty(logs)
    end

    #= ---------- Singleton pipe deletion ----------- =#
    @testset "DeleteElementsCommand singleton pipe" begin
        gamemap = make_two_ship_map()
        pipe = side_pipe(TileCoord(20, 0), 1)

        # Place then delete
        process_and_log!(
            create_set_pipe_behavior_command(cq, pipe, MockPipeBehav()),
            gamemap
        )
        @test !isnothing(get_pipe(gamemap, pipe))

        cmd = create_delete_elements_command(cq, pipe)
        @test cmd isa DeleteElementsCommand
        @test isempty(cmd.component_coords)
        @test cmd.pipe_coords == Set([pipe])

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_pipe(gamemap, pipe))
        @test isempty(logs)
    end

    @testset "DeleteElementsCommand rejects disconnecting a pipe network with feedback" begin
        gamemap = make_gamemap()
        source = VertexCoord(TileCoord(0, 0), Q_POS)
        anchor = get_pipe_segments(source)[1]
        anchor_end = anchor.v1 == to_proper(source) ? anchor.v2 : anchor.v1
        branch = first(pipe for pipe in get_pipe_segments(anchor_end) if pipe != anchor && !is_side_span(pipe))
        set_pipe!(gamemap, anchor, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gamemap, branch, PlacedPipe(MockPipeBehav(), :primary))
        response = Channel{CommandStatus}(1)
        command = create_delete_elements_command(cq, anchor; response_channel = response)

        logs = process_and_log!(command, gamemap)

        @test take!(response) == INVALID
        @test has_pipe(gamemap, anchor)
        @test has_pipe(gamemap, branch)
        @test logs == ["Cannot delete pipe: this would leave part of the pipe network disconnected from every ship"]
    end

    @testset "DeleteElementsCommand singleton missing pipe" begin
        gamemap = GameMap()
        pipe = side_pipe(TileCoord(0, 0), 1)

        logs = process_and_log!(
            create_delete_elements_command(cq, pipe),
            gamemap
        )

        @test isempty(logs)
    end

    #= ---------- Singleton deletion factory correctness ----------- =#
    @testset "DeleteElementsCommand singleton factories" begin
        cmd_tile = create_delete_elements_command(cq, TileCoord(0, 0))
        cmd_pipe = create_delete_elements_command(cq, side_pipe(TileCoord(0, 0), 1))

        @test cmd_tile isa DeleteElementsCommand
        @test cmd_pipe isa DeleteElementsCommand

        # Both are subtypes of MapEditCommand
        @test cmd_tile isa MapEditCommand
        @test cmd_pipe isa MapEditCommand
    end

    #= ---------- ClickTileCommand ----------- =#
    @testset "ClickTileCommand" begin
        gamemap = make_two_ship_map()
        coord = TileCoord(20, 0)

        # Place a component to click on
        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS),
            gamemap
        )

        cmd = create_click_tile_command(cq, coord, CartesianCoord(0.0, 0.0))
        logs = process_and_log!(cmd, gamemap)

        # MockCompBehav.on_click! does nothing, so no error expected
        @test isempty(logs)
    end

    @testset "ClickTileCommand — missing component" begin
        gamemap = GameMap()

        logs = process_and_log!(
            create_click_tile_command(cq, TileCoord(5, 5), CartesianCoord(0.0, 0.0)),
            gamemap
        )

        @test isempty(logs)
    end

    #= ---------- AddShipSurfaceCommand ----------- =#
    @testset "AddShipSurfaceCommand" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 1)  # adjacent to default (0,0) surface

        cmd = create_add_ship_surface_command(cq, coord)
        logs = process_and_log!(cmd, gamemap)

        @test is_on_surface_tile(coord, gamemap; ship_name = :primary)
        @test isempty(logs)
    end

    @testset "AddShipSurfaceCommand — existing surface is a silent no-op" begin
        gamemap = make_gamemap()

        logs = process_and_log!(create_add_ship_surface_command(cq, TileCoord(0, 0)), gamemap)

        @test count_surface_tiles(gamemap; ship_name = :primary) == 1
        @test isempty(logs)
    end

    #= ---------- RemoveShipSurfaceCommand ----------- =#
    @testset "RemoveShipSurfaceCommand" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 1)

        # Add then remove
        process_and_log!(create_add_ship_surface_command(cq, coord), gamemap)
        @test is_on_surface_tile(coord, gamemap; ship_name = :primary)

        logs = process_and_log!(
            create_remove_ship_surface_command(cq, coord),
            gamemap
        )

        @test !is_on_surface_tile(coord, gamemap; ship_name = :primary)
        @test isempty(logs)
    end

    #= ---------- MapOverrideCommand ----------- =#
    @testset "MapOverrideCommand" begin
        gamemap = GameMap()
        new_map = make_two_ship_map()

        cmd = create_map_override_command(cq, new_map)
        logs = process_and_log!(cmd, gamemap)

        # After override, gamemap should have the :asteroid ship
        @test haskey(gamemap.ships, :asteroid)
        @test count_surface_tiles(gamemap) == count_surface_tiles(new_map)
        @test isempty(logs)
    end

    #= ---------- Multi-Ship Routing ----------- =#
    @testset "Multi-ship command routing" begin
        gamemap = make_two_ship_map()

        # Place component on :asteroid's surface tile
        set_surface_tile!(gamemap, TileCoord(1, 0); ship_name = :asteroid)
        process_and_log!(
            create_set_tile_command(cq, TileCoord(1, 0), MockCompBehav(), Q_POS),
            gamemap
        )

        placed = get_component(gamemap, TileCoord(1, 0))
        @test !isnothing(placed)
        @test placed.ship === :asteroid

        # Move within :asteroid
        set_surface_tile!(gamemap, TileCoord(2, 0); ship_name = :asteroid)
        process_and_log!(
            create_move_command(cq, TileCoord(1, 0), TileCoord(2, 0), Q_POS),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(1, 0)))
        moved = get_component(gamemap, TileCoord(2, 0))
        @test !isnothing(moved)
        @test moved.ship === :asteroid

        # Delete from :asteroid
        process_and_log!(
            create_delete_elements_command(cq, TileCoord(2, 0)),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(2, 0)))
    end

    #= ---------- Command ID Generation ----------- =#
    @testset "Command IDs are sequential" begin
        c1 = create_delete_elements_command(cq, TileCoord(0, 0))
        c2 = create_delete_elements_command(cq, TileCoord(0, 0))
        c3 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

        @test c2.id == c1.id + 1
        @test c3.id == c2.id + 1
    end
end

# ===============================================================
# Tests — multi-target component actions
# ===============================================================

@testset "DoActionCommand transactions" begin
    @testset "factories own canonical targets and allocate one ID" begin
        cq = create_command_queue(8)
        coord = TileCoord(2, -1)
        scalar = create_do_action_command(cq, coord, :activate)
        source_coords = [TileCoord(2, 0), TileCoord(0, 0), TileCoord(2, 0), TileCoord(1, 0)]
        command = create_do_action_command(cq, source_coords, :activate)
        source_coords[1] = TileCoord(99, 99)

        @test scalar.component_coords == [coord]
        @test command.component_coords == [TileCoord(0, 0), TileCoord(1, 0), TileCoord(2, 0)]
        @test command.id == scalar.id + 1
        @test_throws ArgumentError create_do_action_command(cq, TileCoord[], :activate)
    end

    @testset "duplicates execute once in deterministic order" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        coords = [TileCoord(2, 0), TileCoord(0, 0), TileCoord(1, 0)]
        for coord in coords
            set_surface_tile!(gm, coord)
            set_component!(gm, coord, PlacedComponent(ActionCompBehav(), Q_POS, :primary))
        end

        action_count[] = 0
        logs = process_and_log!(create_do_action_command(cq, [coords[1], coords[2], coords[1], coords[3]], :flip), gm)

        @test action_count[] == 3
        @test logs == ["Flipped for 3 selected components"]
    end

    @testset "first message and target order are deterministic" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        coords = [TileCoord(2, 0), TileCoord(0, 0)]
        for coord in coords
            set_surface_tile!(gm, coord)
        end
        set_component!(gm, coords[1], PlacedComponent(ResultActionCompBehav(ValidRequestResult("Second result")), Q_POS, :primary))
        set_component!(gm, coords[2], PlacedComponent(ResultActionCompBehav(ValidRequestResult("First result")), Q_POS, :primary))

        logs = process_and_log!(create_do_action_command(cq, coords, :run), gm)

        @test logs == ["First result for 2 selected components"]
    end

    @testset "successful actions commit once and report once" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        set_surface_tile!(gm, TileCoord(1, 0))
        set_component!(gm, TileCoord(0, 0), PlacedComponent(StatefulActionCompBehav(0), Q_POS, :primary))
        set_component!(gm, TileCoord(1, 0), PlacedComponent(StatefulActionCompBehav(0), Q_POS, :primary))

        logs = process_and_log!(create_do_action_command(cq, [TileCoord(0, 0), TileCoord(1, 0)], :activate), gm)

        @test get_component(gm, TileCoord(0, 0)).component.activations == 1
        @test get_component(gm, TileCoord(1, 0)).component.activations == 1
        @test logs == ["Activated for 2 selected components"]
    end

    @testset "later invalid and stale targets roll back earlier actions" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(StatefulActionCompBehav(0), Q_POS, :primary))
        set_surface_tile!(gm, TileCoord(1, 0))
        set_component!(gm, TileCoord(1, 0), PlacedComponent(ResultActionCompBehav(InvalidRequest("Action is no longer available")), Q_POS, :primary))

        logs = process_and_log!(create_do_action_command(cq, [TileCoord(0, 0), TileCoord(1, 0)], :activate), gm)

        @test get_component(gm, TileCoord(0, 0)).component.activations == 0
        @test logs == ["Action is no longer available"]

        logs = process_and_log!(create_do_action_command(cq, [TileCoord(0, 0), TileCoord(5, 5)], :activate), gm)
        @test get_component(gm, TileCoord(0, 0)).component.activations == 0
        @test isempty(logs)
    end

    @testset "programming failures retain the failing target and original backtrace" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        failing_coord = TileCoord(1, 0)
        set_surface_tile!(gm, failing_coord)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(StatefulActionCompBehav(0), Q_POS, :primary))
        set_component!(gm, failing_coord, PlacedComponent(ThrowingActionCompBehav(), Q_POS, :primary))
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        logs, console = make_log_console()
        command = create_do_action_command(cq, [failing_coord, TileCoord(0, 0)], :activate)

        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(command, gm, console; throw_errors = false)
        end

        command_log = only(filter(log -> log.message == "Map edit command threw an exception", logger.logs))
        @test command_log.kwargs[:failed_coord] == failing_coord
        @test command_log.kwargs[:action_id] == :activate
        @test !isempty(command_log.kwargs[:exception][2])
        @test get_component(gm, TileCoord(0, 0)).component.activations == 0
        @test isempty(logs)
    end

    @testset "candidate validation rolls back action and feedback" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(ActionValidationFailCompBehav(0), Q_POS, :primary))
        command = create_do_action_command(cq, TileCoord(0, 0), :activate)
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        logs, console = make_log_console()

        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(command, gm, console; throw_errors = false)
        end

        validation_log = only(filter(log -> log.message == "Map edit candidate validation failed", logger.logs))
        @test validation_log.kwargs[:command_context].id == command.id
        @test validation_log.kwargs[:candidate_map_state].components == 1
        @test !isempty(validation_log.kwargs[:exception][2])
        @test get_component(gm, TileCoord(0, 0)).component.activations == 0
        @test logs == ["Invalid map edit: candidate validation failed"]
        @test length(filter(log -> log.message == "Map edit candidate validation failed", logger.logs)) == 1
    end

    @testset "expected candidate validation subtype is warning-free" begin
        gm = make_gamemap()
        cq = create_command_queue(8)
        response = Channel{CommandStatus}(1)
        command = create_set_tile_command(
            cq, TileCoord(0, 0), ExpectedValidationFailCompBehav(), Q_POS; response_channel = response,
        )
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        logs, console = make_log_console()

        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(command, gm, console; throw_errors = false)
        end

        @test take!(response) == REJECTED
        @test !isready(response)
        @test !has_component(gm, TileCoord(0, 0))
        @test logs == ["Invalid map edit: expected candidate validation failure"]
        @test isempty(logger.logs)
    end

    @testset "one command ID, queue slot, and response status" begin
        cq = create_command_queue(1)
        coords = [TileCoord(0, 0), TileCoord(1, 0)]
        command = create_do_action_command(cq, coords, :activate; response_channel = Channel{CommandStatus}(1))
        @test try_enqueue_command!(cq, command)
        @test take!(cq.command_channel) === command
        @test !isready(cq.command_channel)
        @test length(command.component_coords) == 2
        @test command.id == cq.last_command.id
    end
end

# ===============================================================
# Tests — dedicated collective commands
# ===============================================================

@testset "DeleteElementsCommand collective behaviour" begin
    cq = create_command_queue(4)
    @test_throws ArgumentError create_delete_elements_command(cq, Set{TileCoord}(), Set{PipeCoord}())

    gamemap = make_gamemap()
    component_coord = TileCoord(0, 0)
    pipe_coord = side_pipe(TileCoord(0, 0))
    set_component!(gamemap, component_coord, PlacedComponent(MockCompBehav(), Q_POS, :primary))
    set_pipe!(gamemap, pipe_coord, PlacedPipe(MockPipeBehav(), :primary))

    process_and_log!(create_delete_elements_command(cq, Set([component_coord]), Set([pipe_coord])), gamemap)

    @test !has_component(gamemap, component_coord)
    @test !has_pipe(gamemap, pipe_coord)
end

# ===============================================================
# Tests — _spacemap_to_ship
# ===============================================================

@testset "_spacemap_to_ship" begin
    # +X stays as +X
    result = HexFlowCalculator._spacemap_to_ship(SVector(10.0, 0.0))
    @test result ≈ SVector(10.0, 0.0)

    # +Y: magnitude preserved, rotated to +X
    result2 = HexFlowCalculator._spacemap_to_ship(SVector(0.0, 5.0))
    @test result2 ≈ SVector(5.0, 0.0)

    # Diagonal: magnitude = 5
    result3 = HexFlowCalculator._spacemap_to_ship(SVector(3.0, 4.0))
    @test result3 ≈ SVector(5.0, 0.0)

    # Near-zero → zero
    result4 = HexFlowCalculator._spacemap_to_ship(SVector(1.0e-12, 0.0))
    @test result4 ≈ SVector(0.0, 0.0)

    # Negative dv — magnitude still positive
    result5 = HexFlowCalculator._spacemap_to_ship(SVector(-10.0, 0.0))
    @test result5 ≈ SVector(10.0, 0.0)

    # Exact zero
    result6 = HexFlowCalculator._spacemap_to_ship(SVector(0.0, 0.0))
    @test result6 ≈ SVector(0.0, 0.0)
end

# ===============================================================
# Tests — Snapshot Storage
# ===============================================================

@testset "create_snapshot_storage — triple buffer" begin
    snap = FlowCalculatorSnapshot(timestamp = 1.0)
    publish_snap, get_snap = create_snapshot_storage(snap)

    # Get returns seeded snapshot
    result = get_snap()
    @test result.timestamp == 1.0
    @test result.gamemap isa GameMap
    @test result.gamestate isa GameState
    @test result.mna isa MNA_StateSnapshot

    # Publish overwrites via raw state objects
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 42.0)
    result2 = get_snap()
    @test result2.timestamp == 42.0

    # Multiple publishes — last write wins
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 100.0)
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 200.0)
    @test get_snap().timestamp == 200.0
end

@testset "render-thread time-lapse recorder" begin
    gamemap = GameMap()
    snapshot = (gamemap = gamemap, timestamp = 1.0)

    recorder = TimelapseRecorder(nothing; now = 0.0)
    @test !recorder.enabled
    @test isnothing(recorder.history)
    @test timelapse_frame_count(recorder) == 0
    @test !capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 0.5)
    @test isnothing(recorder.history)
    @test_throws ArgumentError TimelapseRecorder(TimelapseHistory(format_version = UInt16(1)); now = 0.0)

    loaded_recorder = TimelapseRecorder(TimelapseHistory(); now = 10.0)
    @test loaded_recorder.enabled
    @test loaded_recorder.next_capture_time_seconds == 40.0

    set_timelapse_enabled!(recorder, true; now = 0.0)
    @test recorder.enabled
    @test maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    @test timelapse_frame_count(recorder) == 1
    @test only(recorder.history.frames) === gamemap
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 30.0)

    changed_snapshot = (gamemap = GameMap(), timestamp = 2.0)
    @test maybe_capture_timelapse!(recorder, changed_snapshot; now = 31.0)
    @test timelapse_frame_count(recorder) == 2
    @test recorder.next_capture_time_seconds == 61.0

    suppressed_snapshot = (gamemap = GameMap(), timestamp = 3.0)
    @test !maybe_capture_timelapse!(recorder, suppressed_snapshot; capture_suppressed = true, now = 100.0)
    @test recorder.next_capture_time_seconds == 61.0
    @test maybe_capture_timelapse!(recorder, suppressed_snapshot; now = 101.0)
    @test timelapse_frame_count(recorder) == 3

    before_disable = snapshot_timelapse_history(recorder)::TimelapseHistory
    @test before_disable.frames !== recorder.history.frames
    @test before_disable.frames[1] === gamemap
    @test capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 4.0)
    set_timelapse_enabled!(recorder, false; now = 110.0)
    @test !recorder.enabled
    @test !maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 5.0); now = 200.0)
    @test timelapse_frame_count(recorder) == 4

    set_timelapse_enabled!(recorder, true; now = 200.0)
    reenabled_snapshot = (gamemap = GameMap(), timestamp = 6.0)
    @test maybe_capture_timelapse!(recorder, reenabled_snapshot; now = 200.0)
    @test timelapse_frame_count(recorder) == 5

    prepared = snapshot_timelapse_history(recorder)::TimelapseHistory
    @test capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 7.0)
    @test length(prepared.frames) == 5

    timestamped_map = GameMap()
    @test capture_timelapse_frame!(recorder, timestamped_map; snapshot_timestamp = 8.0)
    @test !capture_timelapse_frame!(recorder, timestamped_map; snapshot_timestamp = 8.0)
    timestampless_map = GameMap()
    @test capture_timelapse_frame!(recorder, timestampless_map)
    @test recorder.last_captured_snapshot_timestamp === nothing
    @test maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 8.0); now = 300.0)
end

@testset "retained render snapshot maps survive buffer reuse" begin
    source_map = GameMap()
    set_recorded_play_time_seconds!(source_map, 12.0)
    initial_snapshot = FlowCalculatorSnapshot(gamemap = source_map, timestamp = 0.0)
    publish_snap, get_snap = create_snapshot_storage(initial_snapshot)

    publish_snap(source_map, DerivedMapState(), MNA_State(), GameState(), 1.0)
    retained_map = get_snap().gamemap
    set_recorded_play_time_seconds!(source_map, 99.0)

    latest_snapshot = nothing
    for timestamp in 2.0:8.0
        publish_snap(source_map, DerivedMapState(), MNA_State(), GameState(), timestamp)
        latest_snapshot = get_snap()
    end

    @test get_recorded_play_time_seconds(retained_map) == 12.0
    @test latest_snapshot.gamemap !== retained_map
end

@testset "snapshot! methods" begin
    # DerivedMapState refill
    src_derived = DerivedMapState()
    push!(src_derived.primaryelements, AbsoluteElement(
        connections = AbsoluteElementConnections(NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS), NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_NEG)),
        value = 1.0,
        type = HexElements.CONST_RESISTOR,
        id = ElementID(TileCoord(0, 0), 1),
    ))
    src_derived.nodeactualfluids[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] = HexFluids.COLD_GAS

    dest_derived = DerivedMapState()
    HexFlowCalculator.snapshot!(dest_derived, src_derived)
    @test length(dest_derived.primaryelements) == 1
    @test length(dest_derived.nodeactualfluids) == 1

    # Refill again with empty — should clear
    HexFlowCalculator.snapshot!(dest_derived, DerivedMapState())
    @test isempty(dest_derived.primaryelements)
    @test isempty(dest_derived.nodeactualfluids)

    # MNA_StateSnapshot refill from MNA_State
    src_mna = MNA_State()
    src_mna.node_voltages[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] = 5.0
    src_mna.vsource_currents[ElementID(TileCoord(0, 0), 1)] = 0.1

    dest_mna = MNA_StateSnapshot()
    HexFlowCalculator.snapshot!(dest_mna, src_mna)
    @test dest_mna.node_voltages[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] == 5.0
    @test dest_mna.vsource_currents[ElementID(TileCoord(0, 0), 1)] == 0.1

    # GameState refill
    src_gs = GameState(ticks = 42, estimated_min_delta_v = 123.0)
    dest_gs = GameState()
    HexFlowCalculator.snapshot!(dest_gs, src_gs)
    @test dest_gs.ticks == 42
    @test dest_gs.estimated_min_delta_v == 123.0
end

@testset "refresh_estimated_min_delta_v!" begin
    gm = GameMap()

    gs_initial = GameState(ticks = 0, estimated_min_delta_v = 42.0)
    HexFlowCalculator.refresh_estimated_min_delta_v!(gs_initial, gm)
    @test gs_initial.estimated_min_delta_v == 0.0

    gs_skip = GameState(ticks = 1, estimated_min_delta_v = 42.0)
    HexFlowCalculator.refresh_estimated_min_delta_v!(gs_skip, gm)
    @test gs_skip.estimated_min_delta_v == 42.0

    gs_modulo = GameState(ticks = HexFlowCalculator.DELTA_V_CACHE_TICK_DIVISOR, estimated_min_delta_v = 42.0)
    HexFlowCalculator.refresh_estimated_min_delta_v!(gs_modulo, gm)
    @test gs_modulo.estimated_min_delta_v == 0.0

    gs_forced = GameState(ticks = 7, estimated_min_delta_v = 42.0)
    HexFlowCalculator.refresh_estimated_min_delta_v!(gs_forced, gm; force = true)
    @test gs_forced.estimated_min_delta_v == 0.0
end

# ===============================================================
# Tests — Console Buffer
# ===============================================================

@testset "create_threadsafe_consolebuffer" begin
    push_msg, see_msgs = create_threadsafe_consolebuffer(5)

    # Initially empty
    @test isempty(see_msgs())

    # Push and see
    push_msg("hello")
    msgs = see_msgs()
    @test length(msgs) == 1
    @test contains(msgs[1], "hello")

    # Messages get timestamped
    @test contains(msgs[1], ":")  # timestamp format HH:MM:SS contains colons

    # Ring buffer wraps at capacity
    for i in 1:10
        push_msg("msg $i")
    end
    msgs2 = see_msgs()
    @test length(msgs2) == 5  # buffer capacity is 5

    # see_messages returns a copy — mutating it doesn't affect buffer
    msgs3 = see_msgs()
    empty!(msgs3)
    @test length(see_msgs()) == 5
end

@testset "create_threadsafe_consolebuffer — invalid length" begin
    @test_throws Exception create_threadsafe_consolebuffer(0)
end

# ===============================================================
# Tests — FlowCalculatorSharedState
# ===============================================================

@testset "FlowCalculatorSharedState — defaults" begin
    ss = FlowCalculatorSharedState()

    @test (@atomic ss.should_exit) == false
    @test (@atomic ss.is_paused) == false
    @test (@atomic ss.target_ups) == BASE_UPS
    @test (@atomic ss.actual_ups) == 0.0
    @test (@atomic ss.target_spacemap_time) == 0.0
    @test get_max_reachable_bounds(ss) == (X_POS = 5.0, X_NEG = -5.0, Y_POS = 5.0, Y_NEG = -5.0)
end

@testset "FlowCalculatorSharedState — atomic operations" begin
    ss = FlowCalculatorSharedState()

    @atomic ss.should_exit = true
    @test (@atomic ss.should_exit) == true

    @atomic ss.is_paused = true
    @test (@atomic ss.is_paused) == true

    @atomic ss.target_ups = 120.0
    @test (@atomic ss.target_ups) == 120.0

    @atomic ss.actual_ups = 59.5
    @test (@atomic ss.actual_ups) == 59.5

    @atomic ss.target_spacemap_time = 42.0
    @test (@atomic ss.target_spacemap_time) == 42.0
end

@testset "FlowCalculatorSharedState — bounds accessors" begin
    ss = FlowCalculatorSharedState()
    bounds = (X_POS = 12.0, X_NEG = -8.0, Y_POS = 7.5, Y_NEG = -3.5)

    set_max_reachable_bounds!(ss, bounds)

    @test get_max_reachable_bounds(ss) == bounds
end

@testset "FlowCalculatorSharedState — keyword constructor" begin
    ss = FlowCalculatorSharedState(target_ups = 30.0, is_paused = true, view_bounds_x_pos = 12.0)
    @test (@atomic ss.target_ups) == 30.0
    @test (@atomic ss.is_paused) == true
    @test (@atomic ss.should_exit) == false  # default
    @test (@atomic ss.target_spacemap_time) == 0.0  # default
    @test (@atomic ss.view_bounds_x_pos) == 12.0
end

# ===============================================================
# Tests — TimingState
# ===============================================================

@testset "TimingState — defaults" begin
    t = TimingState()

    @test t.current_time > 0.0        # initialised to time()
    @test t.last_loop_time > 0.0
    @test t.delta_time == 0.0
    @test t.accumulator == 0.0
    @test t.should_update == false
    @test t.last_update_time > 0.0
    @test !t.saturation_reported
end

@testset "update_ups_metrics! — reports once per saturation episode" begin
    shared_state = FlowCalculatorSharedState()
    timing = TimingState()
    logs, console = make_log_console()
    max_accumulator = (1.0 / BASE_UPS) * 10.0

    timing.accumulator = max_accumulator
    HexFlowCalculator.update_ups_metrics!(shared_state, timing, 0, BASE_UPS, console)
    HexFlowCalculator.update_ups_metrics!(shared_state, timing, 0, BASE_UPS, console)
    @test logs == ["Simulation is running behind its target update rate"]

    timing.accumulator = max_accumulator * 0.4
    HexFlowCalculator.update_ups_metrics!(shared_state, timing, 0, BASE_UPS, console)
    @test !timing.saturation_reported

    timing.accumulator = max_accumulator
    HexFlowCalculator.update_ups_metrics!(shared_state, timing, 0, BASE_UPS, console)
    @test logs == fill("Simulation is running behind its target update rate", 2)
end

@testset "accumulate_time! — basic" begin
    t = TimingState()
    # Simulate 100ms elapsed by backdating last_loop_time
    t.last_loop_time = time() - 0.1

    target_update_time = 1.0 / BASE_UPS  # ~16.67ms
    HexFlowCalculator.accumulate_time!(t, target_update_time)

    @test t.delta_time >= 0.05            # at least ~50ms with tolerance
    @test t.accumulator >= 0.05
    @test t.should_update == true         # 100ms >> 16.67ms target
end

@testset "accumulate_time! — immediate call" begin
    t = TimingState()
    target_update_time = 1.0 / BASE_UPS

    # Called immediately — delta_time should be tiny
    HexFlowCalculator.accumulate_time!(t, target_update_time)
    @test t.delta_time < 0.01             # practically zero
end

@testset "accumulate_time! — accumulator saturation" begin
    t = TimingState()
    target_update_time = 1.0 / BASE_UPS

    # Simulate a very large elapsed time (1 second)
    t.last_loop_time = time() - 1.0
    HexFlowCalculator.accumulate_time!(t, target_update_time)

    # Accumulator should be clamped to target_update_time * 10
    max_accumulator = target_update_time * 10.0
    @test t.accumulator <= max_accumulator + 0.001  # small tolerance
end

# ===============================================================
# Tests — Command Queue
# ===============================================================

@testset "try_enqueue_command!" begin
    cq = create_command_queue(4)
    cmd = create_delete_elements_command(cq, TileCoord(0, 0))

    @test try_enqueue_command!(cq, cmd) == true
end

@testset "CommandQueue — last_command tracking" begin
    cq = create_command_queue(4)
    cmd1 = create_delete_elements_command(cq, TileCoord(0, 0))
    cmd2 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

    try_enqueue_command!(cq, cmd1)
    @test cq.last_command === cmd1

    try_enqueue_command!(cq, cmd2)
    @test cq.last_command === cmd2
end

@testset "CommandQueue — failed enqueue" begin
    cq = create_command_queue(1)
    first_command = create_delete_elements_command(cq, TileCoord(0, 0))
    @test try_enqueue_command!(cq, first_command)
    close(cq.command_channel)

    failed_command = create_delete_elements_command(cq, TileCoord(1, 0))
    logs, console = make_log_console()
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        @test !try_enqueue_command!(cq, failed_command)
    end

    @test cq.last_command === first_command
    @test isempty(logs)
    enqueue_log = only(filter(log -> log.message == "Failed to enqueue map edit command", logger.logs))
    @test enqueue_log.kwargs[:command_context].type == :DeleteElementsCommand
    @test enqueue_log.kwargs[:command_context].id == failed_command.id
    @test !isempty(enqueue_log.kwargs[:exception][2])
end

# ===============================================================
# Tests — scale_node_voltages!
# ===============================================================

@testset "scale_node_voltages! — empty" begin
    mna = MNA_State()
    scale_node_voltages!(mna)
    @test isempty(mna.node_voltages_scaled)
end

@testset "scale_node_voltages! — single entry" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    mna = MNA_State(node_voltages = Dict(nc => 10.0))
    scale_node_voltages!(mna)
    @test mna.node_voltage_scale_max == 10.0
    @test mna.node_voltages_scaled[nc] == 1.0
end

@testset "scale_node_voltages! — zero solution repairs non-positive scale" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    mna = MNA_State(node_voltages = Dict(nc => 0.0), node_voltage_scale_max = 0.0)
    scale_node_voltages!(mna)
    @test mna.node_voltage_scale_max == eps(Float64)
    @test mna.node_voltages_scaled[nc] == 0.0
end

@testset "scale_node_voltages! — all-negative solution keeps finite scaled values" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    mna = MNA_State(node_voltages = Dict(nc => -5.0))
    scale_node_voltages!(mna)
    @test mna.node_voltage_scale_max == eps(Float64)
    @test isfinite(mna.node_voltages_scaled[nc])
end

@testset "scale_node_voltages! — relative ordering preserved" begin
    nc1 = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    nc2 = NodeCoord(TileCoord(1, 0), HexFrame.NODE_Q_POS)

    mna = MNA_State(node_voltages = Dict(nc1 => 100.0, nc2 => 50.0))
    scale_node_voltages!(mna)
    @test mna.node_voltages_scaled[nc1] > mna.node_voltages_scaled[nc2]  # higher voltage → higher scaled value
end

@testset "scale_node_voltages! — histories are isolated by MNA state" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    high_voltage_mna = MNA_State(node_voltages = Dict(nc => 100.0))
    scale_node_voltages!(high_voltage_mna)
    high_voltage_mna.node_voltages[nc] = 10.0
    scale_node_voltages!(high_voltage_mna)

    low_voltage_mna = MNA_State(node_voltages = Dict(nc => 10.0))
    scale_node_voltages!(low_voltage_mna)

    @test high_voltage_mna.node_voltage_scale_max == 100.0
    @test high_voltage_mna.node_voltages_scaled[nc] == 0.1
    @test low_voltage_mna.node_voltage_scale_max == 10.0
    @test low_voltage_mna.node_voltages_scaled[nc] == 1.0
end

# ===============================================================
# Tests — handle_thrusters!
# ===============================================================

@testset "handle_thrusters! — empty map" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    handle_thrusters!(gs, gm, derived, mna)

    # No components → no thrust
    @test gs.thrust ≈ SVector(0.0, 0.0)
    @test gs.acceleration_ship_frame ≈ SVector(0.0, 0.0)
    @test gs.acceleration_space_map_frame ≈ SVector(0.0, 0.0)
    @test get_total_delta_v(gm) == 0.0
    @test get_peak_thrust(gm) == 0.0
end

@testset "handle_thrusters! — velocity unchanged with no thrust" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    set_velocity!(gm, SVector(100.0, 50.0))
    initial_vel = get_velocity(gm)

    handle_thrusters!(gs, gm, derived, mna)

    # With no thrust, velocity should remain unchanged
    @test get_velocity(gm) ≈ initial_vel
end

@testset "handle_thrusters! — sets acceleration per-second" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    # base_ups defaults to BASE_UPS, acceleration is stored in per-second units (F/m)
    handle_thrusters!(gs, gm, derived, mna; base_ups = BASE_UPS)
    @test gs.acceleration_ship_frame ≈ SVector(0.0, 0.0)  # zero thrust → zero accel
    @test gs.acceleration_space_map_frame ≈ SVector(0.0, 0.0)
end

@testset "handle_thrusters! — records propulsion statistics" begin
    gm = make_gamemap()
    set_component!(gm, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(3.0, 4.0)), Q_POS, :primary))
    gs = GameState()
    derived = DerivedMapState()
    mna = MNA_State()

    initial_velocity = get_velocity(gm)
    handle_thrusters!(gs, gm, derived, mna)
    velocity_change = get_velocity(gm) - initial_velocity
    expected_delta_v = norm(gs.acceleration_space_map_frame / BASE_UPS)

    @test get_peak_thrust(gm) == 5.0
    @test get_total_delta_v(gm) ≈ expected_delta_v
    @test norm(velocity_change) ≈ expected_delta_v

    set_component!(gm, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(-3.0, -4.0)), Q_POS, :primary))
    handle_thrusters!(gs, gm, derived, mna)
    @test get_total_delta_v(gm) ≈ 2 * expected_delta_v
    @test get_peak_thrust(gm) == 5.0

    low_thrust = SVector(0.0, 1.0)
    set_component!(gm, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(low_thrust), Q_POS, :primary))
    handle_thrusters!(gs, gm, derived, mna)
    @test get_peak_thrust(gm) == 5.0

    scaled_map = make_gamemap()
    set_component!(scaled_map, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(3.0, 4.0)), Q_POS, :primary))
    scaled_state = GameState()
    scaled_initial_velocity = get_velocity(scaled_map)
    handle_thrusters!(scaled_state, scaled_map, DerivedMapState(), MNA_State(); base_ups = 10.0)
    scaled_velocity_change = get_velocity(scaled_map) - scaled_initial_velocity
    scaled_expected_delta_v = norm(scaled_state.acceleration_space_map_frame / 10.0)
    @test get_total_delta_v(scaled_map) ≈ scaled_expected_delta_v
    @test norm(scaled_velocity_change) ≈ scaled_expected_delta_v
end

# ===============================================================
# Tests — Galaxy escape calculator integration
# ===============================================================

@testset "StartGalaxyEscapeCommand" begin
    command_queue = create_command_queue(16)

    @testset "creator and eligibility rejections" begin
        response = Channel{CommandStatus}(1)
        command = create_start_galaxy_escape_command(command_queue; response_channel = response)
        @test command isa StartGalaxyEscapeCommand
        @test command.response_channel === response

        locked_map = make_gamemap()
        initialise_spacemap!(locked_map, UInt32(1), _test_enc_config)
        @test process_and_log!(command, locked_map) == ["Galaxy escape has not been discovered yet"]
        @test take!(response) == INVALID
        @test locked_map.space_map isa SpaceMapState

        empty_map = GameMap()
        record_peak_estimated_delta_v!(empty_map, GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V)
        @test process_and_log!(create_start_galaxy_escape_command(command_queue), empty_map) ==
            ["Galaxy escape can only begin from normal galactic navigation"]
        @test empty_map.space_map isa SpaceMapEmpty

        active_map = GameMap(space_map = GalaxyEscapeSpaceMap(
            velocity = SVector(5.0, 0.0), starting_velocity_x = 5.0, departure_time_years = 2.0,
            pre_escape_map = GameMap(),
        ))
        record_peak_estimated_delta_v!(active_map, GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V)
        @test process_and_log!(create_start_galaxy_escape_command(command_queue), active_map) ==
            ["Galaxy escape can only begin from normal galactic navigation"]
        @test active_map.space_map isa GalaxyEscapeSpaceMap
    end

    @testset "rejects malformed normal navigation state" begin
        invalid_velocity_map = make_galaxy_escape_ready_map()
        invalid_velocity_map.space_map.velocity = SVector(Inf, 0.0)
        @test process_and_log!(create_start_galaxy_escape_command(command_queue), invalid_velocity_map) ==
            ["Cannot begin galaxy escape with a non-finite velocity"]
        @test invalid_velocity_map.space_map isa SpaceMapState

        invalid_time_map = make_galaxy_escape_ready_map()
        invalid_time_map.space_map.time_years = -1.0
        @test process_and_log!(create_start_galaxy_escape_command(command_queue), invalid_time_map) ==
            ["Cannot begin galaxy escape with an invalid galactic time"]
        @test invalid_time_map.space_map isa SpaceMapState
    end

    @testset "atomically replaces normal navigation and an active manoeuvre" begin
        initial_velocity = SVector(120.0, -8.0)
        gamemap = make_galaxy_escape_ready_map(velocity = initial_velocity, time_years = 35.0)
        normal_space_map = gamemap.space_map::SpaceMapState
        normal_space_map.position = SVector(400.0, -250.0)
        normal_space_map.target_time_years = 80.0
        normal_space_map.last_stop_time = 30.0
        normal_space_map.is_time_progressing = true
        push!(normal_space_map.encounter_points, EncounterPoint(index = 1, base_velocity = 50.0))
        normal_space_map.active_manoeuvre = ManoeuvreData(
            approach_burn_dv = SVector(3.0, 4.0),
            capture_burn_dv = SVector(-3.0, -4.0),
            target_encounter_index = 1,
        )
        response = Channel{CommandStatus}(1)
        expected_pre_escape_map = deepcopy(gamemap)

        logs = process_and_log!(create_start_galaxy_escape_command(command_queue; response_channel = response), gamemap)

        @test take!(response) == APPLIED
        @test logs == ["Galaxy escape begun. Galactic navigation is no longer available."]
        @test gamemap.space_map isa GalaxyEscapeSpaceMap
        escape_map = gamemap.space_map::GalaxyEscapeSpaceMap
        captured_map = get_pre_escape_map(escape_map)
        @test captured_map !== expected_pre_escape_map
        @test captured_map.components == expected_pre_escape_map.components
        @test captured_map.pipe_behaviors == expected_pre_escape_map.pipe_behaviors
        @test captured_map.surface_shiptags == expected_pre_escape_map.surface_shiptags
        @test captured_map.statistics == expected_pre_escape_map.statistics
        captured_space_map = captured_map.space_map::SpaceMapState
        expected_space_map = expected_pre_escape_map.space_map::SpaceMapState
        @test captured_space_map.velocity == expected_space_map.velocity
        @test captured_space_map.position == expected_space_map.position
        @test captured_space_map.time_years == expected_space_map.time_years
        @test captured_space_map.target_time_years == expected_space_map.target_time_years
        @test captured_space_map.active_manoeuvre == expected_space_map.active_manoeuvre
        @test length(captured_space_map.encounter_points) == length(expected_space_map.encounter_points)
        @test only(captured_space_map.encounter_points) !== only(expected_space_map.encounter_points)
        @test only(captured_space_map.encounter_points).index == only(expected_space_map.encounter_points).index
        @test only(captured_space_map.encounter_points).base_velocity == only(expected_space_map.encounter_points).base_velocity
        @test can_abort_galaxy_escape(gamemap)
        @test get_velocity(escape_map) == initial_velocity
        @test escape_map.starting_velocity_x == initial_velocity[1]
        @test get_time_years(escape_map) == 35.0
        @test galaxy_escape_progress(escape_map) == 0.0
        @test get_position(escape_map) == SVector(0.0, 0.0)
        @test get_target_time(escape_map) == 35.0
        @test isempty(get_encounter_points(escape_map))
        @test !has_active_manoeuvre(escape_map)
    end

    @testset "ordinary topology and component actions remain available" begin
        gamemap = make_galaxy_escape_ready_map()
        set_component!(gamemap, TileCoord(0, 0), PlacedComponent(StatefulActionCompBehav(0), Q_POS, :primary))
        process_and_log!(create_start_galaxy_escape_command(command_queue), gamemap)

        action_logs = process_and_log!(create_do_action_command(command_queue, TileCoord(0, 0), :activate), gamemap)
        @test action_logs == ["Activated"]
        @test get_component(gamemap, TileCoord(0, 0)).component.activations == 1
        @test get_component(get_pre_escape_map(gamemap), TileCoord(0, 0)).component.activations == 0

        new_surface = TileCoord(1, 0)
        @test isempty(process_and_log!(create_add_ship_surface_command(command_queue, new_surface), gamemap))
        @test is_on_surface_tile(new_surface, gamemap)
        @test !is_on_surface_tile(new_surface, get_pre_escape_map(gamemap))
        @test gamemap.space_map isa GalaxyEscapeSpaceMap
    end
end

@testset "Galaxy escape burn progress uses authoritative velocity" begin
    gamemap = make_galaxy_escape_ready_map(velocity = SVector(50.0, 7.0), time_years = 9.0)
    add_ship!(gamemap, :docked_ship, ShipState())
    set_surface_tile!(gamemap, TileCoord(20, 0); ship_name = :docked_ship)
    thrust = 2.0 * get_tile_mass()
    set_component!(gamemap, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(thrust, 0.0)), Q_POS, :primary))

    process_and_log!(create_start_galaxy_escape_command(create_command_queue()), gamemap)
    escape_map = gamemap.space_map::GalaxyEscapeSpaceMap
    gamestate = GameState()
    derived = DerivedMapState()
    mna = MNA_State()

    handle_thrusters!(gamestate, gamemap, derived, mna; base_ups = 1.0)
    @test gamestate.acceleration_space_map_frame == SVector(1.0, 0.0)
    @test galaxy_escape_progress(escape_map) == 1.0

    set_component!(gamemap, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(-thrust, 0.0)), Q_POS, :primary))
    handle_thrusters!(gamestate, gamemap, derived, mna; base_ups = 1.0)
    @test galaxy_escape_progress(escape_map) == 0.0

    set_component!(gamemap, TileCoord(0, 0), PlacedComponent(FixedThrustCompBehav(SVector(0.0, thrust)), Q_POS, :primary))
    handle_thrusters!(gamestate, gamemap, derived, mna; base_ups = 1.0)
    @test get_velocity(escape_map) == SVector(50.0, 8.0)
    @test galaxy_escape_progress(escape_map) == 0.0
    @test get_total_delta_v(gamemap) == 3.0

    departure_time = get_time_years(escape_map)
    @test !step_space_map_time!(escape_map, 1000.0)
    @test get_time_years(escape_map) == departure_time
end

@testset "Calculator refresh records a permanent estimated delta-V peak" begin
    gamemap = make_gamemap()
    set_component!(
        gamemap,
        TileCoord(0, 0),
        PlacedComponent(DeltaVEstimateCompBehav(10.0, 1000.0), Q_POS, :primary),
    )
    gamestate = GameState(ticks = 1)

    HexFlowCalculator.refresh_estimated_min_delta_v!(gamestate, gamemap)
    @test gamestate.estimated_min_delta_v == 0.0
    @test get_peak_estimated_delta_v(gamemap) == 0.0

    gamestate.ticks = 30
    HexFlowCalculator.refresh_estimated_min_delta_v!(gamestate, gamemap)
    recorded_peak = get_peak_estimated_delta_v(gamemap)
    @test recorded_peak == gamestate.estimated_min_delta_v
    @test is_galaxy_escape_unlocked(recorded_peak)

    delete_component!(gamemap, TileCoord(0, 0))
    HexFlowCalculator.refresh_estimated_min_delta_v!(gamestate, gamemap; force = true)
    @test gamestate.estimated_min_delta_v == 0.0
    @test get_peak_estimated_delta_v(gamemap) == recorded_peak
    @test is_galaxy_escape_unlocked(get_peak_estimated_delta_v(gamemap))
end

# ===============================================================
# Tests — Reactivation Scheduler
# ===============================================================

@testset "run_reactivation_trial! — singular probe stays isolated" begin
    gamemap = make_gamemap()
    probe_tile = TileCoord(1, 0)
    set_surface_tile!(gamemap, probe_tile; ship_name = :primary)

    set_component!(gamemap, TileCoord(0, 0), PlacedComponent(GroundedAnchorCompBehav(), Q_POS, :primary))
    set_component!(gamemap, probe_tile, PlacedComponent(SingularProbeCompBehav(false), Q_POS, :primary))

    live_derived = DerivedMapState()
    live_mna = MNA_State()
    live_scratchpad = CalculatorScratchpad()

    update_components!(gamemap, live_mna, live_derived)
    collect_primary_map_inputs!(gamemap, live_derived)
    solve_from_inputs!(live_derived, live_mna, live_scratchpad, Int64(1))

    baseline_elements = copy(live_derived.filteredelements)
    baseline_voltages = copy(live_mna.node_voltages)

    scheduler = HexFlowCalculator.ReactivationScheduler()
    HexFlowCalculator.scan_reactivation_requests!(scheduler, gamemap)
    @test scheduler.pending == [probe_tile]

    probe_comp = something(get_component(gamemap, probe_tile))
    HexFlowCalculator.load_reactivation_probe!(scheduler, probe_comp, probe_tile)

    trial_derived = DerivedMapState()
    resize!(trial_derived.primaryelements, length(live_derived.primaryelements))
    copyto!(trial_derived.primaryelements, live_derived.primaryelements)
    append!(trial_derived.primaryelements, scheduler.probe_elements)
    resize!(trial_derived.primary_fluid_declarations, length(live_derived.primary_fluid_declarations))
    copyto!(trial_derived.primary_fluid_declarations, live_derived.primary_fluid_declarations)
    append!(trial_derived.primary_fluid_declarations, scheduler.probe_declarations)

    @test_throws SingularException solve_from_inputs!(trial_derived, MNA_State(), CalculatorScratchpad(), Int64(1))

    @test HexFlowCalculator.run_reactivation_trial!(scheduler, gamemap, live_derived, live_mna, live_scratchpad, Int64(1))
    @test isempty(scheduler.pending)
    @test !get_component(gamemap, probe_tile).component.accepted
    @test live_derived.filteredelements == baseline_elements
    @test live_mna.node_voltages == baseline_voltages
end

@testset "run_reactivation_trial! — accepted bootstrap probe is reflected by committed rebuild" begin
    gamemap = make_gamemap()
    probe_tile = TileCoord(0, 0)
    probe_comp = BootstrapProbeCompBehav(0.0, 5.0, false, false)
    set_component!(gamemap, probe_tile, PlacedComponent(probe_comp, Q_POS, :primary))

    live_derived = DerivedMapState()
    live_mna = MNA_State()
    live_scratchpad = CalculatorScratchpad()
    scheduler = HexFlowCalculator.ReactivationScheduler()

    update_components!(gamemap, live_mna, live_derived)
    HexFlowCalculator.scan_reactivation_requests!(scheduler, gamemap)
    collect_primary_map_inputs!(gamemap, live_derived)

    @test isempty(live_derived.primaryelements)
    @test HexFlowCalculator.run_reactivation_trial!(scheduler, gamemap, live_derived, live_mna, live_scratchpad, Int64(1))
    @test probe_comp.accepted
    @test haskey(live_mna.vsource_currents, ElementID(probe_tile, 1))

    update_components!(gamemap, live_mna, live_derived)
    @test probe_comp.charge > 0.0

    collect_primary_map_inputs!(gamemap, live_derived)
    solve_from_inputs!(live_derived, live_mna, live_scratchpad, Int64(2))
    @test haskey(live_mna.vsource_currents, ElementID(probe_tile, 1))
end

@testset "run_reactivation_trial! — grouped neutral retry commits useful subset" begin
    gamemap = make_gamemap()
    anchor_tile = TileCoord(0, 0)
    peer_tile = TileCoord(1, 0)
    neutral_tile = TileCoord(2, 0)

    anchor_comp = GroupedNeutralProbeCompBehav(2, false, false, false)
    peer_comp = GroupedNeutralProbeCompBehav(2, false, false, false)
    neutral_comp = GroupedNeutralProbeCompBehav(99, false, false, true)

    set_component!(gamemap, anchor_tile, PlacedComponent(anchor_comp, Q_POS, :primary))
    set_component!(gamemap, peer_tile, PlacedComponent(peer_comp, Q_POS, :primary))
    set_component!(gamemap, neutral_tile, PlacedComponent(neutral_comp, Q_POS, :primary))

    live_derived = DerivedMapState()
    live_mna = MNA_State()
    live_scratchpad = CalculatorScratchpad()
    scheduler = HexFlowCalculator.ReactivationScheduler()

    update_components!(gamemap, live_mna, live_derived)
    collect_primary_map_inputs!(gamemap, live_derived)
    solve_from_inputs!(live_derived, live_mna, live_scratchpad, Int64(1))

    HexFlowCalculator.push_neutral_registry!(scheduler, anchor_tile)
    HexFlowCalculator.push_neutral_registry!(scheduler, neutral_tile)
    push!(scheduler.pending, peer_tile)
    push!(scheduler.pending_set, peer_tile)

    @test HexFlowCalculator.run_reactivation_trial!(scheduler, gamemap, live_derived, live_mna, live_scratchpad, Int64(2))
    @test anchor_comp.committed
    @test peer_comp.committed
    @test neutral_tile in scheduler.neutral_registry
    @test !(anchor_tile in scheduler.neutral_registry)
    @test !(peer_tile in scheduler.neutral_registry)
    @test !(peer_tile in scheduler.pending_set)
end

@testset "run_reactivation_trial! — harmful grouped member aborts retry and is evicted" begin
    gamemap = make_gamemap()
    anchor_tile = TileCoord(0, 0)
    harmful_tile = TileCoord(1, 0)

    anchor_comp = GroupedNeutralProbeCompBehav(2, false, false, false)
    harmful_comp = HarmfulGroupedProbeCompBehav(false)

    set_component!(gamemap, anchor_tile, PlacedComponent(anchor_comp, Q_POS, :primary))
    set_component!(gamemap, harmful_tile, PlacedComponent(harmful_comp, Q_POS, :primary))

    live_derived = DerivedMapState()
    live_mna = MNA_State()
    live_scratchpad = CalculatorScratchpad()
    scheduler = HexFlowCalculator.ReactivationScheduler()

    update_components!(gamemap, live_mna, live_derived)
    collect_primary_map_inputs!(gamemap, live_derived)
    solve_from_inputs!(live_derived, live_mna, live_scratchpad, Int64(1))

    HexFlowCalculator.push_neutral_registry!(scheduler, harmful_tile)
    push!(scheduler.pending, anchor_tile)
    push!(scheduler.pending_set, anchor_tile)

    @test HexFlowCalculator.run_reactivation_trial!(scheduler, gamemap, live_derived, live_mna, live_scratchpad, Int64(2))
    @test !anchor_comp.committed
    @test !harmful_comp.committed
    @test !(harmful_tile in scheduler.neutral_registry)
    @test anchor_tile in scheduler.neutral_registry
end

# ===============================================================
# Tests — Manoeuvre Guard Helpers
# ===============================================================

@testset "cancel_if_thrust! — zero thrust" begin
    gm = GameMap()
    gs = GameState()
    gs.thrust = SVector(0.0, 0.0)

    # Below threshold → no cancellation
    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == false
end

@testset "cancel_if_thrust! — above threshold cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    gs = GameState()
    gs.thrust = SVector(10.0, 0.0)  # well above MANOEUVRE_THRUST_THRESHOLD (0.1)

    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_thrust! — at threshold" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    gs = GameState()
    gs.thrust = SVector(MANOEUVRE_THRUST_THRESHOLD, 0.0)  # exactly at threshold

    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == false  # <= threshold → no cancel
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_time_progressing! — SpaceMapEmpty" begin
    gm = GameMap()  # default SpaceMapEmpty

    # SpaceMapEmpty → not a SpaceMapState → returns false
    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == false
end

@testset "cancel_if_time_progressing! — time not progressing" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 3.0)  # target behind current → not progressing

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == false
    @test has_active_manoeuvre(gm)  # NOT cancelled
end

@testset "cancel_if_time_progressing! — time progressing cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 10.0)  # target ahead → progressing

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — time matches" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.0) == false
    @test has_active_manoeuvre(gm)
end

# ===============================================================
# Tests — RedockShipCommand
# ===============================================================

@testset "RedockShipCommand" begin
    cq = create_command_queue(16)

    @testset "valid redock moves ship and starts animation" begin
        gm = make_gamemap()
        add_ship!(gm, :asteroid, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, Set(TileCoord(10, r) for r in -1:1); ship_name = :asteroid)

        delta = TileCoord(-3, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)
        logs = process_and_log!(cmd, gm)

        # Ship should now be offset by delta (originally at 10,0 → 7,0)
        new_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid)
        @test TileCoord(7, 0) in new_tiles

        # Should be in approaching state (animating)
        status = FlowMap.get_docking_status(gm, :asteroid)
        @test status isa FlowMap.ApproachingDockStat
        @test isempty(logs)
    end

    @testset "rejects placement too close to another ship" begin
        gm = make_gamemap()
        add_ship!(gm, :asteroid, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, Set(TileCoord(5, r) for r in -1:1); ship_name = :asteroid)

        # Try to move directly on top of primary ship at (0,0)
        delta = TileCoord(-5, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)

        # Should not mutate the map (rejected via console message)
        original_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid)
        logs = process_and_log!(cmd, gm)
        @test collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid) == original_tiles
        @test logs == ["Cannot redock here: move the ship until its highlighted footprint no longer overlaps another ship's clearance area"]
    end

    @testset "rejects placement when pipe clearance overlaps another ship" begin
        gm = make_gamemap()
        add_ship!(gm, :asteroid, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, TileCoord(10, 0); ship_name = :asteroid)
        set_pipe!(gm, side_pipe(TileCoord(15, 0)), MockPipeBehav(); ship_name = :asteroid)

        cmd = create_redock_ship_command(cq, :asteroid, TileCoord(-15, 0))
        original_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid)
        logs = process_and_log!(cmd, gm)

        @test collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid) == original_tiles
        @test logs == ["Cannot redock here: move the ship until its highlighted footprint no longer overlaps another ship's clearance area"]
    end

    @testset "rejects redock of nonexistent ship" begin
        gm = GameMap()
        delta = TileCoord(1, 0)
        cmd = create_redock_ship_command(cq, :nonexistent, delta)
        @test isempty(process_and_log!(cmd, gm))
    end

    @testset "primary redock is a centrally logged programming failure" begin
        gm = make_gamemap()
        response = Channel{CommandStatus}(1)
        cmd = create_redock_ship_command(cq, :primary, TileCoord(1, 0); response_channel = response)
        logs, console = make_log_console()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)

        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(cmd, gm, console; throw_errors = false)
        end

        @test take!(response) == REJECTED
        @test !isready(response)
        @test isempty(logs)
        @test any(log -> log.message == "Map edit command threw an exception", logger.logs)
    end

    @testset "animation completes after redock" begin
        gm = make_gamemap()
        add_ship!(gm, :asteroid, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, Set(TileCoord(10, r) for r in -1:1); ship_name = :asteroid)

        delta = TileCoord(-3, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)
        process_and_log!(cmd, gm)

        # Animate to completion
        for _ in 1:5000
            FlowMap.update_docking!(gm; ship_name = :asteroid)
            s = FlowMap.get_docking_status(gm, :asteroid)
            s isa FlowMap.ConnectedDockStat && break
        end

        final_status = FlowMap.get_docking_status(gm, :asteroid)
        @test final_status isa FlowMap.ConnectedDockStat
    end
end

# ===============================================================
# Tests — AddEncounterShipCommand
# ===============================================================

@testset "AddEncounterShipCommand" begin
    cq = create_command_queue(16)

    @testset "explicit direction adds ship with merged blueprint contents" begin
        gm = make_gamemap()
        blueprint = make_encounter_test_blueprint()
        before_ships = Set(get_all_ship_names(gm))

        cmd = create_add_encounter_ship_command(
            cq, blueprint, "test_enc", UInt32(42);
            dir = HexFrame.Q_POS,
            target_encounter_index = nothing,
            max_view_bounds = nothing
        )

        # Verify command was created
        @test cmd isa AddEncounterShipCommand
        @test cmd.blueprint.ship_tiles == blueprint.ship_tiles
        @test cmd.dir === HexFrame.Q_POS
        @test cmd.target_encounter_index === nothing

        # Apply the command
        logs = process_and_log!(cmd, gm)
        new_ship = assert_encounter_ship_added!(gm, blueprint, before_ships)
        status = get_docking_status(gm, new_ship)

        @test status isa ApproachingDockStat
        @test get_render_offset(status) isa AxialCoord
        only_comp = only(each_component_of_ship(gm, new_ship))
        @test only_comp.component isa MockCompBehav
        @test only_comp.rotation == Q_POS

        @test !any(contains(log, "Invalid map edit") for log in logs)
        @test isempty(get_playthrough_statistics(gm).completed_encounters)
        @test get_total_encounter_count(gm) == 0
    end

    @testset "optimal direction adds ship with approaching dock status" begin
        gm = make_gamemap()
        blueprint = make_encounter_test_blueprint()
        before_ships = Set(get_all_ship_names(gm))

        cmd = create_add_encounter_ship_command(
            cq, blueprint, "test_enc2", UInt32(43);
            dir = nothing,  # Trigger optimal direction
            target_encounter_index = nothing,
            max_view_bounds = nothing
        )

        # Verify command structure
        @test cmd isa AddEncounterShipCommand
        @test cmd.dir === nothing  # Should request optimal direction

        logs = process_and_log!(cmd, gm)
        new_ship = assert_encounter_ship_added!(gm, blueprint, before_ships)
        status = get_docking_status(gm, new_ship)

        @test status isa ApproachingDockStat
        @test get_render_offset(status) isa AxialCoord
        @test !any(contains(log, "Invalid map edit") for log in logs)
    end

    @testset "tile-only blueprint still creates a ship" begin
        gm = make_gamemap()
        blueprint = ShipBlueprint(ship_tiles = Set([TileCoord(0, 0)]))
        before_ships = Set(get_all_ship_names(gm))

        cmd = create_add_encounter_ship_command(
            cq, blueprint, "minimal_ship", UInt32(44);
            dir = HexFrame.Q_POS,
            target_encounter_index = nothing,
            max_view_bounds = nothing
        )

        logs = process_and_log!(cmd, gm)
        new_ship = assert_encounter_ship_added!(gm, blueprint, before_ships)

        @test get_docking_status(gm, new_ship) isa ApproachingDockStat
        @test count_components(gm; ship_name = new_ship) == 0
        @test count_pipes(gm; ship_name = new_ship) == 0
        @test !any(contains(log, "Invalid map edit") for log in logs)
    end

    @testset "command creation preserves blueprint data" begin
        blueprint = make_encounter_test_blueprint()

        cmd = create_add_encounter_ship_command(
            cq, blueprint, "data_test", UInt32(45)
        )

        @test cmd.blueprint !== blueprint
        @test cmd.blueprint.ship_tiles == blueprint.ship_tiles
        @test keys(cmd.blueprint.components) == keys(blueprint.components)
        @test keys(cmd.blueprint.pipe_behaviors) == keys(blueprint.pipe_behaviors)
        @test only(values(cmd.blueprint.components)).ship == :_blueprint
    end

    @testset "live encounter recycles encounter point and clears manoeuvre" begin
        gm = make_gamemap()
        blueprint = make_encounter_test_blueprint(include_pipe = false)
        before_ships = Set(get_all_ship_names(gm))
        initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
        push!(get_encounter_points(gm), make_trigger_test_encounter_point())
        set_time_years!(gm, 5.0)

        man = ManoeuvreData(
            approach_burn_dv = SVector(1.0, 0.0),
            capture_burn_dv = SVector(-1.0, 0.0),
            target_encounter_index = 1,
        )
        set_active_manoeuvre!(gm, man)

        cmd = create_add_encounter_ship_command(
            cq, blueprint, "live_encounter", UInt32(46);
            dir = HexFrame.Q_POS,
            target_encounter_index = 1,
        )

        logs = process_and_log!(cmd, gm)
        new_ship = assert_encounter_ship_added!(gm, blueprint, before_ships)
        encounter_point = only(get_encounter_points(gm))

        @test get_docking_status(gm, new_ship) isa ApproachingDockStat
        @test !has_active_manoeuvre(gm)
        @test encounter_point.spawn_time == 5.0
        @test isempty(logs)
        @test !any(contains(log, "Invalid map edit") for log in logs)
        @test get_encounter_count(gm, ENCOUNTER_SHIP) == 1
        @test get_total_encounter_count(gm) == 1
    end

    @testset "rejected live encounter does not record statistics" begin
        gm = make_gamemap()
        invalid_blueprint = ShipBlueprint(
            ship_tiles = Set([TileCoord(0, 0)]),
            components = Dict(
                TileCoord(0, 0) => PlacedComponent(InvalidFluidBridgeCompBehav(), Q_POS, :_blueprint),
            ),
        )
        initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
        push!(get_encounter_points(gm), make_trigger_test_encounter_point())

        cmd = create_add_encounter_ship_command(
            cq, invalid_blueprint, "invalid_live_encounter", UInt32(47);
            dir = HexFrame.Q_POS,
            target_encounter_index = 1,
        )
        logs, console = make_log_console()
        HexFlowCalculator.process_command!(cmd, gm, console; throw_errors = false)

        @test isempty(get_playthrough_statistics(gm).completed_encounters)
        @test get_total_encounter_count(gm) == 0
        @test get_all_ship_names(gm) == [:primary]
        @test any(contains(log, "Invalid map edit") for log in logs)
    end

    @testset "queued live encounter becomes stale after galaxy departure" begin
        gm = make_galaxy_escape_ready_map()
        blueprint = make_encounter_test_blueprint(include_pipe = false)
        before_ships = get_all_ship_names(gm)
        response = Channel{CommandStatus}(1)
        queued_encounter = create_add_encounter_ship_command(
            cq,
            blueprint,
            "stale_live_encounter",
            UInt32(48);
            dir = HexFrame.Q_POS,
            target_encounter_index = 1,
            response_channel = response,
        )
        process_and_log!(create_start_galaxy_escape_command(cq), gm)

        logs = process_and_log!(queued_encounter, gm)

        @test take!(response) == INVALID
        @test isempty(logs)
        @test get_all_ship_names(gm) == before_ships
        @test get_total_encounter_count(gm) == 0
        @test gm.space_map isa GalaxyEscapeSpaceMap
    end
end

@testset "process_command! rejects invalid fluid bridge placements" begin
    gm = GameMap()
    set_surface_tile!(gm, TileCoord(0, 0))

    cq = create_command_queue(4)
    cmd = create_set_tile_command(cq, TileCoord(0, 0), InvalidFluidBridgeCompBehav(), Q_POS)
    logs, console = make_log_console()
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)

    Base.CoreLogging.with_logger(logger) do
        caught_error = try
            HexFlowCalculator.process_command!(cmd, gm, console, throw_errors = true)
            nothing
        catch error
            error
        end
        @test caught_error isa FluidCompatibilityError
        @test caught_error isa ExpectedMapValidationError
    end
    @test !has_component(gm, TileCoord(0, 0))
    @test logs == ["Invalid map edit: Fluid MONOPROP_GAS incompatible with constraint IS_LIQUID"]
    @test isempty(logger.logs)
end

@testset "process_command! — response channels" begin
    @testset "writes APPLIED on success" begin
        gm = make_gamemap()
        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)

        cmd = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS; response_channel = ch)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = false)

        @test take!(ch) == APPLIED
        @test has_component(gm, TileCoord(0, 0))
    end

    @testset "writes INVALID when apply method refuses" begin
        gm = make_gamemap()
        set_component!(gm, TileCoord(0, 0),
            PlacedComponent(MockCompBehav(), Q_POS, false, :primary))

        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)
        cmd = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS;
            response_channel = ch)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = false)

        @test take!(ch) == INVALID
    end

    @testset "writes REJECTED for unsupported action and logs once" begin
        gm = make_gamemap()
        set_component!(gm, TileCoord(0, 0),
            PlacedComponent(ActionCompBehav(), Q_POS, false, :primary))

        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)
        cmd = create_do_action_command(cq, TileCoord(0, 0), :no_such_action;
            response_channel = ch)
        logs, console = make_log_console()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(cmd, gm, console, throw_errors = false)
        end

        @test take!(ch) == REJECTED
        @test !isready(ch)
        @test isempty(logs)
        @test any(log -> log.message == "Map edit command threw an exception", logger.logs)
    end

    @testset "writes REJECTED for expected candidate validation" begin
        gm = GameMap()
        set_surface_tile!(gm, TileCoord(0, 0))
        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)

        cmd = create_set_tile_command(cq, TileCoord(0, 0), InvalidFluidBridgeCompBehav(), Q_POS; response_channel = ch)
        logs, console = make_log_console()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(logger) do
            HexFlowCalculator.process_command!(cmd, gm, console, throw_errors = false)
        end

        @test take!(ch) == REJECTED
        @test !isready(ch)
        @test !has_component(gm, TileCoord(0, 0))
        @test logs == ["Invalid map edit: Fluid MONOPROP_GAS incompatible with constraint IS_LIQUID"]
        @test isempty(logger.logs)
    end
end

@testset "cancel_if_time_wrong! — time mismatch cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 10.0) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — within tolerance" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # 5.005 is within default tolerance of 0.01
    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.005) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint ahead" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # Waypoint at 10.0, target time at 5.0 → target not past waypoint
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 10.0) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint behind cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # Waypoint at 3.0, target time at 5.0 → target has passed waypoint
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 3.0) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — SpaceMapEmpty" begin
    gm = GameMap()  # default SpaceMapEmpty
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 5.0) == false
end

# ===============================================================
# Tests — update_manoeuvre_phase! (smoke tests)
# ===============================================================

@testset "update_manoeuvre_phase! — no manoeuvre is no-op" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()

    # Should not error when no manoeuvre is active
    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
end

@testset "update_manoeuvre_phase! — SpaceMapEmpty is no-op" begin
    gs = GameState()
    gm = GameMap()  # SpaceMapEmpty
    ipc = make_test_ipc()

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
end

@testset "update_manoeuvre_phase! — APPROACH_BURN respects preloaded burn state" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    # Add a dummy encounter point so the encounter index lookup succeeds
    ep = make_test_encounter_point(
        1;
        base_velocity = 100.0,
        position = SVector(500.0, 0.0),
        velocity = SVector(-100.0, 0.0),
    )
    push!(get_encounter_points(gm), ep)

    man = ManoeuvreData(
        approach_burn_dv = SVector(10.0, 0.0),
        capture_burn_dv = SVector(-10.0, 0.0),
        burn_target_dv = SVector(10.0, 0.0),
        burn_remaining_dv = SVector(10.0, 0.0),
        approach_burn_time = 0.0,
        intercept_time = 10.0,
        target_encounter_index = 1,
    )
    set_active_manoeuvre!(gm, man)

    set_time_years!(gm, 0.0)
    set_target_time!(gm, 0.0)  # target behind current → not progressing
    gs.thrust = SVector(0.0, 0.0)  # no thrust

    HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc)

    @test has_active_manoeuvre(gm)
    updated_man = get_active_manoeuvre(gm)
    @test updated_man.phase == PHASE_APPROACH_BURN
    @test updated_man.burn_remaining_dv ≈ SVector(10.0, 0.0)
    @test updated_man.burn_target_dv ≈ SVector(10.0, 0.0)
end

@testset "update_manoeuvre_phase! — COAST thrust replans the approach burn" begin
    logs, console = make_log_console()
    shared_state = FlowCalculatorSharedState(target_spacemap_time = 25.0)

    gs = GameState()
    gs.thrust = SVector(5.0, 0.0)

    gm = GameMap()
    ipc = make_test_ipc(shared_state = shared_state, console_push = console)
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    ep = make_test_encounter_point(
        1;
        base_velocity = 80.0,
        position = SVector(1000.0, 0.0),
        velocity = SVector(80.0, 0.0),
    )
    push!(get_encounter_points(gm), ep)

    player_pos_0 = SVector(0.0, 0.0)
    player_vel_0 = SVector(100.0, 0.0)
    initial_plan = plan_intercept_manoeuvre(player_pos_0, player_vel_0, ep, 0.0, 30.0)
    @test !isnothing(initial_plan)
    initial_plan = initial_plan::ManoeuvreData

    current_time, player_pos_mid, current_velocity = make_midcoast_state(
        player_pos_0,
        player_vel_0,
        initial_plan;
        velocity_offset = SVector(0.5, 0.0),
    )

    set_position!(gm, player_pos_mid)
    set_velocity!(gm, current_velocity)
    set_time_years!(gm, current_time)
    set_target_time!(gm, 25.0)

    initial_plan.phase = PHASE_COAST
    initial_plan.burn_target_dv = SVector(0.0, 0.0)
    initial_plan.burn_remaining_dv = SVector(0.0, 0.0)
    set_active_manoeuvre!(gm, initial_plan)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
    @test has_active_manoeuvre(gm)

    updated_man = get_active_manoeuvre(gm)
    @test updated_man.phase == PHASE_APPROACH_BURN
    @test updated_man.target_encounter_index == 1
    @test updated_man.approach_burn_time == current_time
    @test updated_man.intercept_time == initial_plan.intercept_time
    @test updated_man.burn_target_dv ≈ updated_man.burn_remaining_dv
    @test updated_man.approach_burn_dv ≈ SVector(-0.5, 0.0)
    @test updated_man.burn_target_dv ≈ SVector(0.5, 0.0)
    @test get_target_time(gm) == current_time
    @test (@atomic shared_state.target_spacemap_time) == current_time
    @test any(occursin("Manoeuvre recalculated", msg) for msg in logs)

    time_before = get_time_years(gm)
    @test !HexFlowProcGen.step_space_map_time!(gm.space_map, @atomic shared_state.target_spacemap_time)
    @test get_time_years(gm) == time_before
end

@testset "update_manoeuvre_phase! — COAST thrust with invalid target cancels" begin
    logs, console = make_log_console()
    shared_state = FlowCalculatorSharedState(target_spacemap_time = 8.0)

    gs = GameState()
    gs.thrust = SVector(5.0, 0.0)

    gm = GameMap()
    ipc = make_test_ipc(shared_state = shared_state, console_push = console)
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 3.0)
    set_target_time!(gm, 8.0)

    man = ManoeuvreData(
        phase = PHASE_COAST,
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(1.0, 0.0),
        target_encounter_index = 1,
    )
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
    @test !has_active_manoeuvre(gm)
    @test get_target_time(gm) == 3.0
    @test (@atomic shared_state.target_spacemap_time) == 3.0
    @test any(occursin("target encounter is no longer available", msg) for msg in logs)
end

@testset "update_manoeuvre_phase! — COAST reaches CAPTURE_BURN at intercept" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    push!(get_encounter_points(gm), make_test_encounter_point(
        1;
        base_velocity = 80.0,
        position = SVector(100.0, 0.0),
        velocity = SVector(80.0, 0.0),
    ))

    set_time_years!(gm, 5.0)
    set_target_time!(gm, 5.0)
    gs.thrust = SVector(0.0, 0.0)

    man = ManoeuvreData(
        phase = PHASE_COAST,
        approach_burn_dv = SVector(6.0, 0.0),
        capture_burn_dv = SVector(-3.0, 4.0),
        burn_target_dv = SVector(0.0, 0.0),
        burn_remaining_dv = SVector(0.0, 0.0),
        approach_burn_time = 0.0,
        intercept_time = 5.0,
        target_encounter_index = 1,
        capture_burn_position = SVector(0.0, 0.0),
    )
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
    @test has_active_manoeuvre(gm)

    updated_man = get_active_manoeuvre(gm)
    @test updated_man.phase == PHASE_CAPTURE_BURN
    @test updated_man.burn_target_dv ≈ SVector(5.0, 0.0)
    @test updated_man.burn_remaining_dv ≈ SVector(5.0, 0.0)
end

@testset "update_manoeuvre_phase! — ENCOUNTER_READY with thrust cancels" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
    )
    man.phase = PHASE_ENCOUNTER_READY
    set_active_manoeuvre!(gm, man)

    # Thrust above threshold → cancel
    gs.thrust = SVector(5.0, 0.0)
    HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc)

    @test !has_active_manoeuvre(gm)
end

@testset "update_manoeuvre_phase! — CAPTURE_BURN completion triggers encounter" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
    set_surface_tile!(gm, TileCoord(0, 0))
    push!(get_encounter_points(gm), make_trigger_test_encounter_point())
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
        target_encounter_index = 1,
    )
    man.phase = PHASE_CAPTURE_BURN
    man.burn_target_dv = SVector(0.0, 0.0)
    man.burn_remaining_dv = SVector(0.0, 0.0)
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing

    @test !has_active_manoeuvre(gm)

    # Encounter is now enqueued — drain the command queue to apply it
    while isready(ipc.command_queue.command_channel)
        cmd = take!(ipc.command_queue.command_channel)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = true)
    end
    @test any(ship_name -> ship_name != :primary, get_all_ship_names(gm))
end

@testset "update_manoeuvre_phase! — ENCOUNTER_READY triggers encounter even with future target time" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
    set_surface_tile!(gm, TileCoord(0, 0))
    push!(get_encounter_points(gm), make_trigger_test_encounter_point())
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 10.0)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
        target_encounter_index = 1,
    )
    man.phase = PHASE_ENCOUNTER_READY
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing

    @test !has_active_manoeuvre(gm)

    # Encounter is now enqueued — drain the command queue to apply it
    while isready(ipc.command_queue.command_channel)
        cmd = take!(ipc.command_queue.command_channel)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = true)
    end
    @test any(ship_name -> ship_name != :primary, get_all_ship_names(gm))
end

# ===============================================================
# Tests — replace_by_mutation!
# ===============================================================

@testset "replace_by_mutation!" begin
    src = GameMap()
    set_surface_tile!(src, TileCoord(5, 5))
    set_component!(src, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))

    dest = GameMap()
    @test !is_on_surface_tile(TileCoord(5, 5), dest)

    HexFlowCalculator.replace_by_mutation!(dest, src)

    # dest should now have src's data
    @test is_on_surface_tile(TileCoord(5, 5), dest)
    @test has_component(dest, TileCoord(0, 0))
end

# ===============================================================
# Tests — CommandStatus enum
# ===============================================================

@testset "CommandStatus enum" begin
    @test APPLIED isa CommandStatus
    @test REJECTED isa CommandStatus
    @test QUEUED_FAILED isa CommandStatus
    @test INVALID isa CommandStatus
end

# ===============================================================
# Tests — Manoeuvre constants
# ===============================================================

@testset "Manoeuvre constants" begin
    @test MANOEUVRE_THRUST_THRESHOLD > 0.0
    @test MANOEUVRE_COMPLETION_THRESHOLD > 0.0
    @test MANOEUVRE_THRUST_THRESHOLD == 0.1
    @test MANOEUVRE_COMPLETION_THRESHOLD == 0.05
end

@testset "PlaythroughStatistics persistence" begin
    old_layout = (
        components = Dict{TileCoord, PlacedComponent}(),
        pipe_behaviors = Dict{PipeCoord, PlacedPipe}(),
        surface_shiptags = Dict{TileCoord, Symbol}(),
        ships = Dict{Symbol, ShipState}(),
        space_map = SpaceMapEmpty(),
        learning_system = NoLearningSystem(),
    )
    old_map = rconvert(FlowMap.GameMap, old_layout)
    @test get_recorded_play_time_seconds(old_map) == 0.0
    @test get_simulated_ticks(old_map) == 0
    @test get_total_delta_v(old_map) == 0.0
    @test get_peak_thrust(old_map) == 0.0
    @test get_peak_estimated_delta_v(old_map) == 0.0
    @test isempty(get_playthrough_statistics(old_map).completed_encounters)

    partial_statistics = rconvert(FlowMap.PlaythroughStatistics, (total_delta_v = 2.5, peak_estimated_delta_v = 1700.0))
    @test get_recorded_play_time_seconds(partial_statistics) == 0.0
    @test get_total_delta_v(partial_statistics) == 2.5
    @test get_peak_estimated_delta_v(partial_statistics) == 1700.0
    @test get_simulated_ticks(partial_statistics) == 0
    @test typeof(partial_statistics.completed_encounters) == Dict{EncounterClass, Int64}
    for invalid_peak in (-1.0, Inf, NaN)
        @test_throws ArgumentError rconvert(
            FlowMap.PlaythroughStatistics,
            (peak_estimated_delta_v = invalid_peak,),
        )
    end

    typemap = _build_map_typemap()
    @test haskey(typemap, "FlowMap.PlaythroughStatistics")
    @test haskey(typemap, "FlowMap.GalaxyEscapeSpaceMap")

    gamemap = GameMap()
    set_recorded_play_time_seconds!(gamemap, 12.0)
    for _ in 1:4
        increment_simulated_ticks!(gamemap)
    end
    record_delta_v!(gamemap, 3.5)
    record_peak_thrust!(gamemap, 8.0)
    record_peak_estimated_delta_v!(gamemap, 1900.0)
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    record_completed_encounter!(gamemap, ENCOUNTER_FUEL_CACHE)

    mktempdir() do directory
        path = joinpath(directory, "statistics.jld2")
        savemap(gamemap, path)
        loaded_map = loadmap(path)

        @test get_recorded_play_time_seconds(loaded_map) == 12.0
        @test get_simulated_ticks(loaded_map) == 4
        @test get_total_delta_v(loaded_map) == 3.5
        @test get_peak_thrust(loaded_map) == 8.0
        @test get_peak_estimated_delta_v(loaded_map) == 1900.0
        @test get_encounter_count(loaded_map, ENCOUNTER_SHIP) == 1
        @test get_encounter_count(loaded_map, ENCOUNTER_FUEL_CACHE) == 1
        @test get_total_encounter_count(loaded_map) == 2
        @test typeof(loaded_map.statistics.completed_encounters) == Dict{EncounterClass, Int64}
    end
end


@testset "GalaxyEscapeSpaceMap persistence" begin
    pre_escape_map = make_galaxy_escape_ready_map(velocity = SVector(100.0, -8.0), time_years = 42.0)
    escape_map = GalaxyEscapeSpaceMap(
        velocity = SVector(175.0, -8.0),
        starting_velocity_x = 100.0,
        departure_time_years = 42.0,
        pre_escape_map = pre_escape_map,
    )
    gamemap = GameMap(space_map = escape_map)
    record_peak_estimated_delta_v!(gamemap, 2100.0)

    reconstructed = rconvert(FlowMap.GalaxyEscapeSpaceMap, (
        velocity = SVector(130.0, 2.0),
        starting_velocity_x = 100.0,
        departure_time_years = 7.0,
    ))
    @test reconstructed == GalaxyEscapeSpaceMap(
        velocity = SVector(130.0, 2.0), starting_velocity_x = 100.0, departure_time_years = 7.0,
        pre_escape_map = GameMap(),
    )
    @test !can_abort_galaxy_escape(reconstructed)
    @test_throws ErrorException rconvert(FlowMap.GalaxyEscapeSpaceMap, (
        starting_velocity_x = 100.0, departure_time_years = 7.0,
    ))
    @test_throws ArgumentError rconvert(FlowMap.GalaxyEscapeSpaceMap, (
        velocity = SVector(Inf, 0.0), starting_velocity_x = 100.0, departure_time_years = 7.0,
    ))
    @test_throws ArgumentError rconvert(FlowMap.GalaxyEscapeSpaceMap, (
        velocity = SVector(130.0, 0.0), starting_velocity_x = 100.0, departure_time_years = -1.0,
    ))

    mktempdir() do directory
        path = joinpath(directory, "galaxy_escape.jld2")
        savemap(gamemap, path)
        loaded_map = loadmap(path)

        @test loaded_map.space_map isa GalaxyEscapeSpaceMap
        loaded_escape = loaded_map.space_map::GalaxyEscapeSpaceMap
        @test loaded_escape.velocity == escape_map.velocity
        @test loaded_escape.starting_velocity_x == escape_map.starting_velocity_x
        @test loaded_escape.departure_time_years == escape_map.departure_time_years
        @test loaded_escape.pre_escape_map !== pre_escape_map
        loaded_pre_escape_space_map = loaded_escape.pre_escape_map.space_map::SpaceMapState
        original_pre_escape_space_map = pre_escape_map.space_map::SpaceMapState
        @test loaded_pre_escape_space_map.seed == original_pre_escape_space_map.seed
        @test loaded_pre_escape_space_map.velocity == original_pre_escape_space_map.velocity
        @test loaded_pre_escape_space_map.time_years == original_pre_escape_space_map.time_years
        @test loaded_escape.pre_escape_map.statistics == pre_escape_map.statistics
        @test can_abort_galaxy_escape(loaded_map)
        @test galaxy_escape_progress(loaded_escape) == 75.0
        @test get_peak_estimated_delta_v(loaded_map) == 2100.0
        @test isempty(get_encounter_points(loaded_escape))
        @test !has_active_manoeuvre(loaded_escape)
    end
end

@testset "render-thread time-lapse persistence" begin
    gamemap = GameMap()
    first_frame = GameMap()
    second_frame = GameMap()
    increment_simulated_ticks!(first_frame)
    for _ in 1:2
        increment_simulated_ticks!(second_frame)
    end
    history = TimelapseHistory(frames = [first_frame, second_frame])

    mktempdir() do directory
        map_only_path = joinpath(directory, "map_only.jld2")
        savemap(gamemap, map_only_path)
        map_only = loadmap_bundle(map_only_path)
        @test map_only.gamemap isa GameMap
        @test isnothing(map_only.timelapse)
        @test !JLD2.jldopen(map_only_path, "r") do file
            haskey(file, "stored_timelapse")
        end
        @test loadmap(map_only_path) isa GameMap

        bundled_path = joinpath(directory, "bundled.jld2")
        savemap(GameMapBundle(gamemap, history), bundled_path)
        bundled = loadmap_bundle(bundled_path)
        @test bundled.gamemap isa GameMap
        @test bundled.timelapse isa TimelapseHistory
        loaded_history = bundled.timelapse::TimelapseHistory
        @test loaded_history.format_version == TIMELAPSE_FORMAT_VERSION
        @test length(loaded_history.frames) == 2
        @test get_simulated_ticks(loaded_history.frames[1]) == 1
        @test get_simulated_ticks(loaded_history.frames[2]) == 2

        bundled_source = loadmap_bundle_from_source(bundled_path)
        @test bundled_source.timelapse isa TimelapseHistory
        @test length(bundled_source.timelapse.frames) == 2

        direct_source = loadmap_bundle_from_source(gamemap)
        @test direct_source.gamemap === gamemap
        @test isnothing(direct_source.timelapse)

        empty_path = joinpath(directory, "empty_history.jld2")
        savemap(GameMapBundle(gamemap, TimelapseHistory()), empty_path)
        empty_bundle = loadmap_bundle(empty_path)
        @test empty_bundle.timelapse isa TimelapseHistory
        @test isempty(empty_bundle.timelapse.frames)

        malformed_path = joinpath(directory, "malformed_history.jld2")
        JLD2.jldsave(malformed_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        malformed_bundle = @test_logs (:warn, r"invalid type") loadmap_bundle(malformed_path)
        @test malformed_bundle.gamemap isa GameMap
        @test isnothing(malformed_bundle.timelapse)

        unsupported_path = joinpath(directory, "unsupported_history.jld2")
        unsupported = TimelapseHistory(format_version = UInt16(1))
        JLD2.jldsave(unsupported_path; stored_gamemap = gamemap, stored_timelapse = unsupported)
        unsupported_bundle = @test_logs (:warn, r"unsupported format version") loadmap_bundle(unsupported_path)
        @test unsupported_bundle.gamemap isa GameMap
        @test isnothing(unsupported_bundle.timelapse)

        @test_throws ArgumentError savemap(GameMapBundle(gamemap, unsupported), joinpath(directory, "unsupported_save.jld2"))
    end
end
