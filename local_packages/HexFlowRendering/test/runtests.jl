using Test
using HexFrame
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
