"""
    mapgen_coldgasthrusters()

Cold gas thruster control tutorial demonstrating switched nozzle systems.

This map teaches:
- Using SwitchedNozzleCompBehav for controllable thrust
- Multiple switched nozzles with independent control
- Creating an RCS (Reaction Control System) setup
- Proper rotation alignment for directional control
- The `connected_node` parameter determines which external node connects to the system
"""
function mapgen_coldgasthrusters()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()

    # Create a gas tank for the thruster system
    gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )
    components[TileCoord(0, 0)] = ComponentOnTile(gas_tank, HexFrame.Q_NEG)

    # Create three separate switched nozzles for RCS control
    # Each nozzle must be a separate instance to maintain independent state
    # connected_node is HexFrame.NODE_Q_POS (the external connection point)

    # Nozzle 1: Positioned at (4, -5) with R_NEG rotation
    switched_nozzle_1 = SwitchedNozzleCompBehav(
        throat_area = Float64(0.1f0),  # Float32 -> Float64 to match saved precision
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        change_rate = Float64(0.1f0)
    )
    components[TileCoord(4, -5)] = ComponentOnTile(switched_nozzle_1, HexFrame.R_NEG)

    # Nozzle 2: Positioned at (4, -7) with S_NEG rotation
    switched_nozzle_2 = SwitchedNozzleCompBehav(
        throat_area = Float64(0.1f0),  # Float32 -> Float64 to match saved precision
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        change_rate = Float64(0.1f0)
    )
    components[TileCoord(4, -7)] = ComponentOnTile(switched_nozzle_2, HexFrame.S_NEG)

    # Nozzle 3: Positioned at (6, -7) with Q_NEG rotation
    switched_nozzle_3 = SwitchedNozzleCompBehav(
        throat_area = Float64(0.1f0),  # Float32 -> Float64 to match saved precision
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        change_rate = Float64(0.1f0)
    )
    components[TileCoord(6, -7)] = ComponentOnTile(switched_nozzle_3, HexFrame.Q_NEG)

    # Define ship surface
    surface = Set(
        [
            TileCoord(1, -1),
            TileCoord(5, -6),
            TileCoord(-1, 0),
            TileCoord(0, -1),
            TileCoord(0, 1),
            TileCoord(4, -6),
            TileCoord(5, -7),
            TileCoord(-1, 1),
            TileCoord(1, 0),
            TileCoord(0, 0),
        ]
    )

    set_component!(ship, components)
    set_surface_tile!(ship, surface)

    return GameMap(ship)
end
