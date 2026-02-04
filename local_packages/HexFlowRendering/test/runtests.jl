using Test
using HexFrame
using FlowMap
using FlowEngine
using HexFlowRendering
using RenderEngine
using StaticArrays
using HexComponentsAPI

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

tile_particle_spawn!(pm, GLObjectMap(), gm, DerivedMapState(), MNA_State(), gamestate)

# Count total particles across groups
total = sum(length(g.particles) for g in values(pm.groups))
@test total == 2

println("HexFlowRendering Phase4 tests passed")

# -----------------------------
# Test: fractional render offset culling
# -----------------------------
# Primary ship with a fractional render offset
gm2 = GameMap()
set_surface_tile!(gm2, TileCoord(0,0))
# Set docking status so the ship has a fractional render offset for rendering tests
FlowMap.set_docking_status!(get_ship(gm2, :primary), FlowMap.ApproachingDockStat(HexFrame.AxialCoord(0.3, 0.0), HexFrame.AxialCoord(0.3, 0.0), 1.0, HexFrame.Q_POS))

pm = ParticleManager()
colour = SVector{4, Float32}(1.0f0, 1.0f0, 1.0f0, 1.0f0)

# Spawn a particle at the world-space position corresponding to the tile + fractional offset.
pos = glvec(TileCoord(0,0)) .+ glvec(get_ship_render_offset(gm2, :primary))
spawn_particles!(pm, [pos], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group = pm.groups[colour]

bottom_left = SVector(-1000.0f0, -1000.0f0)
top_right = SVector(1000.0f0, 1000.0f0)

visible = HexFlowRendering.cull_particles_to_buffer!(pm, group, bottom_left, top_right, time(), 60.0, gm2)
@test visible == 0  # Particle should be culled as it's behind the visually-offset ship

# Spawn a particle at a distant tile; it should NOT be culled
pm2 = ParticleManager()
pos2 = glvec(TileCoord(10,10))
spawn_particles!(pm2, [pos2], [SVector{2, Float64}(0.0,0.0)], 0, 10; colour = colour)
group2 = pm2.groups[colour]
visible2 = HexFlowRendering.cull_particles_to_buffer!(pm2, group2, bottom_left, top_right, time(), 60.0, gm2)
@test visible2 == 1

println("HexFlowRendering fractional offset culling tests passed")
