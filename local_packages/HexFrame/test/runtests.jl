using Test
using StaticArrays
using HexFrame

@testset "HexFrame Tests" begin

    @testset "Cartesian types" begin
        @testset "addition" begin
            @test CartesianCoord(1, 2) + CartesianCoord(4, 5) ≈ CartesianCoord(5, 7)
            @test CartesianCoord(-7.2, 2.8) + CartesianCoord(3, 5.1) ≈ CartesianCoord(-4.2, 7.9)
            @test CartesianCoord(0, 0) + CartesianCoord(0, 0) ≈ CartesianCoord(0, 0)
            @test CartesianCoord(1.5, -2.5) + CartesianCoord(-1.5, 2.5) ≈ CartesianCoord(0, 0)
        end

        @testset "subtraction" begin
            @test CartesianCoord(1, 2) - CartesianCoord(4, 5) ≈ CartesianCoord(-3, -3)
            @test CartesianCoord(-7.2, 2.8) - CartesianCoord(3, 5.1) ≈ CartesianCoord(-10.2, -2.3)
            @test CartesianCoord(0, 0) - CartesianCoord(0, 0) ≈ CartesianCoord(0, 0)
            @test CartesianCoord(1.5, -2.5) - CartesianCoord(-1.5, 2.5) ≈ CartesianCoord(3, -5)
        end
    end

    @testset "Axial types" begin
        @testset "addition" begin
            @test AxialCoord(1.0, 2.0) + AxialCoord(4.0, 5.0) ≈ AxialCoord(5.0, 7.0)
            @test AxialCoord(-7.2, 2.8) + AxialCoord(3.0, 5.1) ≈ AxialCoord(-4.2, 7.9)
            @test AxialCoord(0.0, 0.0) + AxialCoord(0.0, 0.0) ≈ AxialCoord(0.0, 0.0)
            @test AxialCoord(1.5, -2.5) + AxialCoord(-1.5, 2.5) ≈ AxialCoord(0.0, 0.0)
        end

        @testset "subtraction" begin
            @test AxialCoord(1.0, 2.0) - AxialCoord(4.0, 5.0) ≈ AxialCoord(-3.0, -3.0)
            @test AxialCoord(-7.2, 2.8) - AxialCoord(3.0, 5.1) ≈ AxialCoord(-10.2, -2.3)
            @test AxialCoord(0.0, 0.0) - AxialCoord(0.0, 0.0) ≈ AxialCoord(0.0, 0.0)
            @test AxialCoord(1.5, -2.5) - AxialCoord(-1.5, 2.5) ≈ AxialCoord(3.0, -5.0)
        end
    end

    @testset "TileCoord types" begin
        @testset "addition" begin
            @test TileCoord(1, 2) + TileCoord(4, 5) ≈ TileCoord(5, 7)
            @test TileCoord(-7, 2) + TileCoord(3, 5) ≈ TileCoord(-4, 7)
            @test TileCoord(0, 0) + TileCoord(0, 0) ≈ TileCoord(0, 0)
            @test TileCoord(1, -2) + TileCoord(-1, 2) ≈ TileCoord(0, 0)
        end

        @testset "subtraction" begin
            @test TileCoord(1, 2) - TileCoord(4, 5) ≈ TileCoord(-3, -3)
            @test TileCoord(-7, 2) - TileCoord(3, 5) ≈ TileCoord(-10, -3)
            @test TileCoord(0, 0) - TileCoord(0, 0) ≈ TileCoord(0, 0)
            @test TileCoord(1, -2) - TileCoord(-1, 2) ≈ TileCoord(2, -4)
        end
    end

    @testset "Mixed types" begin
        @testset "addition" begin
            @test AxialCoord(1.0, 2.0) + TileCoord(4, 5) ≈ AxialCoord(5.0, 7.0)
            @test AxialCoord(-7.2, 2.8) + TileCoord(3, 5) ≈ AxialCoord(-4.2, 7.8)
            @test AxialCoord(0.0, 0.0) + TileCoord(0, 0) ≈ AxialCoord(0.0, 0.0)
            @test AxialCoord(1.5, -2.5) + TileCoord(-1, 2) ≈ AxialCoord(0.5, -0.5)
        end

        @testset "subtraction" begin
            @test AxialCoord(1.0, 2.0) - TileCoord(4, 5) ≈ AxialCoord(-3.0, -3.0)
            @test AxialCoord(-7.2, 2.8) - TileCoord(3, 5) ≈ AxialCoord(-10.2, -2.2)
            @test AxialCoord(0.0, 0.0) - TileCoord(0, 0) ≈ AxialCoord(0.0, 0.0)
            @test AxialCoord(1.5, -2.5) - TileCoord(-1, 2) ≈ AxialCoord(2.5, -4.5)
        end
    end


    @testset "to_cartesian for TileCoord" begin
        @test to_cartesian(TileCoord(1, 0)) ≈ CartesianCoord(3 / 2, -sqrt(3) / 2)
        @test to_cartesian(TileCoord(0, 1)) ≈ CartesianCoord(0, -sqrt(3))
        @test to_cartesian(TileCoord(1, -1)) ≈ CartesianCoord(3 / 2, sqrt(3) / 2)
        @test to_cartesian(TileCoord(0, 0)) ≈ CartesianCoord(0.0, 0.0)
    end

    # had to increase the tolerance
    @testset "to_axial for CartesianCoord" begin
        @test isapprox(to_axial(CartesianCoord(3 / 2, -sqrt(3) / 2)), AxialCoord(1, 0), atol = 1.0e-15, rtol = 1.0e-15)
        @test isapprox(to_axial(CartesianCoord(0, -sqrt(3))), AxialCoord(0, 1), atol = 1.0e-15, rtol = 1.0e-15)
        @test isapprox(to_axial(CartesianCoord(3 / 2, sqrt(3) / 2)), AxialCoord(1, -1), atol = 1.0e-15, rtol = 1.0e-15)
        @test isapprox(to_axial(CartesianCoord(0.0, 0.0)), AxialCoord(0, 0), atol = 1.0e-15, rtol = 1.0e-15)
    end

    @testset "round_axial_to_tile for AxialCoord" begin
        @test round_to_tile(AxialCoord(0.1, 0.1)) ≈ TileCoord(0, 0)

    end

    @testset "get axial loaction of vertex" begin
        @test to_axial(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)) ≈ to_axial(CartesianCoord(1, 0))
    end

    @testset "get axial loaction of edge" begin
        TV1 = VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)
        TV2 = VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG)
        @test isapprox(to_axial(EdgeCoord(TV1, TV2)), to_axial(CartesianCoord(0, sqrt(3) / 2)), atol = 1.0e-15, rtol = 1.0e-15)
    end

    @testset "get rotaion matrix of edge" begin
        TV1 = VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)
        TV2 = VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG)
        @test get_rotmat(EdgeCoord(TV1, TV2)) ≈ hex_rotmats[HexFrame.Q_POS]
    end

    @testset "check is_proper vertexes" begin
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)) == true
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.R_NEG)) == false
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.S_POS)) == false
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)) == true
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.R_POS)) == false
        @test is_proper(VertexCoord(TileCoord(0, 0), HexFrame.S_NEG)) == false
    end

    @testset "to_proper vertexes" begin
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)) == VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.R_NEG)) == VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG)
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.S_POS)) == VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)) == VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.R_POS)) == VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS)
        @test to_proper(VertexCoord(TileCoord(0, 0), HexFrame.S_NEG)) == VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG)
    end

    @testset "check is_proper edges" begin
        @test is_proper(EdgeCoord(VertexCoord(Number[1, -1], HexFrame.Q_NEG), VertexCoord(Number[0, 0], HexFrame.Q_POS))) == true
        @test is_proper(EdgeCoord(VertexCoord(Number[0, 0], HexFrame.Q_POS), VertexCoord(Number[1, -1], HexFrame.Q_NEG))) == false
    end

    @testset "getting edges for a tile" begin
        desired_array = (
            EdgeCoord(VertexCoord(Number[1, -1], HexFrame.Q_NEG), VertexCoord(Number[0, 0], HexFrame.Q_POS)),
            EdgeCoord(VertexCoord(Number[-1, 0], HexFrame.Q_POS), VertexCoord(Number[1, -1], HexFrame.Q_NEG)),
            EdgeCoord(VertexCoord(Number[0, 0], HexFrame.Q_NEG), VertexCoord(Number[-1, 0], HexFrame.Q_POS)),
            EdgeCoord(VertexCoord(Number[0, 0], HexFrame.Q_NEG), VertexCoord(Number[-1, 1], HexFrame.Q_POS)),
            EdgeCoord(VertexCoord(Number[-1, 1], HexFrame.Q_POS), VertexCoord(Number[1, 0], HexFrame.Q_NEG)),
            EdgeCoord(VertexCoord(Number[1, 0], HexFrame.Q_NEG), VertexCoord(Number[0, 0], HexFrame.Q_POS)),
        )
        @test get_edges(TileCoord(0, 0)) == desired_array
    end

    @testset "edge rounding" begin
        @test round_to_edge(CartesianCoord(0, 0.2)) == EdgeCoord(VertexCoord(Number[-1, 0], HexFrame.Q_POS), VertexCoord(Number[1, -1], HexFrame.Q_NEG))
    end

    @testset "get_edges for a vertex" begin
        #check proper
        @test all(is_proper, get_edges(VertexCoord(Number[0, 0], HexFrame.Q_NEG))) == true
        @test all(is_proper, get_edges(VertexCoord(Number[0, 0], HexFrame.Q_POS))) == true
        @test all(is_proper, get_edges(VertexCoord(Number[2, -4], HexFrame.Q_NEG))) == true
    end

    @testset "get_vertexes for a vertex" begin
        #check proper
        @test all(is_proper, get_vertexes(VertexCoord(Number[0, 0], HexFrame.Q_NEG))) == true
        @test all(is_proper, get_vertexes(VertexCoord(Number[0, 0], HexFrame.Q_POS))) == true
        @test all(is_proper, get_vertexes(VertexCoord(Number[2, -4], HexFrame.Q_NEG))) == true
    end

    @testset "get_tiles for a vertex" begin
        @test get_tiles(VertexCoord(Number[0, -1], HexFrame.Q_POS)) == (TileCoord(1, -2), TileCoord(0, -1), TileCoord(1, -1))
        @test get_tiles(VertexCoord(Number[-1, 2], HexFrame.Q_NEG)) == (TileCoord(-1, 2), TileCoord(-2, 2), TileCoord(-2, 3))
    end


    @testset "rotate HexAxis" begin
        @test rotate(HexFrame.Q_POS, HexFrame.R_POS) == HexFrame.R_POS
        @test rotate(HexFrame.R_NEG, HexFrame.S_POS) == HexFrame.Q_NEG
        @test rotate(HexFrame.S_NEG, HexFrame.Q_NEG) == HexFrame.S_POS
    end


end
