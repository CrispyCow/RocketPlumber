#=
Scope: Application map-source dispatch and runtime time-lapse recording tests
Formatter: Runic
=#

using Test
ENV["JULIA_GLFW_PLATFORM"] = "null"
using RocketPlumber
using FlowMap: GameMap, ShipState, set_surface_tile!
using HexFrame: TileCoord, VertexCoord, Q_POS
using HexFlowCalculator: FlowCalculatorSnapshot, ConsoleMessage
using HexFlowControl: InputState, PlacementReadyState, PlacementPipeChainState,
    PlacementDeleteState, PlacementTileState, PlacementSurfaceEditState,
    placement_state, set_placement_state!, editor_capabilities_enabled
using HexFlowBasicPipes: BigPipeBehav, ScrapPipeBehav
using HexFlowRendering: SpriteRenderCommand
using RenderEngine: GLObjectMap, GLspriteData
using StaticArrays: SVector
import RenderEngine
using HexFlowPersistence: TimelapseHistory, GameMapBundle, savemap
using RocketPlumber: TimelapseRecorder, timelapse_frame_count, capture_timelapse_frame!,
    set_timelapse_enabled!, maybe_capture_timelapse!, snapshot_timelapse_history

include(joinpath(@__DIR__, "smoke", "SmokeTestSupport.jl"))

@testset "Console notifications" begin
    ipc = RocketPlumber.setup_flowcalc_ipc(FlowCalculatorSnapshot())
    winsize = (width = Int32(800), height = Int32(600))
    @test isnothing(ipc.console_see())
    @test isnothing(RocketPlumber.ui_notifications_render!(winsize, ipc.console_see))

    # Existing IPC producers need only supply the message text
    ipc.console_push("hello")
    @test ipc.console_see().text == "hello"
    ipc.console_push("latest")
    @test ipc.console_see().text == "latest"

    # Expired notifications return before any CImGui calls, even without a UI context
    expired = ConsoleMessage("expired", Float64(time_ns()) / 1.0e9 - RocketPlumber.NOTIFICATION_DURATION)
    @test isnothing(RocketPlumber.ui_notifications_render!(winsize, () -> expired))
end

@testset "Launch and smoke arguments" begin
    @test RocketPlumber.parse_launch_args(String[]) == (telemetry = false,)
    @test RocketPlumber.parse_launch_args(["--telemetry"]) == (telemetry = true,)
    @test_throws ArgumentError RocketPlumber.parse_launch_args(["--unknown"])
    @test_throws ArgumentError RocketPlumber.parse_launch_args(["--duration", "60"])

    @test SmokeTestSupport.parse_smoke_args(String[]) == (telemetry = false, duration = 20.0)
    @test SmokeTestSupport.parse_smoke_args(["--telemetry", "--duration", "60"]) == (telemetry = true, duration = 60.0)
    @test SmokeTestSupport.parse_smoke_args(["--duration", "21.5", "--telemetry"]) == (telemetry = true, duration = 21.5)
    @test SmokeTestSupport.smoke_exit_tick(20.0) == 1200
    @test SmokeTestSupport.smoke_exit_tick(60.0) == 3600
    @test SmokeTestSupport.smoke_exit_tick(20.01) == 1201
    for args in (["--duration"], ["--duration", "bad"], ["--duration", "19.9"], ["--duration", "NaN"], ["--duration", "Inf"], ["--unknown"])
        @test_throws ArgumentError SmokeTestSupport.parse_smoke_args(args)
    end
end

@testset "Editor Mode transitions" begin
    inputstate = InputState()
    @test !editor_capabilities_enabled(inputstate)

    # Exercise the same state changes used by the shortcut and checkbox.
    RocketPlumber.set_editor_mode!(inputstate, !inputstate.editor_mode)
    @test editor_capabilities_enabled(inputstate)
    RocketPlumber.set_editor_mode!(inputstate, false)
    @test !editor_capabilities_enabled(inputstate)

    RocketPlumber.set_editor_mode!(inputstate, true)
    @test editor_capabilities_enabled(inputstate)
    RocketPlumber.set_editor_mode!(inputstate, !inputstate.editor_mode)
    @test !editor_capabilities_enabled(inputstate)

    for editor_state in (PlacementDeleteState(), RocketPlumber.new_tile_placement_state(), PlacementSurfaceEditState())
        RocketPlumber.set_editor_mode!(inputstate, true)
        set_placement_state!(inputstate, editor_state)
        RocketPlumber.set_editor_mode!(inputstate, false)
        @test placement_state(inputstate) isa PlacementReadyState
    end

    pipe_state = PlacementPipeChainState(
        source_node = VertexCoord(TileCoord(0, 0), Q_POS),
        pipe_behavior = BigPipeBehav(),
    )
    RocketPlumber.set_editor_mode!(inputstate, true)
    set_placement_state!(inputstate, pipe_state)
    RocketPlumber.set_editor_mode!(inputstate, false)
    @test placement_state(inputstate) === pipe_state
    @test pipe_state.pipe_behavior isa ScrapPipeBehav
end

@testset "application map-source dispatch" begin
    gamemap = GameMap()
    @test RocketPlumber.loadmap_from_source(gamemap) === gamemap
    @test RocketPlumber.loadmap_bundle_from_source(gamemap).gamemap === gamemap
    @test isnothing(RocketPlumber.loadmap_bundle_from_source(gamemap).timelapse)

    ship_map = RocketPlumber.loadmap_from_source(ShipState())
    @test ship_map isa GameMap
    @test RocketPlumber.loadmap_bundle_from_source(ShipState()).gamemap isa GameMap
    @test RocketPlumber.loadmap_from_source(nothing) isa GameMap
    @test RocketPlumber.loadmap_bundle_from_source(nothing).gamemap isa GameMap

    mktempdir() do directory
        path = joinpath(directory, "source_bundle.jld2")
        history = TimelapseHistory(frames = [gamemap])
        savemap(GameMapBundle(gamemap, history), path)

        @test RocketPlumber.loadmap_from_source(path) isa GameMap
        bundle = RocketPlumber.loadmap_bundle_from_source(path)
        @test bundle.gamemap isa GameMap
        @test bundle.timelapse isa TimelapseHistory
        @test length(bundle.timelapse.frames) == 1
    end
end

@testset "world render queue population" begin
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0))
    snapshot = FlowCalculatorSnapshot(gamemap = gamemap)
    inputstate = InputState()
    renderqueue = SpriteRenderCommand[]

    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(256), UInt(256))
    glmap.sprites[:ShipSurface_basic] = GLspriteData(
        :TestAtlas,
        SVector{2, Float32}(0.1f0, 0.1f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
    )

    RocketPlumber.populate_renderqueue!(renderqueue, glmap, snapshot, inputstate)
    @test !isempty(renderqueue)
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
