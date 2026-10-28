#=
Scope: Time-lapse recording, snapshot ownership, and associated saves
Formatter: Runic
=#

using RocketPlumber: TimelapseRecorder, timelapse_frame_count, capture_timelapse_frame!,
    set_timelapse_enabled!, maybe_capture_timelapse!, snapshot_timelapse_history

@testset "render-thread time-lapse recorder" begin
    gamemap = GameMap()
    snapshot = (gamemap = gamemap, timestamp = 1.0)

    recorder = TimelapseRecorder(; now = 0.0)
    @test recorder.enabled
    @test recorder.capture_interval_seconds == 60.0
    @test recorder.next_capture_time_seconds == 60.0
    @test isnothing(recorder.history)
    @test timelapse_frame_count(recorder) == 0
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 59.0)
    @test isnothing(recorder.history)

    loaded_history = TimelapseHistory(frames = [GameMap()])
    loaded_recorder = TimelapseRecorder(loaded_history; now = 10.0)
    @test loaded_recorder.enabled
    @test loaded_recorder.capture_interval_seconds == 60.0
    @test loaded_recorder.next_capture_time_seconds == 70.0
    @test loaded_recorder.history === loaded_history
    set_timelapse_enabled!(loaded_recorder, false; now = 20.0)
    @test !capture_timelapse_frame!(loaded_recorder, GameMap())
    @test loaded_recorder.history === loaded_history
    @test timelapse_frame_count(loaded_recorder) == 1

    @test maybe_capture_timelapse!(recorder, snapshot; now = 60.0)
    @test timelapse_frame_count(recorder) == 1
    @test only(recorder.history.frames) !== gamemap
    @test only(recorder.history.frames) == gamemap
    @test recorder.next_capture_time_seconds == 120.0

    changed_snapshot = (gamemap = GameMap(), timestamp = 2.0)
    recorder.capture_interval_seconds = 10.0
    @test recorder.next_capture_time_seconds == 120.0
    @test !maybe_capture_timelapse!(recorder, changed_snapshot; now = 119.0)
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 120.0)
    @test maybe_capture_timelapse!(recorder, changed_snapshot; now = 121.0)
    @test timelapse_frame_count(recorder) == 2
    @test recorder.next_capture_time_seconds == 131.0

    suppressed_snapshot = (gamemap = GameMap(), timestamp = 3.0)
    @test !maybe_capture_timelapse!(recorder, suppressed_snapshot; capture_suppressed = true, now = 160.0)
    @test recorder.next_capture_time_seconds == 131.0
    @test maybe_capture_timelapse!(recorder, suppressed_snapshot; now = 161.0)
    @test timelapse_frame_count(recorder) == 3

    before_disable = snapshot_timelapse_history(recorder)::TimelapseHistory
    @test before_disable.frames !== recorder.history.frames
    @test before_disable.frames[1] === recorder.history.frames[1]
    @test capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 4.0)
    set_timelapse_enabled!(recorder, false; now = 170.0)
    @test !recorder.enabled
    @test !capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 5.0)
    @test !maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 5.0); now = 200.0)
    @test timelapse_frame_count(recorder) == 4

    set_timelapse_enabled!(recorder, true; now = 200.0)
    @test recorder.enabled
    @test recorder.next_capture_time_seconds == 200.0
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
    @test !capture_timelapse_frame!(recorder, timestampless_map)
    @test recorder.last_captured_snapshot_timestamp === nothing
    @test maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 8.0); now = 300.0)
end

@testset "time-lapse frames own nested mutable state" begin
    gamemap = GameMap(learning_system = LearningProgress([:test]))
    set_surface_tile!(gamemap, TileCoord(1, 0))
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
    publish_snap, get_snap = create_snapshot_storage(FlowCalculatorSnapshot())

    publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), 1.0)
    snapshot = get_snap()
    @test capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    first_frame = only(recorder.history.frames)
    @test first_frame.surface_shiptags == gamemap.surface_shiptags
    @test first_frame.statistics == gamemap.statistics
    @test first_frame !== snapshot.gamemap
    @test first_frame.learning_system.tutorials[:test] !== snapshot.gamemap.learning_system.tutorials[:test]
    @test first_frame.statistics.completed_encounters !== snapshot.gamemap.statistics.completed_encounters

    # Capture another published buffer, then cycle through every slot repeatedly
    gamemap.learning_system.tutorials[:test].unlocked_step = 3
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    delete_surface_tile!(gamemap, TileCoord(1, 0))
    publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), 2.0)
    snapshot = get_snap()
    @test capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    second_frame = last(recorder.history.frames)
    @test second_frame.surface_shiptags == gamemap.surface_shiptags
    @test second_frame.statistics == gamemap.statistics
    @test second_frame !== snapshot.gamemap

    empty!(gamemap.learning_system.tutorials)
    empty!(gamemap.statistics.completed_encounters)
    for timestamp in 3.0:8.0
        publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), timestamp)
        get_snap()
    end
    @test first_frame.learning_system.tutorials[:test].unlocked_step == 1
    @test get_encounter_count(first_frame, ENCOUNTER_SHIP) == 1
    @test is_on_surface_tile(TileCoord(1, 0), first_frame)
    @test second_frame.learning_system.tutorials[:test].unlocked_step == 3
    @test get_encounter_count(second_frame, ENCOUNTER_SHIP) == 2
    @test !is_on_surface_tile(TileCoord(1, 0), second_frame)
end

# A skipped capture must never attempt to copy the source map
mutable struct UncopyableTimelapseLearningState <: AbstractLearningSystem end
Base.deepcopy_internal(::UncopyableTimelapseLearningState, ::IdDict) = error("Unexpected time-lapse copy")

@testset "skipped time-lapse captures avoid copying" begin
    gamemap = GameMap(learning_system = UncopyableTimelapseLearningState())
    @test_throws ErrorException deepcopy(gamemap)
    snapshot = (gamemap = gamemap, timestamp = 1.0)
    recorder = TimelapseRecorder(nothing; now = 0.0)
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    set_timelapse_enabled!(recorder, false; now = 0.0)
    @test !capture_timelapse_frame!(recorder, gamemap)
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    @test isnothing(recorder.history)

    set_timelapse_enabled!(recorder, true; now = 0.0)
    @test !maybe_capture_timelapse!(recorder, snapshot; capture_suppressed = true, now = 0.0)
    @test timelapse_frame_count(recorder) == 0

    gamemap.learning_system = NoLearningSystem()
    @test maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    gamemap.learning_system = UncopyableTimelapseLearningState()
    @test !maybe_capture_timelapse!(recorder, (gamemap = gamemap, timestamp = 2.0); now = 59.0)
    @test !capture_timelapse_frame!(recorder, gamemap; snapshot_timestamp = 1.0)
    @test !capture_timelapse_frame!(recorder, GameMap(learning_system = UncopyableTimelapseLearningState()); snapshot_timestamp = 1.0)
    @test !capture_timelapse_frame!(recorder, gamemap)
    @test timelapse_frame_count(recorder) == 1
    @test recorder.next_capture_time_seconds == 60.0
end

@testset "time-lapse source identity without timestamps" begin
    gamemap = GameMap()
    history = TimelapseHistory(frames = [gamemap])
    recorder = TimelapseRecorder(history; now = 0.0)
    @test !capture_timelapse_frame!(recorder, gamemap)

    other_map = deepcopy(gamemap)
    @test capture_timelapse_frame!(recorder, other_map)
    increment_simulated_ticks!(other_map)
    @test !capture_timelapse_frame!(recorder, other_map)
    @test get_simulated_ticks(last(history.frames)) == 0
    @test capture_timelapse_frame!(recorder, gamemap)
    @test timelapse_frame_count(recorder) == 3
end

@testset "manual and pre-escape saves retain owned time-lapse frames" begin
    mktempdir() do directory
        gamemap = GameMap()
        recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
        snapshot = FlowCalculatorSnapshot(gamemap = gamemap, timestamp = 1.0)
        save_path = joinpath(directory, "manual.jld2")
        timing = PlaySessionTiming(0.0)
        RocketPlumber.save_current_map(recorder, snapshot, timing, nothing, save_path)
        @test only(recorder.history.frames) !== gamemap
        increment_simulated_ticks!(gamemap)
        @test get_simulated_ticks(only(recorder.history.frames)) == 0
        @test get_simulated_ticks(only(loadmap_bundle(save_path).timelapse.frames)) == 0

        pre_escape_map = deepcopy(gamemap)
        escape_map = GameMap(
            space_map = GalaxyEscapeSpaceMap(
                velocity = SVector(10.0, 0.0), starting_velocity_x = 10.0,
                departure_time_years = 0.0, pre_escape_map = pre_escape_map,
            )
        )
        escape_save_path = joinpath(directory, "pre_escape.jld2")
        RocketPlumber.save_pre_escape_map(recorder, escape_map, escape_save_path)
        RocketPlumber.save_pre_escape_map(recorder, escape_map, escape_save_path)
        @test timelapse_frame_count(recorder) == 2
        @test last(recorder.history.frames) !== pre_escape_map
        increment_simulated_ticks!(escape_map)
        @test get_simulated_ticks(pre_escape_map) == 1
        @test get_simulated_ticks(last(recorder.history.frames)) == 1
        saved_bundle = loadmap_bundle(escape_save_path)
        @test get_simulated_ticks(saved_bundle.gamemap) == 1
        @test get_simulated_ticks.(saved_bundle.timelapse.frames) == [0, 1]
    end
end

@testset "paired escape saves" begin
    mktempdir() do directory
        checkpoint = GameMap()
        increment_simulated_ticks!(checkpoint)
        escape_map = GameMap(space_map = GalaxyEscapeSpaceMap(SVector(10.0, 0.0), 10.0, 0.0, checkpoint))
        recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
        state = RocketPlumber.EscapeSaveState()
        messages = String[]
        console_push = message -> push!(messages, message)
        selected_path = nothing
        dialog = (directory; filterlist) -> selected_path
        captures = String[]
        capture = path -> (push!(captures, path); write(path, "complete PNG"))

        # Cancellation neither persists nor queues a capture
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test isempty(readdir(directory))
        @test isempty(captures)
        @test isempty(messages)

        selected_path = joinpath(directory, "My Galactic Escape")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        ship_path = selected_path * ".jld2"
        png_path = selected_path * ".png"
        @test state.pending_path == ship_path
        bundle = loadmap_bundle(ship_path)
        @test get_simulated_ticks(bundle.gamemap) == 1
        @test !is_galaxy_escape_active(bundle.gamemap)
        @test get_simulated_ticks(only(bundle.timelapse.frames)) == 1
        @test isempty(captures)  # Capture is deferred until the render loop finishes the next frame
        @test !ispath(png_path)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test read(png_path, String) == "complete PNG"
        @test isnothing(state.pending_path)
        @test last(messages) == "Escape saved! Ship: $ship_path; Screenshot: $png_path"
        @test !ispath(only(captures))
        @test sort(readdir(directory)) == ["My Galactic Escape.jld2", "My Galactic Escape.png"]

        # Refuse the PNG collision before replacing even an authorised ship file
        selected_path = ship_path
        write(ship_path, "keep ship")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        @test isnothing(state.pending_path)
        @test read(ship_path, String) == "keep ship"
        @test read(png_path, String) == "complete PNG"
        @test startswith(last(messages), "Nothing saved.")

        selected_path = joinpath(directory, "failed_capture.jld2")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        failed_capture = path -> (write(path, "partial PNG"); error("capture failed"))
        @test_logs (:warn, "Escape screenshot save failed") RocketPlumber.finish_escape_save!(state, failed_capture, console_push)
        @test startswith(last(messages), "Ship saved: $selected_path; screenshot failed:")
        @test isnothing(state.pending_path)
        @test !is_galaxy_escape_active(loadmap_bundle(selected_path).gamemap)
        @test !ispath(first(splitext(selected_path)) * ".png")
        @test all(name -> endswith(name, ".jld2") || endswith(name, ".png"), readdir(directory))

        # Ship failure must not queue or attempt a screenshot
        selected_path = joinpath(directory, "blocked.jld2")
        mkdir(selected_path)
        capture_count = length(captures)
        @test_logs (:warn, "Pre-escape map save failed") RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        @test isnothing(state.pending_path)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test length(captures) == capture_count
        @test !ispath(first(splitext(selected_path)) * ".png")
        @test startswith(last(messages), "Ship save failed: $selected_path.")
    end
end
