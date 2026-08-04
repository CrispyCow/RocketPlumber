using Test
using HexFrame
using FlowMap
using FlowEngine
using HexFlowRendering
using RenderEngine
using StaticArrays
using HexComponentsAPI

@testset "Texture atlas PNG loading" begin
    texture_atlas_dir = joinpath(dirname(dirname(pkgdir(HexFlowRendering))), "tools", "TexturePacker", "outputs")
    atlas_image = HexFlowRendering.load_texatlas1_png(texture_atlas_dir)

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
@test TileCoord(0,0) in combined
@test TileCoord(5,0) in combined

# Test that tile_particle_spawn! invokes collect_effect_particles! for components on all ships
# Define a dummy component that spawns a single particle at its tile when collect_effect_particles! is called
struct DummyParticleComp <: ComponentBehavior end
import HexComponentsAPI: collect_effect_particles!

function collect_effect_particles!(manager::ParticleManager, ::DummyParticleComp; kwargs...)
    # Extract tile and gameticks from kwargs
    tile = haskey(kwargs, :tile) ? kwargs[:tile] : TileCoord(0,0)
    gameticks = haskey(kwargs, :gameticks) ? kwargs[:gameticks] : 0

    pos = glvec(tile)
    spawn_particles!(manager, [pos], [SVector{2, Float64}(0.0, 0.0)], gameticks, gameticks + 1; colour = SVector{4, Float32}(1.0f0, 1.0f0, 1.0f0, 1.0f0))
    return nothing
end

pm = ParticleManager()
# Primary
set_component!(gm, TileCoord(10,0), PlacedComponent(DummyParticleComp(), HexFrame.Q_POS, :primary))
# Secondary
set_component!(gm, TileCoord(20,0), PlacedComponent(DummyParticleComp(), HexFrame.Q_POS, :sec))

using HexFlowControl

# Simple GameState for test
gamestate = HexFlowControl.GameState(ticks = 42)

tile_particle_spawn!(pm, GLObjectMap(), gm, DerivedMapState(), MNA_StateSnapshot(), gamestate)

# Count total particles across groups
total = sum(length(g.particles) for g in values(pm.groups))
@test total == 2

println("HexFlowRendering Phase4 tests passed")

@testset "Particle physics updates positions without temp arrays" begin
    colour = SVector{4, Float32}(1.0f0, 0.5f0, 0.25f0, 1.0f0)
    group = create_particle_group(colour, 5.0f0)
    spawn_particles!(group, [SVector{2, Float32}(1.0f0, 2.0f0)], [SVector{2, Float64}(0.5, -1.0)], 0, 10)

    old_scale = get_particle_accel_scale()
    try
        set_particle_accel_scale!(1.0)

        state = HexFlowControl.GameState(
            ticks = 5,
            acceleration_ship_frame = SVector{2, Float64}(1.0, -2.0)
        )

        update_particle_physics!(group, state; base_ups = 2.0, delta_ticks = 2)

        @test group.particles.velocity[1] == SVector{2, Float64}(-0.5, -3.0)
        @test group.particles.position[1] == SVector{2, Float32}(0.0f0, -4.0f0)
    finally
        set_particle_accel_scale!(old_scale)
    end
end

@testset "Particle culling interpolates into the buffer" begin
    colour = SVector{4, Float32}(0.25f0, 0.5f0, 1.0f0, 1.0f0)
    manager = ParticleManager()
    spawn_particles!(manager, [SVector{2, Float32}(1.0f0, 2.0f0)], [SVector{2, Float64}(3.0, -4.0)], 0, 10; colour = colour)
    group = manager.groups[colour]

    visible = HexFlowRendering.cull_particles_to_buffer!(
        manager,
        group,
        SVector(-1000.0f0, -1000.0f0),
        SVector(1000.0f0, 1000.0f0),
        time() - 10.0,
        BASE_UPS,
        nothing
    )

    @test visible == 1
    @test manager.cull_buffer[1] == SVector{2, Float32}(4.0f0, -2.0f0)
end

# -----------------------------
# Test: fractional render offset culling
# -----------------------------
# Primary ship with a fractional render offset
gm2 = GameMap()
set_surface_tile!(gm2, TileCoord(0,0))
# Set docking status so the ship has a fractional render offset for rendering tests
FlowMap.set_docking_status!(gm2, :primary, FlowMap.ApproachingDockStat(HexFrame.AxialCoord(0.3, 0.0), HexFrame.AxialCoord(0.3, 0.0), 1.0))

pm = ParticleManager()
colour = SVector{4, Float32}(1.0f0, 1.0f0, 1.0f0, 1.0f0)

# Spawn a particle at the world-space position corresponding to the tile + fractional offset.
pos = glvec(TileCoord(0,0)) .+ glvec(get_ship_render_offset(gm2, :primary))
spawn_particles!(pm, [pos], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group = pm.groups[colour]

bottom_left = SVector(-1000.0f0, -1000.0f0)
top_right = SVector(1000.0f0, 1000.0f0)

visible = HexFlowRendering.cull_particles_to_buffer!(pm, group, bottom_left, top_right, time(), BASE_UPS, gm2)
@test visible == 1  # Moving ships no longer cull background particles

# Spawn a particle at a stationary ship tile; it should be culled
gm3 = GameMap()
set_surface_tile!(gm3, TileCoord(0,0))
pm_stationary = ParticleManager()
stationary_pos = glvec(TileCoord(0,0))
spawn_particles!(pm_stationary, [stationary_pos], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group_stationary = pm_stationary.groups[colour]
visible_stationary = HexFlowRendering.cull_particles_to_buffer!(pm_stationary, group_stationary, bottom_left, top_right, time(), BASE_UPS, gm3)
@test visible_stationary == 0

# Spawn a particle at a distant tile; it should NOT be culled
pm2 = ParticleManager()
pos2 = glvec(TileCoord(10,10))
spawn_particles!(pm2, [pos2], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group2 = pm2.groups[colour]
visible2 = HexFlowRendering.cull_particles_to_buffer!(pm2, group2, bottom_left, top_right, time(), BASE_UPS, gm2)
@test visible2 == 1

# Multi-ship: stationary tiles cull, moving tiles do not
gm4 = GameMap()
set_surface_tile!(gm4, TileCoord(0,0))
add_ship!(gm4, :moving, ShipState(docking_status = FlowMap.ApproachingDockStat(HexFrame.AxialCoord(0.2, 0.0), HexFrame.AxialCoord(0.2, 0.0), 1.0)))
set_surface_tile!(gm4, TileCoord(5,0); ship_name = :moving)

pm4 = ParticleManager()
spawn_particles!(pm4, [glvec(TileCoord(0,0)), glvec(TileCoord(5,0))], [SVector{2, Float64}(0.0,0.0), SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group4 = pm4.groups[colour]
visible4 = HexFlowRendering.cull_particles_to_buffer!(pm4, group4, bottom_left, top_right, time(), BASE_UPS, gm4)
@test visible4 == 1

@testset "thrust_dust_particle_effect! spawns on multiple ships" begin
    gm_dust = GameMap()
    set_surface_tile!(gm_dust, TileCoord(0, 0))
    add_ship!(gm_dust, :sec, ShipState())
    set_surface_tile!(gm_dust, TileCoord(5, 0); ship_name = :sec)

    pm_dust = ParticleManager()
    dust_state = HexFlowControl.GameState(ticks = 7)
    thrust_dust_particle_effect!(pm_dust, dust_state, gm_dust; num_particles_per_tile = 1)

    total_dust = sum(length(g.particles) for g in values(pm_dust.groups))
    @test total_dust == 2
end

println("HexFlowRendering fractional offset culling tests passed")

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

# ===============================================================
# Catch-up particle spawning (missed ticks / sim speed > 1x)
# ===============================================================

@testset "tile_particle_spawn! catch-up spawns and pre-advances" begin
    # Build a minimal map with one DummyParticleComp on a single-tile ship
    gm_catchup = GameMap()
    set_surface_tile!(gm_catchup, TileCoord(0, 0))
    set_component!(gm_catchup, TileCoord(0, 0), PlacedComponent(DummyParticleComp(), HexFrame.Q_POS, :primary))

    pm_catchup = ParticleManager()

    # First call at tick 10 -- initialises last_spawn_tick → 9, spawns for tick 10 only
    gs1 = HexFlowControl.GameState(ticks = 10)
    tile_particle_spawn!(pm_catchup, GLObjectMap(), gm_catchup, DerivedMapState(), MNA_StateSnapshot(), gs1)

    total_after_first = sum(length(g.particles) for g in values(pm_catchup.groups))
    @test total_after_first == 1  # one DummyParticleComp → 1 particle for tick 10

    # Jump to tick 13 -- missed ticks = 13 - 10 - 1 = 2, so ticks_to_spawn = 3 (ticks 13, 12, 11)
    gs2 = HexFlowControl.GameState(ticks = 13)
    tile_particle_spawn!(pm_catchup, GLObjectMap(), gm_catchup, DerivedMapState(), MNA_StateSnapshot(), gs2)

    total_after_catchup = sum(length(g.particles) for g in values(pm_catchup.groups))
    @test total_after_catchup == 4  # 1 original + 3 new (current + 2 catch-up)
end

@testset "tile_particle_spawn! catch-up pre-advances backdated particles" begin
    # DummyParticleComp spawns with velocity (0,0), so pre-advance is a no-op for position.
    # Define a component that spawns with a known velocity to verify pre-advancement.
    # We use the existing DummyParticleComp but manually test _pre_advance_catchup_particles!

    colour = SVector{4, Float32}(0.8f0, 0.2f0, 0.3f0, 1.0f0)
    pm_pre = ParticleManager()

    # Create a group and spawn a particle with known velocity
    vel = SVector{2, Float64}(0.5, -1.0)
    pos = SVector{2, Float32}(10.0f0, 20.0f0)
    spawn_particles!(pm_pre, [pos], [vel], Int64(5), Int64(15); colour = colour)

    # Record counts before spawning catch-up particles
    prev_counts = Dict{SVector{4, Float32}, Int}(
        c => length(g.particles) for (c, g) in pm_pre.groups
    )

    # Spawn a "backdated" particle (simulating what collect_effect_particles! would do)
    backdate_pos = SVector{2, Float32}(0.0f0, 0.0f0)
    backdate_vel = SVector{2, Float64}(1.0, 2.0)
    spawn_particles!(pm_pre, [backdate_pos], [backdate_vel], Int64(3), Int64(13); colour = colour)

    # Pre-advance by 2 ticks
    HexFlowRendering._pre_advance_catchup_particles!(pm_pre, prev_counts, 2)

    group = pm_pre.groups[colour]
    # First particle (index 1) should be untouched -- it existed before the snapshot
    @test group.particles.position[1] == pos
    # Second particle (index 2) should be pre-advanced: (0,0) + (1,2)*2 = (2,4)
    @test group.particles.position[2] == SVector{2, Float32}(2.0f0, 4.0f0)
end

println("HexFlowRendering catch-up particle tests passed")
