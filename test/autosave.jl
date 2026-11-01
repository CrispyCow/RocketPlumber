#=
Scope: Autosave ownership, scheduling, and session eligibility
Formatter: Runic
=#

using RocketPlumber: AutosaveState, maybe_autosave!, finish_autosave!, write_autosave, final_autosave_bundle

@testset "Autosaves detach current state and share immutable history" begin
    mktempdir() do directory
        path = joinpath(directory, "_autosave.jld2")
        gamemap = GameMap(learning_system = LearningProgress([:editor_intro]))
        snapshot = FlowCalculatorSnapshot(; gamemap)
        learning = RocketPlumber.build_learning_runtime_state(deepcopy(gamemap))
        learning.map_learning.tutorials[:editor_intro].unlocked_step = 7
        timing = PlaySessionTiming(123.0)

        historical_map = GameMap()
        increment_simulated_ticks!(historical_map)
        recorder = TimelapseRecorder(TimelapseHistory(frames = [historical_map]); now = 0.0)
        state = AutosaveState(; now = 0.0)
        messages = String[]
        console_push = message -> push!(messages, message)
        @test maybe_autosave!(state, recorder, snapshot, timing, learning, console_push; now = 30.0, save_path = path)

        increment_simulated_ticks!(snapshot.gamemap)
        learning.map_learning.tutorials[:editor_intro].unlocked_step = 9
        push!(recorder.history.frames, GameMap())
        finish_autosave!(state, console_push; save_path = path)

        saved = loadmap_bundle(path)
        @test get_simulated_ticks(saved.gamemap) == 0
        @test get_recorded_play_time_seconds(saved.gamemap) >= 123.0
        @test saved.gamemap.learning_system.tutorials[:editor_intro].unlocked_step == 7
        @test length(saved.timelapse.frames) == 1
        @test get_simulated_ticks(only(saved.timelapse.frames)) == 1
        @test recorder.next_capture_time_seconds == 60.0
        @test length(recorder.history.frames) == 2  # Autosaving did not force a capture
        @test HexFlowPersistence.load_game_version(path) == string(Base.pkgversion(RocketPlumber))
        @test isempty(messages)
    end
end

@testset "Autosave deadlines, writer lifetime and recovery" begin
    mktempdir() do directory
        path = joinpath(directory, "_autosave.jld2")
        state = AutosaveState(; now = 0.0)
        recorder = TimelapseRecorder(; now = 0.0)
        snapshot = FlowCalculatorSnapshot()
        timing = PlaySessionTiming(0.0)
        messages = String[]
        console_push = message -> push!(messages, message)
        @test state.next_save_time_seconds == 30.0
        @test !maybe_autosave!(state, recorder, snapshot, timing, nothing, console_push; now = 29.0, save_path = path)
        @test !maybe_autosave!(state, recorder, snapshot, timing, nothing, console_push; suppressed = true, now = 30.0, save_path = path)
        @test isnothing(state.writer_task)
        @test maybe_autosave!(state, recorder, snapshot, timing, nothing, console_push; now = 30.0, save_path = path)
        finish_autosave!(state, console_push; save_path = path)
        @test state.next_save_time_seconds == 90.0

        # An unscheduled writer makes overlap and final ordering deterministic without sleeps.
        previous = GameMapBundle(GameMap())
        state.writer_task = Task(() -> write_autosave(previous, path))
        outstanding = state.writer_task
        @test !maybe_autosave!(state, recorder, snapshot, timing, nothing, console_push; now = 90.0, save_path = path)
        @test state.writer_task === outstanding
        @test state.next_save_time_seconds == 150.0
        final_bundle = GameMapBundle(GameMap())
        increment_simulated_ticks!(final_bundle.gamemap)
        schedule(outstanding)
        finish_autosave!(state, console_push, final_bundle; save_path = path)
        @test istaskdone(outstanding)
        @test isnothing(state.writer_task)
        @test get_simulated_ticks(loadmap(path)) == 1
        @test isempty(messages)
    end
end

@testset "Autosave session eligibility and final recovery points" begin
    bundle = GameMapBundle(GameMap(), TimelapseHistory(frames = [GameMap()]))
    for reason in (EXIT_MENU, EXIT_QUIT, EXIT_SANDBOX_STARTED)
        inputstate = InputState(exit_reason = reason)
        @test final_autosave_bundle(bundle, inputstate; completed = false) === bundle
    end
    for reason in (EXIT_RESTART, EXIT_SANDBOX_COMPLETED)
        @test isnothing(final_autosave_bundle(bundle, InputState(exit_reason = reason); completed = false))
    end
    browsing = InputState(gui_inputs = Dict(:timelapse_original_map => GameMap()))
    sandbox = GameMapBundle(GameMap(learning_system = SandboxLearningState(tutorial_id = :teaser, level_index = 1)))
    @test isnothing(final_autosave_bundle(bundle, browsing; completed = false))
    @test isnothing(final_autosave_bundle(sandbox, InputState(); completed = false))
    restoring = InputState(gui_inputs = Dict(:timelapse_restore_requested_at => 10.0))
    @test isnothing(final_autosave_bundle(bundle, restoring; completed = false, snapshot_timestamp = 9.0))
    @test final_autosave_bundle(bundle, restoring; completed = false, snapshot_timestamp = 11.0) === bundle

    checkpoint = GameMap(learning_system = LearningProgress([:editor_intro]), space_map = SpaceMapState(encounter_config = RocketPlumber.get_encounter_system_config()))
    escape = GameMapBundle(GameMap(space_map = GalaxyEscapeSpaceMap(SVector(10.0, 0.0), 10.0, 0.0, checkpoint)), bundle.timelapse)
    set_recorded_play_time_seconds!(escape.gamemap, 123.0)
    set_learning_system!(escape.gamemap, LearningProgress([:editor_intro]))
    escape.gamemap.learning_system.tutorials[:editor_intro].unlocked_step = 7
    @test final_autosave_bundle(escape, InputState(); completed = false) === escape
    recovery = final_autosave_bundle(escape, InputState(); completed = true)
    @test recovery.gamemap !== checkpoint
    @test recovery.gamemap.space_map isa SpaceMapState
    @test get_recorded_play_time_seconds(recovery.gamemap) == 123.0
    @test recovery.gamemap.learning_system.tutorials[:editor_intro].unlocked_step == 7
    @test get_recorded_play_time_seconds(checkpoint) == 0.0
    @test checkpoint.learning_system.tutorials[:editor_intro].unlocked_step == 1
    @test recovery.timelapse === escape.timelapse
    @test isnothing(final_autosave_bundle(bundle, InputState(); completed = true))
end
