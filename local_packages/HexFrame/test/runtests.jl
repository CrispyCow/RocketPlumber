#=
Scope: Test suite for HexFrame coordinate systems, conversions, and spatial operations
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using StaticArrays
using HexFrame

@testset "HexFrame Tests" begin
    pipe_has_proper_vertices(pipe::PipeCoord)::Bool = is_proper(pipe.v1) && is_proper(pipe.v2)

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
        @test round_to_tile(AxialCoord(40000.2, -40000.1)) == TileCoord(40000, -40000)
        @test TileCoord(0, 0).q isa Int32

    end

    @testset "get axial loaction of vertex" begin
        @test to_axial(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)) ≈ to_axial(CartesianCoord(1, 0))
    end

    @testset "get axial location of side pipe" begin
        TV1 = VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)
        TV2 = VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG)
        @test isapprox(to_axial(PipeCoord(TV1, TV2)), to_axial(CartesianCoord(0, sqrt(3) / 2)), atol = 1.0e-15, rtol = 1.0e-15)
    end

    @testset "get rotation matrix of side pipe" begin
        TV1 = VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)
        TV2 = VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG)
        @test get_rotmat(PipeCoord(TV1, TV2)) ≈ hex_rotmats[HexFrame.Q_POS]
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

    @testset "getting side pipes for a tile" begin
        desired_array = (
            PipeCoord(VertexCoord(Number[1, -1], HexFrame.Q_NEG), VertexCoord(Number[0, 0], HexFrame.Q_POS)),
            PipeCoord(VertexCoord(Number[-1, 0], HexFrame.Q_POS), VertexCoord(Number[1, -1], HexFrame.Q_NEG)),
            PipeCoord(VertexCoord(Number[0, 0], HexFrame.Q_NEG), VertexCoord(Number[-1, 0], HexFrame.Q_POS)),
            PipeCoord(VertexCoord(Number[0, 0], HexFrame.Q_NEG), VertexCoord(Number[-1, 1], HexFrame.Q_POS)),
            PipeCoord(VertexCoord(Number[-1, 1], HexFrame.Q_POS), VertexCoord(Number[1, 0], HexFrame.Q_NEG)),
            PipeCoord(VertexCoord(Number[1, 0], HexFrame.Q_NEG), VertexCoord(Number[0, 0], HexFrame.Q_POS)),
        )
        @test get_side_pipes(TileCoord(0, 0)) == desired_array
    end

    @testset "side pipe rounding" begin
        @test round_to_side_pipe(CartesianCoord(0, 0.2)) == PipeCoord(VertexCoord(Number[-1, 0], HexFrame.Q_POS), VertexCoord(Number[1, -1], HexFrame.Q_NEG))
    end

    @testset "get_side_pipes for a vertex" begin
        @test all(pipe_has_proper_vertices, get_side_pipes(VertexCoord(Number[0, 0], HexFrame.Q_NEG))) == true
        @test all(pipe_has_proper_vertices, get_side_pipes(VertexCoord(Number[0, 0], HexFrame.Q_POS))) == true
        @test all(pipe_has_proper_vertices, get_side_pipes(VertexCoord(Number[2, -4], HexFrame.Q_NEG))) == true
        @test all(is_side_span, get_side_pipes(VertexCoord(Number[2, -4], HexFrame.Q_NEG))) == true
    end

    @testset "get_tiles for a vertex" begin
        @test get_tiles(VertexCoord(Number[0, -1], HexFrame.Q_POS)) == (TileCoord(1, -2), TileCoord(0, -1), TileCoord(1, -1))
        @test get_tiles(VertexCoord(Number[-1, 2], HexFrame.Q_NEG)) == (TileCoord(-1, 2), TileCoord(-2, 2), TileCoord(-2, 3))
    end

    @testset "PipeCoord construction and classification" begin
        tile = TileCoord(0, 0)
        qpos = VertexCoord(tile, HexFrame.Q_POS)
        rneg = VertexCoord(tile, HexFrame.R_NEG)
        spos = VertexCoord(tile, HexFrame.S_POS)
        qneg = VertexCoord(tile, HexFrame.Q_NEG)

        side = PipeCoord(qpos, rneg)
        short_diag = PipeCoord(qpos, spos)
        long_diag = PipeCoord(qpos, qneg)

        @test PipeCoord(qpos, rneg) == PipeCoord(rneg, qpos)
        @test PipeCoord(qpos, rneg) == PipeCoord(qpos, to_proper(rneg))
        @test pipe_has_proper_vertices(PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG)))
        @test to_proper(side) == side
        @test_throws ArgumentError PipeCoord(qpos, qpos)
        @test_throws ArgumentError PipeCoord(qpos, VertexCoord(TileCoord(9, 9), HexFrame.Q_POS))

        @test pipe_span_class(side) === SIDE_SPAN
        @test pipe_span_class(short_diag) === SHORT_DIAGONAL_SPAN
        @test pipe_span_class(long_diag) === LONG_DIAGONAL_SPAN
        @test pipe_segment_length(side) ≈ 1.0
        @test pipe_segment_length(short_diag) ≈ sqrt(3.0)
        @test pipe_segment_length(long_diag) ≈ 2.0
        @test pipe_segment_length(qpos, spos) ≈ sqrt(3.0)
        @test is_side_span(side) && !is_short_diagonal_span(side) && !is_long_diagonal_span(side)
        @test !is_side_span(short_diag) && is_short_diagonal_span(short_diag) && !is_long_diagonal_span(short_diag)
        @test !is_side_span(long_diag) && !is_short_diagonal_span(long_diag) && is_long_diagonal_span(long_diag)
        @test is_valid_pipe_segment(side)
        @test is_valid_pipe_segment(qpos, spos)
        @test !is_valid_pipe_segment(qpos, VertexCoord(TileCoord(9, 9), HexFrame.Q_POS))

        @test common_tile_count(side) == 2
        @test common_tile_count(qpos, rneg) == 2
        @test isnothing(get_tile_containing_pipe(side))
        @test common_tile_count(short_diag) == 1
        @test get_tile_containing_pipe(short_diag) == tile
        @test common_tile_count(long_diag) == 1
        @test get_tile_containing_pipe(long_diag) == tile
    end

    @testset "PipeCoord rotation matrix" begin
        tile = TileCoord(0, 0)
        side = PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.R_NEG))
        short_diag = PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.S_POS))
        long_diag = PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.Q_NEG))

        row_transform(axis, matrix) = SVector(
            axis[1] * matrix[1, 1] + axis[2] * matrix[2, 1],
            axis[1] * matrix[1, 2] + axis[2] * matrix[2, 2],
        )
        pipe_direction(pipe) = begin
            delta = to_cartesian(pipe.v2) - to_cartesian(pipe.v1)
            SVector(delta.x, delta.y) ./ pipe_segment_length(pipe)
        end

        side_rotation = get_rotmat(side)'
        @test row_transform(SVector(1.0f0, 0.0f0), side_rotation) ≈ pipe_direction(side)

        short_rotation = get_rotmat(short_diag)'
        @test row_transform(SVector(0.0f0, 1.0f0), short_rotation) ≈ pipe_direction(short_diag)

        long_rotation = get_rotmat(long_diag)'
        @test row_transform(SVector(1.0f0, 0.0f0), long_rotation) ≈ pipe_direction(long_diag)
    end

    @testset "offset_by_tile" begin
        tile = TileCoord(3, -4)
        offset = TileCoord(-2, 5)

        @test offset_by_tile(tile, offset) == TileCoord(1, 1)
        @test offset_by_tile(VertexCoord(tile, HexFrame.Q_POS), offset) == VertexCoord(TileCoord(1, 1), HexFrame.Q_POS)

        pipe = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))
        expected = PipeCoord(
            VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS),
            VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG),
        )

        @test offset_by_tile(pipe, offset) == expected
    end

    @testset "Pipe segment generation" begin
        tile = TileCoord(0, 0)
        qpos = VertexCoord(tile, HexFrame.Q_POS)
        qneg = VertexCoord(tile, HexFrame.Q_NEG)

        expected_qpos = (
            PipeCoord(qpos, VertexCoord(tile + TileCoord(2, -1), HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(1, -1), HexFrame.Q_POS)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(2, -2), HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(0, -1), HexFrame.Q_POS)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(1, -1), HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(-1, 0), HexFrame.Q_POS)),
            PipeCoord(qpos, VertexCoord(tile, HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(-1, 1), HexFrame.Q_POS)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(1, 0), HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(0, 1), HexFrame.Q_POS)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(2, 0), HexFrame.Q_NEG)),
            PipeCoord(qpos, VertexCoord(tile + TileCoord(1, 0), HexFrame.Q_POS)),
        )
        expected_qneg = (
            PipeCoord(qneg, VertexCoord(tile, HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(1, -1), HexFrame.Q_NEG)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-1, 0), HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(0, -1), HexFrame.Q_NEG)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-2, 0), HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-1, 0), HexFrame.Q_NEG)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-2, 1), HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-1, 1), HexFrame.Q_NEG)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-2, 2), HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(0, 1), HexFrame.Q_NEG)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(-1, 1), HexFrame.Q_POS)),
            PipeCoord(qneg, VertexCoord(tile + TileCoord(1, 0), HexFrame.Q_NEG)),
        )

        @test get_pipe_segments(qpos) == expected_qpos
        @test get_pipe_segments(qneg) == expected_qneg
        @test length(Set(get_pipe_segments(qpos))) == 12
        @test length(Set(get_pipe_segments(qneg))) == 12
        @test all(pipe_has_proper_vertices, get_pipe_segments(qpos))
        @test all(is_valid_pipe_segment, get_pipe_segments(qpos))
        @test count(is_side_span, get_pipe_segments(qpos)) == 3
        @test count(is_short_diagonal_span, get_pipe_segments(qpos)) == 6
        @test count(is_long_diagonal_span, get_pipe_segments(qpos)) == 3

        source = to_proper(qpos)
        @test all(pipe -> source in (pipe.v1, pipe.v2), get_pipe_segments(qpos))

        translated = get_pipe_segments(VertexCoord(TileCoord(4, -3), HexFrame.Q_POS))
        expected_translated = map(expected_qpos) do pipe
            PipeCoord(
                VertexCoord(pipe.v1.tile + TileCoord(4, -3), pipe.v1.dir),
                VertexCoord(pipe.v2.tile + TileCoord(4, -3), pipe.v2.dir),
            )
        end
        @test translated == Tuple(expected_translated)

        tile_segments = get_pipe_segments(tile)
        expected_tile_segments = (
            PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.R_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.R_NEG), VertexCoord(tile, HexFrame.S_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.S_POS), VertexCoord(tile, HexFrame.Q_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.Q_NEG), VertexCoord(tile, HexFrame.R_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.R_POS), VertexCoord(tile, HexFrame.S_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.S_NEG), VertexCoord(tile, HexFrame.Q_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.S_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.R_NEG), VertexCoord(tile, HexFrame.Q_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.S_POS), VertexCoord(tile, HexFrame.R_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.Q_NEG), VertexCoord(tile, HexFrame.S_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.R_POS), VertexCoord(tile, HexFrame.Q_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.S_NEG), VertexCoord(tile, HexFrame.R_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.Q_NEG)),
            PipeCoord(VertexCoord(tile, HexFrame.R_NEG), VertexCoord(tile, HexFrame.R_POS)),
            PipeCoord(VertexCoord(tile, HexFrame.S_POS), VertexCoord(tile, HexFrame.S_NEG)),
        )
        @test tile_segments == expected_tile_segments
        @test length(Set(tile_segments)) == 15
        @test all(pipe_has_proper_vertices, tile_segments)
        @test all(is_side_span, tile_segments[1:6])
        @test all(is_short_diagonal_span, tile_segments[7:12])
        @test all(is_long_diagonal_span, tile_segments[13:15])
        @test all(pipe -> get_tile_containing_pipe(pipe) == tile, tile_segments[7:15])
        @test get_side_pipes(tile) == tile_segments[1:6]
    end

    @testset "Pipe stacking ranks" begin
        tile = TileCoord(0, 0)
        tile_segments = get_pipe_segments(tile)
        expected_ranks = (7, 7, 7, 7, 7, 7, 4, 5, 6, 4, 5, 6, 1, 2, 3)

        @test get_stacking_rank.(tile_segments) == expected_ranks
        @test get_stacking_rank.(get_pipe_segments(TileCoord(4, -3))) == expected_ranks

        @test length(Set(get_stacking_rank.(tile_segments[1:6]))) == 1
        @test get_stacking_rank(tile_segments[7]) == get_stacking_rank(tile_segments[10])
        @test get_stacking_rank(tile_segments[8]) == get_stacking_rank(tile_segments[11])
        @test get_stacking_rank(tile_segments[9]) == get_stacking_rank(tile_segments[12])
        @test length(Set(get_stacking_rank.(tile_segments[7:12]))) == 3
        @test length(Set(get_stacking_rank.(tile_segments[13:15]))) == 3

        @test has_higher_stacking_rank(tile_segments[1], tile_segments[13])
        @test has_higher_stacking_rank(tile_segments[7], tile_segments[13])
        @test !has_higher_stacking_rank(tile_segments[13], tile_segments[7])
        @test !has_higher_stacking_rank(tile_segments[7], tile_segments[10])
    end

    @testset "Pipe segment selection helpers" begin
        tile = TileCoord(0, 0)

        for vertex in (VertexCoord(tile, axis) for axis in instances(HexFrame.HexAxis))
            proper_vertex = to_proper(vertex)
            vertex_cart = to_cartesian(proper_vertex)
            @test closest_vertex(vertex_cart) == proper_vertex
            @test closest_vertex(CartesianCoord(vertex_cart.x * 0.98, vertex_cart.y * 0.98)) == proper_vertex
        end

        for source in (VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.Q_NEG))
            proper_source = to_proper(source)
            source_cart = to_cartesian(proper_source)
            candidates = get_pipe_segments(proper_source)

            @test nearest_pipe_segment_from_vertex(proper_source, source_cart) == first(candidates)

            for candidate in candidates
                far_vertex = candidate.v1 == proper_source ? candidate.v2 : candidate.v1
                far_cart = to_cartesian(far_vertex)
                direction = far_cart - source_cart
                test_point = CartesianCoord(source_cart.x + direction.x * 10.0, source_cart.y + direction.y * 10.0)
                @test nearest_pipe_segment_from_vertex(proper_source, test_point) == candidate
            end

            short_candidate = first(filter(is_short_diagonal_span, candidates))
            short_far = short_candidate.v1 == proper_source ? short_candidate.v2 : short_candidate.v1
            short_vec = to_cartesian(short_far) - source_cart
            short_point = CartesianCoord(source_cart.x + short_vec.x * 0.1, source_cart.y + short_vec.y * 0.1)
            @test nearest_pipe_segment_from_vertex(proper_source, short_point) == short_candidate
        end
    end

    @testset "side pipe helper regression" begin
        tile = TileCoord(0, 0)
        @test length(get_side_pipes(tile)) == 6
        @test all(pipe -> pipe_span_class(pipe) === SIDE_SPAN, get_side_pipes(tile))
        @test length(get_side_pipes(VertexCoord(tile, HexFrame.Q_POS))) == 3
        @test all(pipe -> pipe_span_class(pipe) === SIDE_SPAN, get_side_pipes(VertexCoord(tile, HexFrame.Q_POS)))
        @test round_to_side_pipe(CartesianCoord(0, 0.2)) in get_side_pipes(tile)
    end


    @testset "rotate HexAxis" begin
        @test rotate(HexFrame.Q_POS, HexFrame.R_POS) == HexFrame.R_POS
        @test rotate(HexFrame.R_NEG, HexFrame.S_POS) == HexFrame.Q_NEG
        @test rotate(HexFrame.S_NEG, HexFrame.Q_NEG) == HexFrame.S_POS
    end

    @testset "mirror_q_axis" begin
        @test mirror_q_axis(HexFrame.Q_POS) == HexFrame.Q_POS
        @test mirror_q_axis(HexFrame.R_NEG) == HexFrame.S_NEG
        @test mirror_q_axis(HexFrame.S_POS) == HexFrame.R_POS
        @test mirror_q_axis(HexFrame.Q_NEG) == HexFrame.Q_NEG
        @test mirror_q_axis(HexFrame.R_POS) == HexFrame.S_POS
        @test mirror_q_axis(HexFrame.S_NEG) == HexFrame.R_NEG
    end

    @testset "transform_tile_axis" begin
        @test transform_tile_axis(HexFrame.R_NEG, HexFrame.Q_POS, true) == HexFrame.S_NEG
        @test transform_tile_axis(HexFrame.S_POS, HexFrame.R_POS, true) == HexFrame.S_POS
        @test transform_tile_axis(HexFrame.S_NEG, HexFrame.R_NEG, false) == rotate(HexFrame.S_NEG, HexFrame.R_NEG)
    end

    @testset "tile_orientation_matrix" begin
        @test tile_orientation_matrix(HexFrame.Q_POS, true) == HexFrame.mirror_q_mat
    end


end
