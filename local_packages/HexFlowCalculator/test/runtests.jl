using Test
using HexFlowCalculator
using FlowEngine
using HexFrame
using HexFlowNozzleComponents
using HexFlowSwitchComponents

# Minimal threadsafe console push
function silent_console(msg::String)
    # no-op
end

# Test that automatic routing selects the correct ship based on surface and placement rules
@testset "HexFlowCalculator Command Ship Routing" begin
    cq = create_command_queue(8)

    # minimal component
    sample_comp = BigAdjustableValveCompBehav(max_conductance = 2.0, min_conductance = 0.0, percentage_step_size = 0.05, change_rate = 0.25/60)

    # Create gamemap with two ships
    primary = ShipMap()
    secondary = ShipMap()
    # Offset secondary ship to avoid accidental overlap in tests
    offset_ship!(secondary, HexFrame.TileCoord(20, 0))
    gamemap = GameMap(ships = Dict(:primary => primary, :asteroid => secondary))

    # Ensure the tile is surface on the asteroid ship by directly setting it, then place a tile
    set_surface_tile!(gamemap, TileCoord(1,1); ship_name = :asteroid)
    @test is_on_surface_tile(TileCoord(1,1), gamemap; ship_name = :asteroid)

    cmd_place = create_set_tile_command(cq, TileCoord(1,1), sample_comp, HexFrame.Q_POS)
    logs = String[]
    HexFlowCalculator.process_command!(cmd_place, gamemap, (m)->push!(logs, m))

    comp_primary = get_component(gamemap, TileCoord(1,1); ship_name = :primary)
    comp_secondary = get_component(gamemap, TileCoord(1,1); ship_name = :asteroid)

    if isnothing(comp_secondary)
        @info "Placement logs: " join(logs, " | ")
    end

    @test isnothing(comp_primary)
    @test !isnothing(comp_secondary)

    # Move the component within the asteroid ship
    # Ensure destination is a surface tile before moving
    set_surface_tile!(gamemap, TileCoord(2,2); ship_name = :asteroid)
    cmd_move = create_move_command(cq, TileCoord(1,1), TileCoord(2,2), HexFrame.Q_POS)
    logs_move = String[]
    HexFlowCalculator.process_command!(cmd_move, gamemap, (m)->push!(logs_move, m))
    if isnothing(get_component(gamemap, TileCoord(2,2); ship_name = :asteroid))
        @info "Move logs: " join(logs_move, " | ")
    end

    @test isnothing(get_component(gamemap, TileCoord(1,1); ship_name = :asteroid))
    @test !isnothing(get_component(gamemap, TileCoord(2,2); ship_name = :asteroid))

    # Delete the tile on asteroid ship
    cmd_del = create_delete_command(cq, TileCoord(2,2))
    HexFlowCalculator.process_command!(cmd_del, gamemap, silent_console)

    @test isnothing(get_component(gamemap, TileCoord(2,2); ship_name = :asteroid))

    # Add and remove surface adjacent to primary ship origin using direct API (command API tested separately)
    set_surface_tile!(gamemap, TileCoord(0,1); ship_name = :primary)
    @test is_on_surface_tile(TileCoord(0,1), gamemap; ship_name = :primary)

    delete_surface_tile!(get_ship(gamemap, :primary), TileCoord(0,1))
    @test !is_on_surface_tile(TileCoord(0,1), gamemap; ship_name = :primary)

    # Separate sanity test for command-based surface add/remove on a fresh two-ship map
    primary2 = ShipMap(); secondary2 = ShipMap(); offset_ship!(secondary2, TileCoord(20,0)); gm2 = GameMap(ships = Dict(:primary=>primary2, :asteroid=>secondary2));
    cmd_add2 = create_add_ship_surface_command(cq, TileCoord(0,1)); logs2 = String[]; HexFlowCalculator.process_command!(cmd_add2, gm2, (m)->push!(logs2, m)); @test any(contains.(logs2, "Surface added")); @test is_on_surface_tile(TileCoord(0,1), gm2; ship_name = :primary)
    cmd_rem2 = create_remove_ship_surface_command(cq, TileCoord(0,1)); logs3 = String[]; HexFlowCalculator.process_command!(cmd_rem2, gm2, (m)->push!(logs3, m)); @test any(contains.(logs3, "Surface removed") .| contains.(logs3, "removed")); @test !is_on_surface_tile(TileCoord(0,1), gm2; ship_name = :primary)

    # Click command on a non-existing tile should return no tile
    cmd_click = create_click_tile_command(cq, TileCoord(99,99), CartesianCoord(0.0,0.0))
    HexFlowCalculator.process_command!(cmd_click, gamemap, silent_console)

end
