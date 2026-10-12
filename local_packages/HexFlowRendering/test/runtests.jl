#=
Scope: Test suite for HexFlowRendering render programs, sprites, pipes, particles,
and render-height conventions
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexFrame
using FlowMap
using FlowEngine
using HexFlowRendering
using RelocatableFolders
using RenderEngine
using StaticArrays
using HexComponentsAPI
using HexFlowControl

@testset "Texture atlas PNG loading" begin
    shader_dir = HexFlowRendering.shader_dir()
    atlas_dir = HexFlowRendering.texture_atlas_dir()

    @test HexFlowRendering.SHADER_DIR isa RelocatableFolders.Path
    @test HexFlowRendering.TEXTURE_ATLAS_DIR isa RelocatableFolders.Path
    @test isdir(shader_dir)
    @test all(
        isfile(joinpath(shader_dir, name)) for name in (
                "BaseTile.vert",
                "BaseTile.frag",
                "BaseTile_GasEffect.frag",
                "BaseTile_LiquidEffect.frag",
                "particle.vert",
                "particle.geom",
                "particle.frag",
            )
    )
    @test isfile(joinpath(HexFlowRendering.shader_dir(), "BaseTile.vert"))
    @test occursin("#version 410", HexFlowRendering.grab_shader("BaseTile.vert"))
    @test isdir(atlas_dir)
    @test isfile(joinpath(atlas_dir, "TileTextureAtlas1.png"))
    @test isfile(joinpath(atlas_dir, "TileTextureAtlas1.json"))

    atlas_image = HexFlowRendering.load_texatlas1_png()

    @test ndims(atlas_image) == 2
    @test !isempty(atlas_image)
end

# Test combined surface retrieval
gm = GameMap()
set_surface_tile!(gm, TileCoord(0, 0))
sec = ShipState()
add_ship!(gm, :sec, sec)
set_surface_tile!(gm, TileCoord(5, 0); ship_name = :sec)

combined = collect_surface_tiles!(Set{TileCoord}(), gm)
@test TileCoord(0, 0) in combined
@test TileCoord(5, 0) in combined

include("particles.jl")

struct TestPipeRenderBehav <: PipeBehavior end

import HexComponentsAPI: render_pipe_map!, render_pipe_base!, get_pipe_click_radius

get_pipe_click_radius(::TestPipeRenderBehav) = 0.1

function _test_pipe_sprite(position::PipeCoord)::Symbol
    span_class = pipe_span_class(position)
    if span_class === SIDE_SPAN
        return :TestPipe_Side
    elseif span_class === SHORT_DIAGONAL_SPAN
        return :TestPipe_ShortDiagonal
    elseif span_class === LONG_DIAGONAL_SPAN
        return :TestPipe_LongDiagonal
    else
        error("unknown pipe span class")
    end
end

function _test_pipe_sprite_height(position::PipeCoord, render_height_offset::Integer)::Int32
    return Int32(get_stacking_rank(position)) * HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER +
        Int32(1) + Int32(render_height_offset)
end

function render_pipe_map!(queue::AbstractVector, ::TestPipeRenderBehav; glmap::GLObjectMap, rotation::HexAxis, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    position isa PipeCoord || error("pipe_queued_render! should pass PipeCoord, got $(typeof(position))")

    push!(
        queue,
        render_basic_pipe(
            glmap, _test_pipe_sprite(position), position;
            pos_offset = pos_offset,
            draw_height = _test_pipe_sprite_height(position, render_height_offset),
        )
    )
    return nothing
end

function render_pipe_base!(
        queue::AbstractVector, ::TestPipeRenderBehav;
        glmap::GLObjectMap,
        rotation::HexAxis,
        position,
        pos_offset = nothing,
        transparency::Float64 = 1.0,
        colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0),
        render_height_offset::Integer = 0,
        kwargs...
    )
    position isa PipeCoord || error("render_pipe_base! should be called with a PipeCoord, got $(typeof(position))")

    push!(
        queue,
        render_basic_pipe(
            glmap, _test_pipe_sprite(position), position;
            pos_offset = pos_offset,
            transparency = transparency,
            colour = colour,
            draw_height = _test_pipe_sprite_height(position, render_height_offset),
        )
    )
    return nothing
end

function _mock_pipe_glmap()
    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))

    for sprite in (:TestPipe_Side, :TestPipe_ShortDiagonal, :TestPipe_LongDiagonal)
        glmap.sprites[sprite] = GLspriteData(
            :TestAtlas,
            SVector{2, Float32}(0.1f0, 0.1f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
            SVector{2, Float32}(256.0f0, 64.0f0),
            SVector{2, Float32}(256.0f0, 64.0f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
        )
    end

    return glmap
end

function _mock_sprite_glmap()
    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    glmap.sprites[:TestSprite] = GLspriteData(
        :TestAtlas,
        SVector{2, Float32}(0.1f0, 0.2f0),
        SVector{2, Float32}(0.3f0, 0.4f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(128.0f0, 128.0f0),
        SVector{2, Float32}(64.0f0, 32.0f0),
    )
    return glmap
end

@testset "sprite clipping uniforms" begin
    glmap = _mock_sprite_glmap()
    rotation = rotmat_2D(0.0)
    position = TileCoord(0, 0)

    default_uniforms = setup_basesprite_uniforms(glmap, :TestSprite, rotation, glvec(position))
    @test default_uniforms.unclipped_texcoord == SVector{2, Float32}(1.0f0, 1.0f0)

    requested_texcoord = SVector(0.25, 0.75)
    base_uniforms = setup_basesprite_uniforms(glmap, :TestSprite, rotation, glvec(position); unclipped_texcoord = requested_texcoord)
    @test base_uniforms.unclipped_texcoord == SVector{2, Float32}(0.25f0, 0.75f0)

    basic_command = render_basic_sprite(glmap, :TestSprite, rotation, position; unclipped_texcoord = requested_texcoord)
    @test basic_command.uniforms.unclipped_texcoord == SVector{2, Float32}(0.25f0, 0.75f0)

    liquid_command = render_liquid_sprite(glmap, :TestSprite, rotation, position; gameticks = 1, unclipped_texcoord = requested_texcoord)
    @test liquid_command.uniforms.unclipped_texcoord == SVector{2, Float32}(0.25f0, 0.75f0)

    gas_command = render_gas_sprite(glmap, :TestSprite, rotation, position; gameticks = 1, unclipped_texcoord = requested_texcoord)
    @test gas_command.uniforms.unclipped_texcoord == SVector{2, Float32}(0.25f0, 0.75f0)
end

@testset "pipe_queued_render! renders every PipeCoord span class" begin
    gm_pipes = GameMap()
    test_pipe = TestPipeRenderBehav()

    pipes = collect(get_pipe_segments(TileCoord(0, 0)))
    side_pipe = first(filter(p -> pipe_span_class(p) === SIDE_SPAN, pipes))
    short_pipe = first(filter(p -> pipe_span_class(p) === SHORT_DIAGONAL_SPAN, pipes))
    long_pipe = first(filter(p -> pipe_span_class(p) === LONG_DIAGONAL_SPAN, pipes))

    set_pipe!(gm_pipes, side_pipe, test_pipe)
    set_pipe!(gm_pipes, short_pipe, test_pipe)
    set_pipe!(gm_pipes, long_pipe, test_pipe)

    queue = SpriteRenderCommand[]
    pipe_queued_render!(queue, _mock_pipe_glmap(), gm_pipes, DerivedMapState(), HexFlowControl.GameState(ticks = 1))

    @test length(queue) == 3
    @test Set(command.uniforms.object_translation for command in queue) == Set(glvec(pipe) for pipe in (side_pipe, short_pipe, long_pipe))
    @test length(Set(command.uniforms.object_rotation for command in queue)) >= 2
    @test Set(command.draw_height for command in queue) == Set(_test_pipe_sprite_height(pipe, 0) for pipe in (side_pipe, short_pipe, long_pipe))
end
