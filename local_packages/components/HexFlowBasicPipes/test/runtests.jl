#=
Scope: Tests for built-in pipe value semantics, placed tuning, and click radii
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI
using HexFlowBasicPipes

@testset "HexFlowBasicPipes" begin
    @test get_pipe_click_radius(ScrapPipeBehav()) == 0.083984375
    @test get_pipe_click_radius(BigPipeBehav()) == 0.146484375

    for pipe in (ScrapPipeBehav(), BigPipeBehav())
        @testset "$(typeof(pipe)) value semantics" begin
            @test !ismutabletype(typeof(pipe))
            @test isbitstype(typeof(pipe))
            original_conductance = get_conductance(pipe)
            tuned = set_pipe_tunables(pipe, (7.5,))
            @test tuned isa typeof(pipe)
            @test get_conductance(tuned) == 7.5
            @test get_conductance(pipe) == original_conductance

            placed = PlacedPipe(pipe, :Owner)
            updated = set_pipe_tunables(placed, (3.5,))
            @test updated.pipe isa typeof(pipe)
            @test get_conductance(updated) == 3.5
            @test updated.ship === :Owner
            @test get_conductance(placed) == original_conductance
            @test placed.ship === :Owner
        end
    end
end
