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
