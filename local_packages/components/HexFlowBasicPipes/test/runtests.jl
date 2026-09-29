#=
Scope: Tests for HexFlowBasicPipes pipe click-radius behaviour
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI
using HexFlowBasicPipes

@testset "HexFlowBasicPipes" begin
    @test get_pipe_click_radius(ScrapPipeBehav()) == 0.083984375
    @test get_pipe_click_radius(BigPipeBehav()) == 0.146484375
end
