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
sec = ShipMap()
set_surface_tile!(sec, TileCoord(5, 0))
add_ship!(gm, :sec, sec)

combined = get_all_surfaces_combined(gm)
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
set_component!(gm, TileCoord(10,0), ComponentOnTile(DummyParticleComp(), HexFrame.Q_POS))
# Secondary
set_component!(gm, TileCoord(20,0), ComponentOnTile(DummyParticleComp(), HexFrame.Q_POS); ship_name = :sec)

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
FlowMap.set_docking_status!(get_ship(gm2, :primary), FlowMap.ApproachingDockStat(HexFrame.AxialCoord(0.3, 0.0), HexFrame.AxialCoord(0.3, 0.0), 1.0))

pm = ParticleManager()
colour = SVector{4, Float32}(1.0f0, 1.0f0, 1.0f0, 1.0f0)

# Spawn a particle at the world-space position corresponding to the tile + fractional offset.
pos = glvec(TileCoord(0,0)) .+ glvec(get_ship_render_offset(gm2, :primary))
spawn_particles!(pm, [pos], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group = pm.groups[colour]

bottom_left = SVector(-1000.0f0, -1000.0f0)
top_right = SVector(1000.0f0, 1000.0f0)

visible = HexFlowRendering.cull_particles_to_buffer!(pm, group, bottom_left, top_right, time(), BASE_UPS, gm2)
@test visible == 0  # Particle should be culled as it's behind the visually-offset ship

# Spawn a particle at a distant tile; it should NOT be culled
pm2 = ParticleManager()
pos2 = glvec(TileCoord(10,10))
spawn_particles!(pm2, [pos2], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group2 = pm2.groups[colour]
visible2 = HexFlowRendering.cull_particles_to_buffer!(pm2, group2, bottom_left, top_right, time(), BASE_UPS, gm2)
@test visible2 == 1

println("HexFlowRendering fractional offset culling tests passed")

# ===============================================================
# Catch-up particle spawning (missed ticks / sim speed > 1x)
# ===============================================================

@testset "tile_particle_spawn! catch-up spawns and pre-advances" begin
    # Build a minimal map with one DummyParticleComp on a single-tile ship
    gm_catchup = GameMap()
    set_surface_tile!(gm_catchup, TileCoord(0, 0))
    set_component!(gm_catchup, TileCoord(0, 0), ComponentOnTile(DummyParticleComp(), HexFrame.Q_POS))

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
