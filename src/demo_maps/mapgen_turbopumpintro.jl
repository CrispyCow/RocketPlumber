"""
Turbopump Introduction Tutorial Map

This tutorial demonstrates a complete turbopump-driven propulsion system:
- Three liquid tanks storing monopropellant
- A turbopump that uses decomposition chamber exhaust to drive the pump
- A decomposition chamber that converts liquid monoprop to hot gas
- A medium nozzle for thrust generation
- BigPipe connections for high flow capacity

The turbopump uses the pressure from the decomposition chamber to power
the pump impeller, creating a self-sustaining propulsion cycle.
"""
function mapgen_turbopumpintro()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()
    pipes = Dict{EdgeCoord, PipeBehavior}()

    # Create three separate liquid tank instances (must be separate to avoid shared state)
    liquid_tank_1 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_2 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_3 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # Create turbopump instance
    turbopump = TurboPumpCompBehav(
        pump_voltage = 50.0,
        series_conductance = 1.0,
        turbine_gain = -0.2,
    )

    # Create decomposition chamber instance
    decomp_chamber = DecompChamberCompBehav(expansion_factor = 5.0)

    # Create nozzle instance
    nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.0,
        sprite = Symbol("AllNozzles_MediumNozzle")
    )

    # Place components on components
    components[TileCoord(-1, 0)] = ComponentOnTile(liquid_tank_1, HexFrame.Q_NEG)
    components[TileCoord(0, -1)] = ComponentOnTile(liquid_tank_2, HexFrame.Q_NEG)
    components[TileCoord(0, 0)] = ComponentOnTile(liquid_tank_3, HexFrame.Q_NEG)
    components[TileCoord(-3, 1)] = ComponentOnTile(turbopump, HexFrame.Q_POS)
    components[TileCoord(-5, 2)] = ComponentOnTile(decomp_chamber, HexFrame.Q_POS)
    components[TileCoord(-7, 3)] = ComponentOnTile(nozzle, HexFrame.Q_POS)

    # Add BigPipe connections (high flow capacity)
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

    # Define ship surface (valid placement area)
    surface = Set(
        [
            TileCoord(-1, 0),
            TileCoord(-5, 1),
            TileCoord(-2, 0),
            TileCoord(-3, 2),
            TileCoord(-6, 2),
            TileCoord(-2, 1),
            TileCoord(-4, 1),
            TileCoord(-6, 3),
            TileCoord(0, -1),
            TileCoord(-5, 2),
            TileCoord(-3, 0),
            TileCoord(-5, 3),
            TileCoord(-3, 1),
            TileCoord(-4, 2),
            TileCoord(0, 0),
        ]
    )

    set_component!(ship, components)
    set_pipe!(ship, pipes)
    set_surface_tile!(ship, surface)

    return GameMap(ship)
end
