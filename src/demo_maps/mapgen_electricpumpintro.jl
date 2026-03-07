"""
Electric Pump Introduction Tutorial Map

This tutorial demonstrates the electric pump component:
- A liquid tank stores monopropellant
- An electric pump (ElecTurboPump) transfers fluid to a decomposition chamber
- The decomp chamber converts liquid to pressurized gas
- Gas flows through pipes to a nozzle for thrust
- The electric pump uses stored energy to operate and can be switched on/off
"""
function mapgen_electricpumpintro()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()
    pipes = Dict{EdgeCoord, PipeBehavior}()

    # Create components with separate instances to avoid state sharing

    # Decomposition chamber at (-5, 0) - converts liquid to gas
    decomp_chamber = DecompChamberCompBehav()

    # Liquid tank at (-1, 0) - stores monopropellant
    liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 146.72234323771042,
        series_conductance = 5.0
    )

    # Electric turbopump at (-3, -1) - pumps fluid using stored energy
    electric_pump = ElectricPumpCompBehav(
        ElectricTurboPump;
        pump_voltage = 50.0,
        max_energy = 100000.0,
        initial_energy = 100000.0,
        max_conductance = 1.0,
        min_conductance = 0.0,
        change_rate = 1.0 / BASE_UPS
    )

    # Tile-based pipe at (-3, 1) - high-flow pipe connector
    tile_pipe = BigTilePipeCompBehav(10.0)

    # Small nozzle at (-7, 3) - provides thrust from gas
    nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.3,
        sprite = Symbol("AllNozzles_SmallNozzle")
    )

    # Place components on map
    components[TileCoord(-5, 0)] = ComponentOnTile(decomp_chamber, HexFrame.Q_POS)
    components[TileCoord(-1, 0)] = ComponentOnTile(liquid_tank, HexFrame.Q_NEG)
    components[TileCoord(-3, -1)] = ComponentOnTile(electric_pump, HexFrame.Q_POS)
    components[TileCoord(-3, 1)] = ComponentOnTile(tile_pipe, HexFrame.Q_POS)
    components[TileCoord(-7, 3)] = ComponentOnTile(nozzle, HexFrame.Q_POS)

    # Add edge-based pipes (BigPipe with 10.0 S conductance)
    pipes[
        EdgeCoord(
            VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS),
            VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    pipes[
        EdgeCoord(
            VertexCoord(TileCoord(-5, 2), HexFrame.Q_POS),
            VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    pipes[
        EdgeCoord(
            VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS),
            VertexCoord(TileCoord(-5, 2), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    # Define ship surface components
    surface = Set(
        [
            TileCoord(-4, 0),
            TileCoord(-2, -2),
            TileCoord(-3, -1),
            TileCoord(-4, 1),
            TileCoord(-5, -1),
            TileCoord(-3, 0),
            TileCoord(-6, 0),
            TileCoord(-2, -1),
            TileCoord(-3, 1),
            TileCoord(-4, 2),
            TileCoord(-6, 1),
            TileCoord(-5, 0),
            TileCoord(-1, 0),
            TileCoord(-5, 1),
            TileCoord(-2, 0),
            TileCoord(-3, 2),
            TileCoord(-6, 2),
            TileCoord(-2, 1),
            TileCoord(-6, 3),
            TileCoord(-5, 2),
            TileCoord(-3, -2),
            TileCoord(-5, 3),
            TileCoord(-4, -1),
        ]
    )

    set_component!(ship, components)
    set_pipe!(ship, pipes)
    set_surface_tile!(ship, surface)

    return GameMap(ship)
end
