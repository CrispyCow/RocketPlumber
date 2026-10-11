#=
Scope: Contract tests for placed value transitions, action metadata, validation errors, and request results
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI

struct TestExpectedMapValidationError <: ExpectedMapValidationError end

status_result()::RequestStatus = ValidRequest()
payload_result()::RequestResult{Symbol} = ValidRequestResult(:ship)

@testset "ActionInfo" begin
    enabled_action = ActionInfo(id = :open, label = "Open", enabled = true, tooltip = "Ready")
    disabled_action = ActionInfo(id = :close, label = "Close", enabled = false, tooltip = "Already closed")
    group_enabled_action = ActionInfo(
        id = :vent,
        label = "Vent",
        enabled = false,
        group_enabled = true,
        tooltip = "Already empty",
    )
    confirmed_action = ActionInfo(
        id = :delete,
        label = "Delete",
        enabled = true,
        tooltip = "Remove it",
        confirmation_message = "Are you sure?",
    )

    @test enabled_action.group_enabled
    @test !disabled_action.group_enabled
    @test group_enabled_action.group_enabled
    @test isnothing(enabled_action.confirmation_message)
    @test confirmed_action.confirmation_message == "Are you sure?"
end

@testset "ExpectedMapValidationError contract" begin
    @test ExpectedMapValidationError <: Exception
    @test TestExpectedMapValidationError() isa ExpectedMapValidationError
    @test TestExpectedMapValidationError() isa Exception
end

@testset "HexComponentsAPI request results" begin
    @testset "construction" begin
        @test ValidRequest() isa ValidRequest
        @test ValidRequestResult(:ship).result === :ship

        string_reason = "invalid placement"
        substring_reason = SubString("invalid placement", 1, 7)
        @test InvalidRequest(string_reason).reason === string_reason
        @test InvalidRequest(substring_reason).reason == "invalid"
        @test InvalidRequest(substring_reason).reason isa String
    end

    @testset "validity" begin
        @test isvalidrequest(ValidRequest())
        @test isvalidrequest(ValidRequestResult(42))
        @test !isvalidrequest(InvalidRequest("blocked"))
    end

    @testset "successful results" begin
        @test unwrap(ValidRequestResult(:ship)) === :ship
        @test unwrap(ValidRequestResult(42)) == 42
        @test unwrap(ValidRequestResult(Dict(:pipe => :ship))) == Dict(:pipe => :ship)
        @test isvalidrequest(status_result())
        @test unwrap(payload_result()) === :ship
    end

    @testset "invalid results" begin
        invalid = InvalidRequest("occupied")
        unwrap_error = try
            unwrap(invalid)
        catch err
            err
        end
        @test unwrap_error isa ArgumentError
        @test unwrap_error.msg == "cannot unwrap an invalid request: occupied"
        @test reason(invalid) == "occupied"
    end

    @testset "valid requests do not expose failure reasons" begin
        valid_status_error = try
            reason(ValidRequest())
        catch err
            err
        end
        valid_result_error = try
            reason(ValidRequestResult(:ship))
        catch err
            err
        end

        @test valid_status_error isa ArgumentError
        @test valid_result_error isa ArgumentError
        @test valid_status_error.msg == "a valid request has no failure reason"
        @test valid_result_error.msg == "a valid request has no failure reason"
    end
end

struct DefaultValueBehaviour <: ComponentBehavior end
struct TransitionBehaviour <: ComponentBehavior
    state::Int
end
HexComponentsAPI.update_flowbehav(behav::TransitionBehaviour; kwargs...) = TransitionBehaviour(behav.state + 1)
HexComponentsAPI.get_tunables(behav::TransitionBehaviour) = (TunableProps(behav.state, "Test parameter", ""),)
HexComponentsAPI.set_tunables(behav::TransitionBehaviour, values::Tuple) = TransitionBehaviour(Int(only(values)))
HexComponentsAPI.on_click(behav::TransitionBehaviour; kwargs...) = TransitionBehaviour(behav.state + 2)
HexComponentsAPI.commit_reactivation_probe(behav::TransitionBehaviour; kwargs...) = TransitionBehaviour(behav.state + 3)
function HexComponentsAPI.do_action(behav::TransitionBehaviour, action_id::Symbol; kwargs...)
    action_id === :advance && return TransitionBehaviour(behav.state + 4), ValidRequestResult("Advanced")
    action_id === :reject && return behav, InvalidRequest("Rejected")
    throw(ArgumentError("Unsupported action"))
end

@testset "Value transition defaults and placed delegation" begin
    default = DefaultValueBehaviour()
    @test update_flowbehav(default) === default
    @test on_click(default) === default
    @test commit_reactivation_probe(default) === default
    @test_throws ArgumentError do_action(default, :unsupported)

    original = PlacedComponent(TransitionBehaviour(10), HexComponentsAPI.HexFrame.S_NEG, true, :Owner)
    for (transition, expected) in (
            (update_flowbehav, 11), (on_click, 12), (commit_reactivation_probe, 13),
            (comp -> on_click(comp; unrotated_clicksite = HexComponentsAPI.HexFrame.CartesianCoord(0.2, 0.1)), 12),
        )
        updated = transition(original)
        @test updated.component.state == expected
        @test original.component.state == 10
        @test (updated.rotation, updated.mirrored, updated.ship) == (original.rotation, true, :Owner)
    end
    @test get_tunables(original) == get_tunables(original.component)
    tuned = set_tunables(original, (25,))
    @test tuned isa PlacedComponent
    @test tuned.component.state == 25
    @test original.component.state == 10
    @test (tuned.rotation, tuned.mirrored, tuned.ship) == (original.rotation, true, :Owner)

    updated, result = do_action(original, :advance)
    @test updated.component.state == 14
    @test isvalidrequest(result)
    @test original.component.state == 10
    @test (updated.rotation, updated.mirrored, updated.ship) == (original.rotation, true, :Owner)
    unchanged, rejected = do_action(original, :reject)
    @test unchanged.component.state == 10
    @test unchanged === original
    @test !isvalidrequest(rejected)
    @test_throws ArgumentError do_action(original, :unsupported)
    @test (original.component.state, original.rotation, original.mirrored, original.ship) == (10, HexComponentsAPI.HexFrame.S_NEG, true, :Owner)
end
