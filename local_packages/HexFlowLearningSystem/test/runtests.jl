using Test
using FlowMap
using FlowEngine
using HexComponentsAPI
using HexFlowCalculator
using HexFlowControl
using HexFlowLearningSystem

# ===============================================================
# Mock Types
# ===============================================================

struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(behaviour::MockCompBehav, ::Any) = behaviour
HexComponentsAPI.render_base_elem!(::Any, ::MockCompBehav; kwargs...) = nothing

struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(behaviour::MockPipeBehav, ::Any) = behaviour
HexComponentsAPI.render_pipe_base!(::Any, ::MockPipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::MockPipeBehav) = 0.1

# ===============================================================
# Test Helpers
# ===============================================================

function make_test_inputstate()
    return InputState(
        pendingpipebehavior = MockPipeBehav(),
        tile_tool_state = PlacementTileState(pendingcomponent = MockCompBehav()),
    )
end

function make_test_inputs(;
        gamemap::GameMap = GameMap(),
        derivedmapstate::DerivedMapState = DerivedMapState(),
        gamestate::GameState = GameState(),
        inputstate::InputState = make_test_inputstate(),
        flowcalc_shared_state::FlowCalculatorSharedState = FlowCalculatorSharedState(),
    )
    return LearningInputs(
        gamemap = gamemap,
        derivedmapstate = derivedmapstate,
        gamestate = gamestate,
        inputstate = inputstate,
        flowcalc_shared_state = flowcalc_shared_state,
    )
end

function make_ingame_def(n_steps::Int; title = "Test Tutorial", description = "Test")
    steps = [TutorialStep("Step $index") for index in 1:n_steps]
    return InGameTutorialDef(title = title, description = description, steps = steps)
end

function make_sandbox_def(steps::Vector{TutorialStep}; title = "Sandbox", description = "Sandbox Test", body_text = "")
    return SandboxTutorialDef(
        title = title,
        description = description,
        body_text = body_text,
        levels = [SandboxTutorialLevel(map_generator = () -> GameMap(), steps = steps)],
    )
end

function make_entry(id::Symbol; definition = make_ingame_def(3), priority = 0, trigger = _ -> true)
    return LearningEntry(id = id, trigger = trigger, definition = definition, priority = priority)
end

function make_system_state(entries::Vector{LearningEntry}; map_learning::AbstractLearningSystem = LearningProgress())
    sorted = sort(entries; by = e -> e.priority)
    return LearningSystemState(map_learning = map_learning, entries = sorted)
end

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowLearningSystem" begin

    #= ---------- State Query Functions ----------- =#

    @testset "get_tutorial_status" begin
        progress = LearningProgress()
        @test get_tutorial_status(progress, :missing) == TUTORIAL_WAITING

        progress.tutorials[:test] = TutorialState(status = TUTORIAL_IN_PROGRESS)
        @test get_tutorial_status(progress, :test) == TUTORIAL_IN_PROGRESS

        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        @test get_tutorial_status(sandbox, :sandbox) == TUTORIAL_IN_PROGRESS
        @test get_tutorial_status(sandbox, :other) == TUTORIAL_WAITING
    end

    @testset "get_unlocked_step" begin
        progress = LearningProgress()
        @test get_unlocked_step(progress, :missing) == 1

        progress.tutorials[:test] = TutorialState(unlocked_step = 5)
        @test get_unlocked_step(progress, :test) == 5

        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        @test get_unlocked_step(sandbox, :sandbox) == 1
        @test get_unlocked_step(sandbox, :other) == 1
    end

    @testset "get_steps" begin
        ingame_def = make_ingame_def(2)
        sandbox_def = make_sandbox_def([TutorialStep("Sandbox Step")])

        @test length(get_steps(ingame_def, LearningProgress())) == 2
        @test length(get_steps(sandbox_def, SandboxLearningState(tutorial_id = :sandbox, level_index = 1))) == 1
        @test isempty(get_steps(sandbox_def, SandboxLearningState(tutorial_id = :sandbox, level_index = 2)))
    end

    #= ---------- State Transition Functions ----------- =#

    @testset "activate_tutorial!" begin
        progress = LearningProgress()
        activate_tutorial!(progress, :new)
        @test progress.tutorials[:new].status == TUTORIAL_IN_PROGRESS

        sandbox = SandboxLearningState(tutorial_id = :sandbox, tutorial_state = TutorialState())
        activate_tutorial!(sandbox, :sandbox)
        @test sandbox.tutorial_state.status == TUTORIAL_IN_PROGRESS
    end

    @testset "complete_tutorial!" begin
        progress = LearningProgress()
        complete_tutorial!(progress, :done)
        @test progress.tutorials[:done].status == TUTORIAL_COMPLETED

        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        complete_tutorial!(sandbox, :sandbox)
        @test sandbox.tutorial_state.status == TUTORIAL_COMPLETED
    end

    @testset "unlock_next_step!" begin
        progress = LearningProgress()

        unlock_next_step!(progress, :new, 5)
        @test progress.tutorials[:new].unlocked_step == 2

        progress.tutorials[:final] = TutorialState(unlocked_step = 1)
        unlock_next_step!(progress, :final, 1)
        @test progress.tutorials[:final].unlocked_step == 2

        unlock_next_step!(progress, :final, 1)
        @test progress.tutorials[:final].unlocked_step == 2
    end

    #= ---------- Trigger Evaluation ----------- =#

    @testset "check_triggers! — activates first matching" begin
        entries = [make_entry(:a; trigger = _ -> true), make_entry(:b; trigger = _ -> true)]
        state = make_system_state(entries)
        inputs = make_test_inputs()

        result = check_triggers!(state, inputs)
        @test !isnothing(result)
        @test get_tutorial_status(state.map_learning, result) == TUTORIAL_IN_PROGRESS
    end

    @testset "check_triggers! — respects priority" begin
        entries = [
            make_entry(:highest; trigger = _ -> true, priority = 0),
            make_entry(:later; trigger = _ -> true, priority = 10),
        ]
        state = make_system_state(entries)
        inputs = make_test_inputs()

        @test check_triggers!(state, inputs) == :highest
    end

    @testset "check_triggers! — skips sandbox learning state" begin
        entries = [make_entry(:sandbox; trigger = _ -> true)]
        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        state = make_system_state(entries; map_learning = sandbox)
        inputs = make_test_inputs()

        @test isnothing(check_triggers!(state, inputs))
        @test sandbox.tutorial_state.status == TUTORIAL_IN_PROGRESS
    end

    #= ---------- Step Blocker Evaluation ----------- =#

    @testset "check_step_blockers! — no active hint" begin
        state = make_system_state([make_entry(:a)])
        @test isnothing(check_step_blockers!(state, make_test_inputs()))
    end

    @testset "check_step_blockers! — one-step blocker unlocks sentinel step" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [TutorialStep("Step 1", _ -> nothing)],
        )
        progress = LearningProgress()
        activate_tutorial!(progress, :a)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a

        check_step_blockers!(state, make_test_inputs())
        @test get_unlocked_step(state.map_learning, :a) == 2
        @test isnothing(progress.tutorials[:a].step_blocker)
    end

    @testset "check_step_blockers! — info step does not auto-advance" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [TutorialStep("Step 1"), TutorialStep("Step 2")],
        )
        progress = LearningProgress()
        activate_tutorial!(progress, :a)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a

        check_step_blockers!(state, make_test_inputs())
        @test get_unlocked_step(state.map_learning, :a) == 1
        @test isnothing(progress.tutorials[:a].step_blocker)
    end

    @testset "check_step_blockers! — blocked step caches its message" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [TutorialStep("Step 1", _ -> "Do the thing first.")],
        )
        progress = LearningProgress()
        activate_tutorial!(progress, :a)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a

        check_step_blockers!(state, make_test_inputs())
        @test get_unlocked_step(state.map_learning, :a) == 1
        @test progress.tutorials[:a].step_blocker == "Do the thing first."
    end

    @testset "check_step_blockers! — sandbox learning state can progress steps" begin
        definition = make_sandbox_def([TutorialStep("Step 1", _ -> nothing), TutorialStep("Step 2")])
        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        state = make_system_state([make_entry(:sandbox; definition = definition)]; map_learning = sandbox)
        state.active_hint_id = :sandbox

        check_step_blockers!(state, make_test_inputs())
        @test sandbox.tutorial_state.unlocked_step == 2
        @test isnothing(sandbox.tutorial_state.step_blocker)
    end

    @testset "check_step_blockers! - evaluates the frontier step" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [
                TutorialStep("Step 1", _ -> "Blocked"),
                TutorialStep("Step 2", _ -> nothing),
            ],
        )
        progress = LearningProgress()
        progress.tutorials[:a] = TutorialState(status = TUTORIAL_IN_PROGRESS, unlocked_step = 2)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a
        state.viewing_step = 2

        check_step_blockers!(state, make_test_inputs())
        @test get_unlocked_step(state.map_learning, :a) == 3
        @test isnothing(progress.tutorials[:a].step_blocker)
    end

    @testset "check_step_blockers! - does not re-evaluate a completed viewed step" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [
                TutorialStep("Step 1", _ -> nothing),
                TutorialStep("Step 2", _ -> "Still blocked"),
            ],
        )
        progress = LearningProgress()
        progress.tutorials[:a] = TutorialState(status = TUTORIAL_IN_PROGRESS, unlocked_step = 2)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a
        state.viewing_step = 1

        check_step_blockers!(state, make_test_inputs())
        @test get_unlocked_step(state.map_learning, :a) == 2
        @test progress.tutorials[:a].step_blocker == "Still blocked"
    end

    @testset "check_step_blockers! — handles blocker errors" begin
        definition = InGameTutorialDef(
            title = "Test",
            description = "Test",
            steps = [TutorialStep("Step 1", _ -> error("boom"))],
        )
        progress = LearningProgress()
        activate_tutorial!(progress, :a)
        state = make_system_state([make_entry(:a; definition = definition)]; map_learning = progress)
        state.active_hint_id = :a

        @test isnothing(check_step_blockers!(state, make_test_inputs()))
        @test get_unlocked_step(state.map_learning, :a) == 1
        @test progress.tutorials[:a].step_blocker == "Step blocker evaluation failed."
    end

    #= ---------- Learning System Tick ----------- =#

    @testset "learning_system_tick! — throttling" begin
        entries = [make_entry(:a; trigger = _ -> true)]
        state = make_system_state(entries)
        state.eval_interval = 3
        inputs = make_test_inputs()

        learning_system_tick!(state, inputs)
        @test get_tutorial_status(state.map_learning, :a) == TUTORIAL_WAITING
        learning_system_tick!(state, inputs)
        @test get_tutorial_status(state.map_learning, :a) == TUTORIAL_WAITING
        learning_system_tick!(state, inputs)
        @test get_tutorial_status(state.map_learning, :a) == TUTORIAL_IN_PROGRESS
    end

    @testset "learning_system_tick! — sandbox skips triggers but checks blockers" begin
        definition = make_sandbox_def([TutorialStep("Step 1", _ -> nothing), TutorialStep("Step 2")])
        sandbox = SandboxLearningState(tutorial_id = :sandbox)
        state = make_system_state([make_entry(:sandbox; definition = definition, trigger = _ -> true)]; map_learning = sandbox)
        state.active_hint_id = :sandbox
        state.eval_interval = 1

        learning_system_tick!(state, make_test_inputs())
        @test sandbox.tutorial_state.unlocked_step == 2
        @test sandbox.tutorial_state.status == TUTORIAL_IN_PROGRESS
    end

    @testset "learning_system_tick! — disabled for NoLearningSystem" begin
        state = make_system_state([make_entry(:a)]; map_learning = NoLearningSystem())
        state.eval_interval = 1

        @test isnothing(learning_system_tick!(state, make_test_inputs()))
        @test isnothing(state.active_hint_id)
    end

    #= ---------- Helper Functions ----------- =#

    @testset "find_learning_entry and get_learning_def" begin
        definition = make_ingame_def(2)
        entries = [make_entry(:a; definition = definition), make_entry(:b)]
        state = make_system_state(entries)

        @test find_learning_entry(state, :a).id == :a
        @test isnothing(find_learning_entry(state, :missing))
        @test get_learning_def(state, :a) === definition
        @test isnothing(get_learning_def(state, :missing))
    end
end
