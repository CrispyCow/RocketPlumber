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

include(joinpath(@__DIR__, "..", "..", "..", "src", "map_loading.jl"))

"Minimal encounter config for tests that only need a SpaceMapState."
const _test_enc_config = EncounterSystemConfig()

"Minimal encounter config for tests that need a valid generated encounter ship."
function make_trigger_test_encounter_config()
    class_config = EncounterClassConfig(
        NoScaling(1.0),
        HullSizeConfig(LinearScaling(2.0, 0.0), LinearScaling(2.0, 0.0)),
        LinearScaling(0.0, 0.0),
        Dict{FluidType, FuelTagConfig}(
            HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), WeightedComponentSet[]),
        ),
        PipeSpawnOptions[],
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
    return (ActionInfo(:flip, "Flip", true, "Flip state"),)
end
function do_action!(comp::ActionCompBehav, action_id::Symbol; kwargs...)
    if action_id === :flip
        action_count[] += 1
        return (true, "Flipped")
    end
    return (false, "Unknown action")
end
function placement_valid(comp::ActionCompBehav, coord::TileCoord, gamemap::GameMap; kwargs...)
    return (true, "")
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
        return (false, "Not on ship surface")
    end
    if rotation ∉ comp.valid_rotations
        return (false, "Rotation invalid")
    end
    return (true, "")
end

struct MirrorableCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MirrorableCompBehav) = ()
HexComponentsAPI.get_tunables(::MirrorableCompBehav) = ()
HexComponentsAPI.set_tunables(::MirrorableCompBehav, ::NTuple{0, Real}) = MirrorableCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MirrorableCompBehav; kwargs...) = nothing
HexComponentsAPI.map_mirroring(::MirrorableCompBehav, mirrored::Bool) = mirrored
function placement_valid(::MirrorableCompBehav, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...)
    return is_on_surface_tile(coord, gamemap; ship_name = ship_name) ? (true, "") : (false, "Not on ship surface")
end

struct MirroringRequiredCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MirroringRequiredCompBehav) = ()
HexComponentsAPI.get_tunables(::MirroringRequiredCompBehav) = ()
HexComponentsAPI.set_tunables(::MirroringRequiredCompBehav, ::NTuple{0, Real}) = MirroringRequiredCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MirroringRequiredCompBehav; kwargs...) = nothing
HexComponentsAPI.map_mirroring(::MirroringRequiredCompBehav, mirrored::Bool) = mirrored
function placement_valid(::MirroringRequiredCompBehav, coord::TileCoord, gamemap::GameMap;
        mirrored::Bool = false, ship_name::Symbol = :primary, kwargs...)
    is_on_surface_tile(coord, gamemap; ship_name = ship_name) || return (false, "Not on ship surface")
    mirrored || return (false, "Mirroring required")
    return (true, "")
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
            @test any(contains(l, "crosses an occupied tile") for l in logs)
        end
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
        @test any(contains(l, "rotated in place") for l in logs)
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

    @testset "MoveCommand{TileCoord} — reports occupier ship in collision log" begin
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

        @test any(contains(l, "occupied on asteroid") for l in logs)
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
        @test any(contains(l, "Pipe moved") for l in logs)
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
            @test any(contains(l, "crosses an occupied tile") for l in logs)
        end
    end

    #= ---------- DeleteAtCommand{TileCoord} ----------- =#
    @testset "DeleteAtCommand{TileCoord}" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 0)

        # Place then delete
        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS),
            gamemap
        )
        @test !isnothing(get_component(gamemap, coord))

        cmd = create_delete_command(cq, coord)
        @test cmd isa DeleteAtCommand{TileCoord}

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_component(gamemap, coord))
        @test any(contains(l, "deleted") || contains(l, "Deleted") for l in logs)
        @test any(contains(l, "from primary") for l in logs)
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

        # perform action (sanbox validation + real apply will call the action twice)
        cmd = create_do_action_command(cq, coord, :flip)
        logs = process_and_log!(cmd, gamemap)
        @test action_count[] == 2
        @test !isempty(logs)  # at least some message logged

        # action on nonexistent component should log error and do nothing
        gamemap2 = GameMap()
        logs2 = process_and_log!(create_do_action_command(cq, TileCoord(5, 5), :flip), gamemap2)
        @test any(contains(l, "No component") for l in logs2)
    end

    @testset "DeleteAtCommand{TileCoord} — missing component" begin
        gamemap = GameMap()
        logs = process_and_log!(
            create_delete_command(cq, TileCoord(0, 0)),
            gamemap
        )

        @test any(contains(l, "No component") for l in logs)
    end

    #= ---------- DeleteAtCommand{PipeCoord} ----------- =#
    @testset "DeleteAtCommand{PipeCoord}" begin
        gamemap = make_two_ship_map()
        pipe = side_pipe(TileCoord(20, 0), 1)

        # Place then delete
        process_and_log!(
            create_set_pipe_behavior_command(cq, pipe, MockPipeBehav()),
            gamemap
        )
        @test !isnothing(get_pipe(gamemap, pipe))

        cmd = create_delete_command(cq, pipe)
        @test cmd isa DeleteAtCommand{PipeCoord}

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_pipe(gamemap, pipe))
        @test any(contains(l, "deleted") || contains(l, "Deleted") for l in logs)
        @test any(contains(l, "from asteroid") for l in logs)
    end

    @testset "DeleteAtCommand{PipeCoord} — missing pipe" begin
        gamemap = GameMap()
        pipe = side_pipe(TileCoord(0, 0), 1)

        logs = process_and_log!(
            create_delete_command(cq, pipe),
            gamemap
        )

        @test any(contains(l, "No pipe") for l in logs)
    end

    #= ---------- DeleteAtCommand — type parameter correctness ----------- =#
    @testset "DeleteAtCommand type parameter" begin
        cmd_tile = create_delete_command(cq, TileCoord(0, 0))
        cmd_pipe = create_delete_command(cq, side_pipe(TileCoord(0, 0), 1))

        @test cmd_tile isa DeleteAtCommand{TileCoord}
        @test cmd_pipe isa DeleteAtCommand{PipeCoord}

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
        @test !any(contains(l, "error") || contains(l, "Error") for l in logs)
        @test any(contains(l, "on asteroid") for l in logs)
    end

    @testset "ClickTileCommand — missing component" begin
        gamemap = GameMap()

        logs = process_and_log!(
            create_click_tile_command(cq, TileCoord(5, 5), CartesianCoord(0.0, 0.0)),
            gamemap
        )

        @test any(contains(l, "No component") || contains(l, "no") for l in logs)
    end

    #= ---------- AddShipSurfaceCommand ----------- =#
    @testset "AddShipSurfaceCommand" begin
        gamemap = make_gamemap()
        coord = TileCoord(0, 1)  # adjacent to default (0,0) surface

        cmd = create_add_ship_surface_command(cq, coord)
        logs = process_and_log!(cmd, gamemap)

        @test is_on_surface_tile(coord, gamemap; ship_name = :primary)
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
    end

    #= ---------- MapOverrideCommand ----------- =#
    @testset "MapOverrideCommand" begin
        gamemap = GameMap()
        new_map = make_two_ship_map()

        cmd = create_map_override_command(cq, new_map)
        process_and_log!(cmd, gamemap)

        # After override, gamemap should have the :asteroid ship
        @test haskey(gamemap.ships, :asteroid)
        @test count_surface_tiles(gamemap) == count_surface_tiles(new_map)
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
            create_delete_command(cq, TileCoord(2, 0)),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(2, 0)))
    end

    #= ---------- Command ID Generation ----------- =#
    @testset "Command IDs are sequential" begin
        c1 = create_delete_command(cq, TileCoord(0, 0))
        c2 = create_delete_command(cq, TileCoord(0, 0))
        c3 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

        @test c2.id == c1.id + 1
        @test c3.id == c2.id + 1
    end
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
    cmd = create_delete_command(cq, TileCoord(0, 0))

    success, status = try_enqueue_command!(cq, cmd, silent_console)
    @test success == true
    @test status == APPLIED
end

@testset "CommandQueue — last_command tracking" begin
    cq = create_command_queue(4)
    cmd1 = create_delete_command(cq, TileCoord(0, 0))
    cmd2 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

    try_enqueue_command!(cq, cmd1, silent_console)
    @test cq.last_command === cmd1

    try_enqueue_command!(cq, cmd2, silent_console)
    @test cq.last_command === cmd2
end

# ===============================================================
# Tests — scale_voltage_dict!
# ===============================================================

@testset "scale_voltage_dict! — empty" begin
    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict{NodeCoord, Float64}())
    @test isempty(out)
end

@testset "scale_voltage_dict! — single entry" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict(nc => 10.0))
    @test haskey(out, nc)
    @test out[nc] <= 1.0 + 1.0e-10  # scaled to at most 1.0
    @test out[nc] > 0.0
end

@testset "scale_voltage_dict! — relative ordering preserved" begin
    nc1 = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    nc2 = NodeCoord(TileCoord(1, 0), HexFrame.NODE_Q_POS)

    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict(nc1 => 100.0, nc2 => 50.0))
    @test out[nc1] > out[nc2]  # higher voltage → higher scaled value
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
        process_and_log!(cmd, gm)
        @test collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid) == original_tiles
    end

    @testset "rejects placement when pipe clearance overlaps another ship" begin
        gm = make_gamemap()
        add_ship!(gm, :asteroid, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, TileCoord(10, 0); ship_name = :asteroid)
        set_pipe!(gm, side_pipe(TileCoord(15, 0)), MockPipeBehav(); ship_name = :asteroid)

        cmd = create_redock_ship_command(cq, :asteroid, TileCoord(-15, 0))
        original_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid)
        process_and_log!(cmd, gm)

        @test collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :asteroid) == original_tiles
    end

    @testset "rejects redock of nonexistent ship" begin
        gm = GameMap()
        delta = TileCoord(1, 0)
        cmd = create_redock_ship_command(cq, :nonexistent, delta)
        @test_throws Exception process_and_log!(cmd, gm)
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
        @test any(contains(log, "Encounter triggered: live_encounter") for log in logs)
        @test !any(contains(log, "Invalid map edit") for log in logs)
    end
end

@testset "process_command! rejects invalid fluid bridge placements" begin
    gm = GameMap()
    set_surface_tile!(gm, TileCoord(0, 0))

    cq = create_command_queue(4)
    cmd = create_set_tile_command(cq, TileCoord(0, 0), InvalidFluidBridgeCompBehav(), Q_POS)
    logs, console = make_log_console()

    @test_throws Exception HexFlowCalculator.process_command!(cmd, gm, console, throw_errors = true)
    @test !has_component(gm, TileCoord(0, 0))
    @test any(contains(log, "Invalid map edit") for log in logs)
    @test any(contains(log, "incompatible with constraint") for log in logs)
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

    @testset "writes INVALID for unrecognised action" begin
        gm = make_gamemap()
        set_component!(gm, TileCoord(0, 0),
            PlacedComponent(ActionCompBehav(), Q_POS, false, :primary))

        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)
        cmd = create_do_action_command(cq, TileCoord(0, 0), :no_such_action;
            response_channel = ch)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = false)

        @test take!(ch) == INVALID
    end

    @testset "writes REJECTED on sandbox failure" begin
        gm = GameMap()
        set_surface_tile!(gm, TileCoord(0, 0))
        cq = create_command_queue(4)
        ch = Channel{CommandStatus}(1)

        cmd = create_set_tile_command(cq, TileCoord(0, 0), InvalidFluidBridgeCompBehav(), Q_POS; response_channel = ch)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = false)

        @test take!(ch) == REJECTED
        @test !has_component(gm, TileCoord(0, 0))
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
