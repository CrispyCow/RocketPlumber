"""
    mapgen_basicplumbing()

Basic plumbing tutorial map demonstrating a simple cold gas system.

This map teaches:
- Basic gas tank setup with a ThevininTank
- Direct nozzle connection for thrust generation
- Simple ship surface definition
"""
function mapgen_basicplumbing()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()

    # Create a tri-gas tank with cold gas
    gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # Create a small nozzle for thrust
    nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = Float64(0.3f0),  # Float32 -> Float64 to match saved precision
        sprite = Symbol("AllNozzles_SmallNozzle")
    )

    # Place components on ship
    components[TileCoord(2, -1)] = ComponentOnTile(gas_tank, HexFrame.R_NEG)
    components[TileCoord(-4, 2)] = ComponentOnTile(nozzle, HexFrame.Q_POS)

    # Define ship surface
    surface = Set(
        [
            TileCoord(1, -1),
            TileCoord(-1, 0),
            TileCoord(2, -1),
            TileCoord(-1, 1),
            TileCoord(-3, 2),
            TileCoord(1, 0),
            TileCoord(-3, 1),
            TileCoord(-2, 1),
            TileCoord(0, 0),
        ]
    )

    set_component!(ship, components)
    set_surface_tile!(ship, surface)

    return GameMap(ship)
end
