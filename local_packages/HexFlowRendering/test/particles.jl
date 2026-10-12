#=
Scope: Particle physics, render-buffer preparation, and catch-up spawning tests
Formatter: Runic
=#

@testset "Particle physics and expiry" begin
    @test isbitstype(Particle)
    manager = ParticleManager(0.06f0)
    red = ColourType(1, 0, 0, 0.5)
    blue = ColourType(0, 0, 1, 0.25)
    position = SVector(1.0f0, 2.0f0)
    velocity = SVector(0.5, -1.0)
    spawn_particle!(manager, position, velocity, 5; colour = red)
    spawn_particles!(manager, [position], [velocity], 0, 10; colour = blue)
    spawn_particles!(manager, [position], [velocity], 0, 4; colour = red)
    spawn_particles!(manager, [position], [velocity], 0, 8; colour = red)

    old_scale = get_particle_accel_scale()
    try
        set_particle_accel_scale!(1.0)
        state = GameState(ticks = 3, acceleration_ship_frame = SVector(1.0, -2.0))
        original = copy(manager.particles)
        update_particle_physics!(manager, state; base_ups = 2.0)
        @test manager.particles == original # First update only initialises the tick boundary

        state.ticks = 5
        update_particle_physics!(manager, state; base_ups = 2.0)
        @test length(manager.particles) == 2 # Expiry is inclusive, including skipped ticks
        @test [p.velocity for p in manager.particles] == fill(SVector(-0.5, -3.0), 2)
        @test [p.position for p in manager.particles] == fill(SVector(0.0f0, -4.0f0), 2)
        @test [p.colour for p in manager.particles] == [blue, red]
        @test [p.vanishing_time for p in manager.particles] == [10, 8]

        updated = copy(manager.particles)
        update_particle_physics!(manager, state; base_ups = 2.0)
        @test manager.particles == updated # Repeated render frames do not advance physics
        state.ticks = 10
        update_particle_physics!(manager, state)
        @test isempty(manager.particles)
    finally
        set_particle_accel_scale!(old_scale)
    end
end

@testset "Particle interpolation and viewport colour alignment" begin
    manager = ParticleManager()
    red = ColourType(1, 0, 0, 0.5)
    blue = ColourType(0, 0, 1, 0.25)
    spawn_particles!(manager, [SVector(-2.0f0, 0.0f0)], [SVector(1.0, 0.0)], 0, 10; colour = red)
    spawn_particles!(manager, [SVector(0.0f0, 0.0f0)], [SVector(0.0, 2.0)], 0, 10; colour = blue)
    spawn_particles!(manager, [SVector(0.0f0, 0.0f0)], [SVector(1.0, -1.0)], 0, 10; colour = blue)
    spawn_particles!(manager, [SVector(0.0f0, 1.0f0)], [SVector(0.0, -1.0)], 0, 10; colour = red)
    original = copy(manager.particles)
    bounds = (SVector(-1.0f0, -1.0f0), SVector(1.0f0, 1.0f0))

    # A stale snapshot caps interpolation at one tick; culling uses the interpolated positions
    visible = HexFlowRendering.cull_particles_to_buffer!(manager, bounds..., time() - 10.0, BASE_UPS, nothing)
    expected = [SVector(-1.0f0, 0.0f0, red...), SVector(1.0f0, -1.0f0, blue...), SVector(0.0f0, 0.0f0, red...)]
    @test visible == 3
    @test manager.render_buffer == expected
    @test manager.particles == original

    # A future timestamp caps interpolation at zero, and the reused buffer shrinks correctly
    visible = HexFlowRendering.cull_particles_to_buffer!(manager, bounds..., time() + 10.0, BASE_UPS, nothing)
    @test visible == 3
    @test manager.render_buffer == [SVector(0.0f0, 0.0f0, blue...), SVector(0.0f0, 0.0f0, blue...), SVector(0.0f0, 1.0f0, red...)]
    @test HexFlowRendering.cull_particles_to_buffer!(manager, SVector(20.0f0, 20.0f0), SVector(21.0f0, 21.0f0), 0.0, BASE_UPS, nothing) == 0
    @test isempty(manager.render_buffer)
end

@testset "Stationary and moving ship surface culling" begin
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0))
    offset = AxialCoord(0.3, 0.0)
    add_ship!(gamemap, :moving, ShipState(docking_status = ApproachingDockStat(offset, offset, 1.0)))
    set_surface_tile!(gamemap, TileCoord(5, 0); ship_name = :moving)

    manager = ParticleManager()
    red = ColourType(1, 0, 0, 0.5)
    blue = ColourType(0, 0, 1, 0.25)
    stationary_pos = glvec(TileCoord(0, 0))
    moving_pos = glvec(TileCoord(5, 0)) + glvec(get_ship_render_offset(gamemap, :moving))
    distant_pos = glvec(TileCoord(10, 10))
    spawn_particles!(manager, [stationary_pos], [SVector(0.0, 0.0)], 0, 10; colour = red)
    spawn_particles!(manager, [moving_pos], [SVector(0.0, 0.0)], 0, 10; colour = blue)
    spawn_particles!(manager, [distant_pos], [SVector(0.0, 0.0)], 0, 10; colour = red)
    bounds = (SVector(-100.0f0, -100.0f0), SVector(100.0f0, 100.0f0))

    @test HexFlowRendering.cull_particles_to_buffer!(manager, bounds..., 0.0, BASE_UPS, gamemap) == 2
    @test manager.render_buffer == [SVector(moving_pos..., blue...), SVector(distant_pos..., red...)]
    @test HexFlowRendering.cull_particles_to_buffer!(manager, bounds..., 0.0, BASE_UPS, nothing) == 3
    @test first(manager.render_buffer) == SVector(stationary_pos..., red...)
end

struct TestParticleComp <: ComponentBehavior
    velocity::SVector{2, Float64}
    colour::ColourType
end

import HexComponentsAPI: collect_effect_particles!

function collect_effect_particles!(manager::ParticleManager, comp::TestParticleComp; tile::TileCoord, gameticks::Int64, kwargs...)
    spawn_particle!(manager, glvec(tile), comp.velocity, gameticks + 10; colour = comp.colour)
    return nothing
end

@testset "Foreground catch-up across ships and colours" begin
    gamemap = GameMap()
    add_ship!(gamemap, :sec, ShipState())
    tiles = (TileCoord(0, 0), TileCoord(5, 0))
    comps = (TestParticleComp(SVector(1.0, 2.0), ColourType(1, 0, 0, 0.5)), TestParticleComp(SVector(-0.5, 1.0), ColourType(0, 0, 1, 0.25)))
    for (tile, comp, ship) in zip(tiles, comps, (:primary, :sec))
        set_surface_tile!(gamemap, tile; ship_name = ship)
        set_component!(gamemap, tile, PlacedComponent(comp, HexFrame.Q_POS, ship))
    end
    manager = ParticleManager()
    glmap, derived, mna = GLObjectMap(), DerivedMapState(), MNA_StateSnapshot()
    state = GameState(ticks = 10)

    tile_particle_spawn!(manager, glmap, gamemap, derived, mna, state)
    @test length(manager.particles) == 2
    tile_particle_spawn!(manager, glmap, gamemap, derived, mna, state)
    @test length(manager.particles) == 2

    state.ticks = 13
    tile_particle_spawn!(manager, glmap, gamemap, derived, mna, state)
    @test length(manager.particles) == 8
    for (tile, comp) in zip(tiles, comps)
        particles = filter(p -> p.colour == comp.colour, manager.particles)
        pos = glvec(tile)
        @test [p.position for p in particles] == [pos, pos, SVector{2, Float32}(pos + comp.velocity), SVector{2, Float32}(pos + 2 * comp.velocity)]
        @test all(p -> p.velocity == comp.velocity, particles)
        @test [p.vanishing_time for p in particles] == [20, 23, 22, 21]
    end

    # Long pauses back-fill at most eight ticks per component
    state.ticks = 100
    tile_particle_spawn!(manager, glmap, gamemap, derived, mna, state)
    @test length(manager.particles) == 8 + 2 * 9
    @test minimum(p.vanishing_time for p in manager.particles[9:end]) == 102
end

@testset "Dust catch-up and ship offsets" begin
    gamemap = GameMap()
    tiles = (TileCoord(0, 0), TileCoord(5, 0))
    offset = AxialCoord(0.3, 0.0)
    add_ship!(gamemap, :sec, ShipState(docking_status = ApproachingDockStat(offset, offset, 1.0)))
    for (tile, ship) in zip(tiles, (:primary, :sec))
        set_surface_tile!(gamemap, tile; ship_name = ship)
    end
    # The primary ship has an interior tile, which must not emit dust
    for tile in get_adjacent_tiles_for_tile(first(tiles))
        set_surface_tile!(gamemap, tile)
    end
    derived = DerivedMapState()
    collect_surface_edge_tiles!(derived, gamemap)
    manager = ParticleManager(0.03f0)
    state = GameState(ticks = 7)
    colour = ColourType(0.5, 0.5, 0.5, 1)
    expected_positions = [glvec(tile) for tile in get_adjacent_tiles_for_tile(first(tiles))]
    push!(expected_positions, glvec(last(tiles)) + glvec(offset))
    batch_count = 2 * length(expected_positions)
    thrust_dust_particle_effect!(manager, state, gamemap, derived; num_particles_per_tile = 2)
    @test length(manager.particles) == batch_count
    @test Set(p.position for p in manager.particles) == Set(expected_positions)
    original = copy(manager.particles)
    thrust_dust_particle_effect!(manager, state, gamemap, derived; num_particles_per_tile = 2)
    @test manager.particles == original

    state.ticks = 10
    thrust_dust_particle_effect!(manager, state, gamemap, derived; num_particles_per_tile = 2)
    @test length(manager.particles) == 4 * batch_count
    @test manager.particles[1:batch_count] == original
    lifetime = Int(1.5 * BASE_UPS)
    @test [p.vanishing_time for p in manager.particles[(batch_count + 1):end]] == repeat([10, 9, 8] .+ lifetime; inner = batch_count)
    @test all(p -> p.colour == colour && all(abs.(p.velocity) .<= 0.1), manager.particles)
    for age in 1:2
        batch = manager.particles[((age + 1) * batch_count + 1):((age + 2) * batch_count)]
        spawn_positions = [p.position - SVector{2, Float32}(p.velocity * age) for p in batch]
        @test all(pos -> any(base -> isapprox(pos, base; atol = 1.0e-6), expected_positions), spawn_positions)
    end

    state.ticks = 100
    thrust_dust_particle_effect!(manager, state, gamemap, derived; num_particles_per_tile = 2)
    @test length(manager.particles) == (4 + 9) * batch_count
end
