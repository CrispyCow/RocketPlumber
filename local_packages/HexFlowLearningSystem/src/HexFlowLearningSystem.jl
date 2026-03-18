module HexFlowLearningSystem

using FlowMap
using HexFlowCalculator
using HexFlowControl
import FlowMap: is_sandbox_learning

# ===============================================================
# Exports
# ===============================================================

export LearningInputs
export AbstractTutorialDef, TutorialStep, InGameTutorialDef
export SandboxTutorialLevel, SandboxTutorialDef
export LearningEntry, LearningSystemState
export get_steps, get_current_tutorial_state, get_active_entry
export is_learning_enabled, is_sandbox_learning
export get_tutorial_status, get_unlocked_step
export get_in_progress_tutorials, get_completed_tutorials
export activate_tutorial!, complete_tutorial!, unlock_next_step!
export check_triggers!, check_step_blockers!, learning_system_tick!
export find_learning_entry, get_learning_def

# ===============================================================
# Learning Inputs
# ===============================================================

"Bundles all data available to trigger predicates and step blockers."
@kwdef struct LearningInputs
    gamemap::GameMap
    gamestate::GameState
    inputstate::InputState
    flowcalc_shared_state::FlowCalculatorSharedState
end

# ===============================================================
# Tutorial Definitions
# ===============================================================

abstract type AbstractTutorialDef end

"""One step in a tutorial sequence.

`step_blocker = nothing` means the step is informational and can be advanced freely.
When present, the blocker is called as `(::LearningInputs) -> Union{Nothing, String}`.
It returns `nothing` once the player may proceed, or a `String` explaining what still needs doing.
"""
@kwdef struct TutorialStep
    heading::String = ""
    text::String
    step_blocker::Union{Nothing, Function} = nothing
end

TutorialStep(text::String) = TutorialStep("", text, nothing)
TutorialStep(heading::String, text::String) = TutorialStep(heading, text, nothing)
TutorialStep(text::String, step_blocker::Union{Nothing, Function}) = TutorialStep("", text, step_blocker)

"Definition of an in-game tutorial shown in the Learning Helper."
@kwdef struct InGameTutorialDef <: AbstractTutorialDef
    title::String
    description::String
    steps::Vector{TutorialStep}
end

"One level in a sandbox tutorial sequence."
@kwdef struct SandboxTutorialLevel
    map_generator::Function # () -> GameMap
    steps::Vector{TutorialStep}
end

"Definition of a sandbox tutorial consisting of one or more maps."
@kwdef struct SandboxTutorialDef <: AbstractTutorialDef
    title::String
    description::String
    body_text::String
    levels::Vector{SandboxTutorialLevel}
end

# ===============================================================
# Learning Entry
# ===============================================================

"A registered learning entry containing its trigger, definition, and priority."
@kwdef struct LearningEntry
    id::Symbol
    trigger::Function
    definition::AbstractTutorialDef
    priority::Int = 0
end

# ===============================================================
# Learning System Runtime State
# ===============================================================

"Mutable render-thread state for tutorial UI and predicate evaluation."
@kwdef mutable struct LearningSystemState
    map_learning::AbstractLearningSystem
    entries::Vector{LearningEntry}
    active_hint_id::Union{Nothing, Symbol} = nothing
    viewing_step::Int = 1
    learning_helper_visible::Bool = true
    learning_helper_expanded::Bool = false
    frames_since_last_eval::Int = 0
    eval_interval::Int = 5
    current_helper_pos::Union{Nothing, NTuple{2, Float32}} = nothing
end

# ===============================================================
# Learning System Helpers
# ===============================================================

"Check whether a learning system is enabled."
is_learning_enabled(::AbstractLearningSystem)::Bool = true
is_learning_enabled(::NoLearningSystem)::Bool = false

"Check whether the learning system is a sandbox tutorial."
is_sandbox_learning(::AbstractLearningSystem)::Bool = false
is_sandbox_learning(::SandboxLearningState)::Bool = true
is_sandbox_learning(state::LearningSystemState)::Bool = is_sandbox_learning(state.map_learning)

"Get the persistent learning progress when available."
get_learning_progress(progress::LearningProgress)::LearningProgress = progress
get_learning_progress(::AbstractLearningSystem)::Nothing = nothing

"Get the sandbox tutorial state stored on a sandbox map."
get_sandbox_tutorial_state(learning_system::SandboxLearningState)::TutorialState = learning_system.tutorial_state

"Get the per-entry tutorial state for the active map learning system."
function get_current_tutorial_state(learning_system::LearningProgress, id::Symbol)::TutorialState
    return get(learning_system.tutorials, id, TutorialState())
end

function get_current_tutorial_state(learning_system::SandboxLearningState, id::Symbol)::Union{Nothing, TutorialState}
    learning_system.tutorial_id == id || return nothing
    return learning_system.tutorial_state
end

get_current_tutorial_state(::AbstractLearningSystem, ::Symbol)::Nothing = nothing

"Get the per-entry tutorial state using runtime learning state."
function get_current_tutorial_state(state::LearningSystemState, id::Symbol)::Union{Nothing, TutorialState}
    return get_current_tutorial_state(state.map_learning, id)
end

"Get the tutorial status, defaulting to waiting when the entry is not tracked."
function get_tutorial_status(learning_system::AbstractLearningSystem, id::Symbol)::TutorialStatus
    tutorial_state = get_current_tutorial_state(learning_system, id)
    return isnothing(tutorial_state) ? TUTORIAL_WAITING : tutorial_state.status
end

"Get the unlocked step index, defaulting to 1 when the entry is not tracked."
function get_unlocked_step(learning_system::AbstractLearningSystem, id::Symbol)::Int
    tutorial_state = get_current_tutorial_state(learning_system, id)
    return isnothing(tutorial_state) ? 1 : tutorial_state.unlocked_step
end

"Get all in-progress tutorial IDs from persistent learning progress."
function get_in_progress_tutorials(progress::LearningProgress)::Vector{Symbol}
    return [id for (id, tutorial_state) in progress.tutorials if tutorial_state.status == TUTORIAL_IN_PROGRESS]
end

get_in_progress_tutorials(::AbstractLearningSystem)::Vector{Symbol} = Symbol[]

"Get all completed tutorial IDs from persistent learning progress."
function get_completed_tutorials(progress::LearningProgress)::Vector{Symbol}
    return [id for (id, tutorial_state) in progress.tutorials if tutorial_state.status == TUTORIAL_COMPLETED]
end

get_completed_tutorials(::AbstractLearningSystem)::Vector{Symbol} = Symbol[]

function _get_or_create_tutorial_state!(progress::LearningProgress, id::Symbol)::TutorialState
    return get!(progress.tutorials, id, TutorialState())
end

function _get_or_create_tutorial_state!(learning_system::SandboxLearningState, id::Symbol)::Union{Nothing, TutorialState}
    learning_system.tutorial_id == id || return nothing
    return learning_system.tutorial_state
end

_get_or_create_tutorial_state!(::AbstractLearningSystem, ::Symbol)::Nothing = nothing

# ===============================================================
# State Transition Functions
# ===============================================================

"Transition a tutorial to IN_PROGRESS."
function activate_tutorial!(learning_system::AbstractLearningSystem, id::Symbol)
    tutorial_state = _get_or_create_tutorial_state!(learning_system, id)
    isnothing(tutorial_state) && return nothing
    tutorial_state.status = TUTORIAL_IN_PROGRESS
    tutorial_state.step_blocker = nothing
    return nothing
end

"Mark a tutorial as completed."
function complete_tutorial!(learning_system::AbstractLearningSystem, id::Symbol)
    tutorial_state = _get_or_create_tutorial_state!(learning_system, id)
    isnothing(tutorial_state) && return nothing
    tutorial_state.status = TUTORIAL_COMPLETED
    tutorial_state.step_blocker = nothing
    return nothing
end

"Advance the unlocked step, allowing the sentinel completion step `max_steps + 1`."
function unlock_next_step!(learning_system::AbstractLearningSystem, id::Symbol, max_steps::Int)
    tutorial_state = _get_or_create_tutorial_state!(learning_system, id)
    isnothing(tutorial_state) && return nothing
    if tutorial_state.unlocked_step <= max_steps
        tutorial_state.unlocked_step += 1
    end
    return nothing
end

# ===============================================================
# Tutorial Step Access
# ===============================================================

"Get the step vector for an in-game tutorial definition."
get_steps(definition::InGameTutorialDef, ::AbstractLearningSystem)::Vector{TutorialStep} = definition.steps

"Get the step vector for the currently active sandbox level."
function get_steps(definition::SandboxTutorialDef, learning_system::SandboxLearningState)::Vector{TutorialStep}
    if learning_system.level_index < 1 || learning_system.level_index > length(definition.levels)
        return TutorialStep[]
    end
    return definition.levels[learning_system.level_index].steps
end

get_steps(::SandboxTutorialDef, ::AbstractLearningSystem)::Vector{TutorialStep} = TutorialStep[]

# ===============================================================
# Trigger Evaluation
# ===============================================================

"Check all entry triggers and activate the highest-priority waiting entry whose predicate passes."
function check_triggers!(state::LearningSystemState, inputs::LearningInputs)::Union{Nothing, Symbol}
    state.map_learning isa LearningProgress || return nothing

    # Entries are pre-sorted so lower priority numbers are evaluated first.
    for entry in state.entries
        get_tutorial_status(state.map_learning, entry.id) == TUTORIAL_WAITING || continue

        fired = try
            entry.trigger(inputs)
        catch exception
            @warn "Learning entry trigger predicate failed" entry_id = entry.id exception
            false
        end

        if fired
            activate_tutorial!(state.map_learning, entry.id)
            return entry.id
        end
    end

    return nothing
end

"Look up a LearningEntry by ID."
function find_learning_entry(state::LearningSystemState, id::Symbol)::Union{Nothing, LearningEntry}
    index = findfirst(entry -> entry.id == id, state.entries)
    return isnothing(index) ? nothing : state.entries[index]
end

"Get the definition for an entry by ID."
function get_learning_def(state::LearningSystemState, id::Symbol)
    entry = find_learning_entry(state, id)
    return isnothing(entry) ? nothing : entry.definition
end

"Get the currently active learning entry if any."
function get_active_entry(state::LearningSystemState)::Union{Nothing, LearningEntry}
    isnothing(state.active_hint_id) && return nothing
    return find_learning_entry(state, state.active_hint_id)
end

function _get_current_step_for_eval(tutorial_state::TutorialState, _state::LearningSystemState, num_steps::Int)::Int
    return clamp(tutorial_state.unlocked_step, 1, num_steps)
end

"Evaluate the current frontier step blocker for the active tutorial."
function check_step_blockers!(state::LearningSystemState, inputs::LearningInputs)
    entry = get_active_entry(state)
    isnothing(entry) && return nothing

    tutorial_state = get_current_tutorial_state(state, entry.id)
    isnothing(tutorial_state) && return nothing

    steps = get_steps(entry.definition, state.map_learning)
    if isempty(steps)
        tutorial_state.step_blocker = nothing
        return nothing
    end

    num_steps = length(steps)
    if tutorial_state.unlocked_step > num_steps
        tutorial_state.step_blocker = nothing
        return nothing
    end

    step_index = _get_current_step_for_eval(tutorial_state, state, num_steps)
    step = steps[step_index]
    if isnothing(step.step_blocker)
        tutorial_state.step_blocker = nothing
        return nothing
    end

    result = try
        step.step_blocker(inputs)
    catch exception
        @warn "Tutorial step blocker evaluation failed" entry_id = entry.id step_index exception
        "Step blocker evaluation failed."
    end

    tutorial_state.step_blocker = result
    isnothing(result) && unlock_next_step!(state.map_learning, entry.id, num_steps)
    return nothing
end

# ===============================================================
# Main Tick Function
# ===============================================================

"Called once per frame. Handles evaluation throttling, trigger checks, and step blocker progression."
function learning_system_tick!(state::LearningSystemState, inputs::LearningInputs)
    is_learning_enabled(state.map_learning) || return nothing

    state.frames_since_last_eval += 1
    state.frames_since_last_eval < state.eval_interval && return nothing

    state.frames_since_last_eval = 0
    check_triggers!(state, inputs)
    check_step_blockers!(state, inputs)

    return nothing
end

end # module HexFlowLearningSystem
