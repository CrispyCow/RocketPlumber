#=
Scope: Application map-source dispatch and runtime time-lapse recording tests
Formatter: Runic
=#

using Test
ENV["JULIA_GLFW_PLATFORM"] = "null"
using RocketPlumber
using FlowMap: GameMap, ShipState
using HexFlowPersistence: TimelapseHistory, GameMapBundle, savemap
using RocketPlumber: TimelapseRecorder, timelapse_frame_count, capture_timelapse_frame!,
    set_timelapse_enabled!, maybe_capture_timelapse!, snapshot_timelapse_history

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
