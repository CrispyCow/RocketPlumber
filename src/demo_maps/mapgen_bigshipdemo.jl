"""
    mapgen_bigshipdemo()

Generate a large demonstration ship with comprehensive propulsion system.
This map showcases a complex multi-tank spacecraft with:
- Multiple monopropellant liquid tanks throughout the ship
- Cold gas thruster banks with gas storage
- Electric pumps and turbopumps for fuel transfer
- Switched nozzles for maneuvering control
- Decomposition chambers for monopropellant
- Extensive pipe network using both BigPipe and ScrapPipe
"""
function mapgen_bigshipdemo()
    map = GameMap()

    # Define ship surface - all valid tile positions
    map.ship_surface = Set(
        [
            TileCoord(-2, 3), TileCoord(2, -4), TileCoord(2, 0), TileCoord(-10, 0),
            TileCoord(-2, 4), TileCoord(-7, 8), TileCoord(-7, 10), TileCoord(5, -5),
            TileCoord(-7, 2), TileCoord(-7, -3), TileCoord(3, -2), TileCoord(-4, 1),
            TileCoord(0, -1), TileCoord(4, -3), TileCoord(-8, -2), TileCoord(-1, -1),
            TileCoord(-5, 6), TileCoord(-4, 2), TileCoord(0, 0), TileCoord(-10, 3),
            TileCoord(-11, 8), TileCoord(-10, 4), TileCoord(-1, 0), TileCoord(-8, 5),
            TileCoord(9, 0), TileCoord(-8, 11), TileCoord(-9, 9), TileCoord(-12, 4),
            TileCoord(-2, 1), TileCoord(5, -2), TileCoord(-9, -1), TileCoord(-7, 6),
            TileCoord(0, 3), TileCoord(7, 1), TileCoord(-1, 3), TileCoord(-2, 2),
            TileCoord(-9, 0), TileCoord(-7, 7), TileCoord(6, -2), TileCoord(7, 2),
            TileCoord(7, -3), TileCoord(2, 1), TileCoord(-11, 6), TileCoord(-3, -1),
            TileCoord(1, -1), TileCoord(-9, 3), TileCoord(2, 2), TileCoord(2, -3),
            TileCoord(-3, 0), TileCoord(8, -4), TileCoord(-9, 4), TileCoord(-11, 7),
            TileCoord(1, 0), TileCoord(-12, 8), TileCoord(-7, -2), TileCoord(3, -1),
            TileCoord(-8, 9), TileCoord(4, -2), TileCoord(-6, 0), TileCoord(-10, 10),
            TileCoord(0, 1), TileCoord(8, 0), TileCoord(-7, 5), TileCoord(-8, -1),
            TileCoord(-1, 1), TileCoord(8, -8), TileCoord(3, -4), TileCoord(3, 0),
            TileCoord(-7, 11), TileCoord(9, 1), TileCoord(-3, 3), TileCoord(-6, 3),
            TileCoord(0, 2), TileCoord(0, -3), TileCoord(-3, 4), TileCoord(-6, 4),
            TileCoord(-1, 2), TileCoord(9, -10), TileCoord(-4, 5), TileCoord(-10, 6),
            TileCoord(-11, 5), TileCoord(5, -1), TileCoord(-12, 6), TileCoord(-2, -2),
            TileCoord(-8, 3), TileCoord(-10, 7), TileCoord(5, -4), TileCoord(-9, 10),
            TileCoord(-8, 4), TileCoord(-9, 2), TileCoord(5, 0), TileCoord(-12, 7),
            TileCoord(-5, -1), TileCoord(7, -9), TileCoord(-3, 1), TileCoord(6, -4),
            TileCoord(6, 0), TileCoord(-7, 9), TileCoord(1, 1), TileCoord(8, 1),
            TileCoord(2, -2), TileCoord(8, -10), TileCoord(-7, -1), TileCoord(-3, 2),
            TileCoord(-6, 2), TileCoord(8, 2), TileCoord(1, 2), TileCoord(1, -3),
            TileCoord(3, 1), TileCoord(4, -1), TileCoord(-10, 5), TileCoord(-7, -4),
            TileCoord(-9, 6), TileCoord(-7, 0), TileCoord(-10, 11), TileCoord(-5, 3),
            TileCoord(-4, -1), TileCoord(4, -4), TileCoord(4, 0), TileCoord(0, -2),
            TileCoord(3, -3), TileCoord(-5, 4), TileCoord(-9, 7), TileCoord(-1, -2),
            TileCoord(-12, 5), TileCoord(-8, 2), TileCoord(-8, -3), TileCoord(-8, 10),
            TileCoord(-4, 0), TileCoord(9, -9), TileCoord(-7, 3), TileCoord(-6, 6),
            TileCoord(-7, 4), TileCoord(6, -7), TileCoord(-2, -1), TileCoord(-4, 3),
            TileCoord(5, -3), TileCoord(-4, 4), TileCoord(-5, 1), TileCoord(-2, 0),
            TileCoord(-11, 3), TileCoord(6, 1), TileCoord(-11, 4), TileCoord(-9, 5),
            TileCoord(-8, 6), TileCoord(7, -4), TileCoord(6, -6), TileCoord(6, -3),
            TileCoord(2, -1), TileCoord(-5, 2), TileCoord(-10, -1), TileCoord(7, -8),
            TileCoord(-7, 1), TileCoord(1, -2), TileCoord(8, -9),
        ]
    )

    # Monopropellant liquid tanks (all with standard parameters)
    map.tiles[TileCoord(2, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-2, 3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(2, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-2, 4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-7, 8)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-4, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(4, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-1, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(6, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(7, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(2, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-3, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(2, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(2, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-3, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-7, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-8, 9)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-8, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(3, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-1, 3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-2, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-3, 3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-3, 4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-6, 4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-1, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(5, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-2, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(5, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-7, 9)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(1, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(2, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-7, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-6, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(1, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(1, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(4, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(4, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(4, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-5, 4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-1, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-4, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-2, -1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-4, 3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-4, 4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-2, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-5, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(7, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(6, -3)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(6, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(1, -2)] = ComponentOnTile(
        ThevininTankCompBehav(
            LiquidTankBehavFrag, 3;
            fluid = HexFluids.MONOPROP_LIQUID,
            max_charge = 200,
            max_voltage = 5,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_NEG
    )

    # Cold gas tanks (for thrusters)
    map.tiles[TileCoord(9, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(7, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(7, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, -8)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, 0)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(9, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(9, -10)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(7, -9)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, 1)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, 2)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, -10)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(9, -9)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(7, -8)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(8, -9)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.Q_POS
    )

    # Switched nozzles (for maneuvering control)
    map.tiles[TileCoord(10, 0)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(7, 3)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(9, -11)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.R_POS
    )
    map.tiles[TileCoord(9, -1)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.R_POS
    )
    map.tiles[TileCoord(7, -7)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(9, -8)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.S_POS
    )
    map.tiles[TileCoord(10, -10)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.Q_NEG
    )
    map.tiles[TileCoord(7, -10)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(9, 2)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.S_POS
    )
    map.tiles[TileCoord(7, 0)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(6, 2)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(6, -8)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.10000000149011612,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 0.10000000149011612
        ), HexFrame.Q_POS
    )

    # Basic nozzles (always-on thrusters)
    map.tiles[TileCoord(-13, 4)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-7, -5)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-8, 12)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-13, 8)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-11, 11)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-8, -4)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-7, 12)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-13, 6)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-11, 12)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-11, -1)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-11, 0)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.30000001192092896,
            sprite = :AllNozzles_SmallNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-13, 7)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-13, 5)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-13, 9)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS
    )

    # Electric turbopumps
    map.tiles[TileCoord(-7, 10)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-7, -3)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-8, -2)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-9, 9)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-9, -1)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-9, 0)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-9, 10)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-8, 10)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTurboPump;
            pump_voltage = 50.0,
            max_energy = 100000.0,
            initial_energy = 100000.0,
            max_conductance = 1.0,
            min_conductance = 0.0,
            change_rate = 0.016666666666666666
        ), HexFrame.R_NEG
    )

    # Electric transfer pumps
    map.tiles[TileCoord(-7, 2)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTransferPump;
            pump_voltage = 5.0,
            max_energy = 1.0e6,
            initial_energy = 1.0e6,
            max_conductance = 0.20000000298023224,
            min_conductance = 0.0,
            change_rate = 0.006666666666666667
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-7, 5)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTransferPump;
            pump_voltage = 5.0,
            max_energy = 1.0e6,
            initial_energy = 1.0e6,
            max_conductance = 0.20000000298023224,
            min_conductance = 0.0,
            change_rate = 0.006666666666666667
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-4, 5)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTransferPump;
            pump_voltage = 5.0,
            max_energy = 1.0e6,
            initial_energy = 1.0e6,
            max_conductance = 0.20000000298023224,
            min_conductance = 0.0,
            change_rate = 0.006666666666666667
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-4, -1)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTransferPump;
            pump_voltage = 5.0,
            max_energy = 1.0e6,
            initial_energy = 1.0e6,
            max_conductance = 0.20000000298023224,
            min_conductance = 0.0,
            change_rate = 0.006666666666666667
        ), HexFrame.Q_POS
    )

    # Turbopumps
    map.tiles[TileCoord(-10, 3)] = ComponentOnTile(
        TurboPumpCompBehav(
            pump_voltage = 50.0,
            series_conductance = 1.0,
            turbine_gain = -0.20000000298023224
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-10, 5)] = ComponentOnTile(
        TurboPumpCompBehav(
            pump_voltage = 50.0,
            series_conductance = 1.0,
            turbine_gain = -0.20000000298023224
        ), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-10, 7)] = ComponentOnTile(
        TurboPumpCompBehav(
            pump_voltage = 50.0,
            series_conductance = 1.0,
            turbine_gain = -0.20000000298023224
        ), HexFrame.Q_POS
    )

    # Adjustable valves
    map.tiles[TileCoord(-8, 5)] = ComponentOnTile(
        BigAdjustableValveCompBehav(
            max_conductance = 2.0,
            min_conductance = 0.0,
            percentage_step_size = 0.05000000074505806,
            change_rate = 0.004166666883975267
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-8, 3)] = ComponentOnTile(
        BigAdjustableValveCompBehav(
            max_conductance = 2.0,
            min_conductance = 0.0,
            percentage_step_size = 0.05000000074505806,
            change_rate = 0.004166666883975267
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-8, 4)] = ComponentOnTile(
        BigAdjustableValveCompBehav(
            max_conductance = 2.0,
            min_conductance = 0.0,
            percentage_step_size = 0.05000000074505806,
            change_rate = 0.004166666883975267
        ), HexFrame.Q_POS
    )

    # Decomposition chambers
    map.tiles[TileCoord(-10, 0)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-8, 11)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.S_POS
    )
    map.tiles[TileCoord(-12, 4)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-12, 8)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-10, 10)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-7, -4)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.R_POS
    )
    map.tiles[TileCoord(-10, 11)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-8, -3)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.R_POS
    )
    map.tiles[TileCoord(-10, -1)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.S_NEG
    )
    map.tiles[TileCoord(-12, 6)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.Q_POS
    )
    map.tiles[TileCoord(-7, 11)] = ComponentOnTile(
        DecompChamberCompBehav(expansion_factor = 5.0), HexFrame.S_POS
    )

    # Big tile-based pipes (high conductance)
    map.tiles[TileCoord(3, -2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(0, -1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(0, 0)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-4, 2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-1, 0)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-2, 1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(5, -2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(0, 3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(1, -1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(4, -2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-6, 3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(0, 2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(0, -3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-5, 3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(1, 0)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(3, -1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(0, 1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-1, 1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(0, -2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(5, -3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(2, -1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-3, 2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-5, 2)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-3, 1)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-7, 3)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-7, 4)] = ComponentOnTile(BigTilePipeCompBehav(), HexFrame.Q_NEG)

    # Scrap tile-based pipes (low conductance)
    map.tiles[TileCoord(-7, 6)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.S_POS)
    map.tiles[TileCoord(-7, 7)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.R_NEG)
    map.tiles[TileCoord(-11, 7)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-11, 5)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-6, 0)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.Q_POS)
    map.tiles[TileCoord(-7, 0)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.S_POS)
    map.tiles[TileCoord(-7, 1)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.R_POS)
    map.tiles[TileCoord(-6, 6)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.Q_NEG)
    map.tiles[TileCoord(-11, 3)] = ComponentOnTile(ScrapTilePipeCompBehav(), HexFrame.Q_POS)

    # Edge-based pipes (BigPipeBehav - high conductance, 10.0 S)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -8), HexFrame.Q_POS), VertexCoord(TileCoord(8, -9), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-9, 9), HexFrame.Q_POS), VertexCoord(TileCoord(-7, 8), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-10, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-8, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -4), HexFrame.Q_POS), VertexCoord(TileCoord(5, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-8, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-9, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-10, 3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_POS), VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-9, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-7, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_POS), VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-5, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -4), HexFrame.Q_POS), VertexCoord(TileCoord(6, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 9), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 9), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -9), HexFrame.Q_POS), VertexCoord(TileCoord(10, -10), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-8, 6), HexFrame.Q_NEG), VertexCoord(TileCoord(-9, 6), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-9, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-7, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-5, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-5, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_POS), VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 2), HexFrame.Q_POS), VertexCoord(TileCoord(4, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -8), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -3), HexFrame.Q_POS), VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, 0), HexFrame.Q_POS), VertexCoord(TileCoord(6, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-3, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-6, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -10), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-8, 10), HexFrame.Q_POS), VertexCoord(TileCoord(-6, 9), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_POS), VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(4, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -4), HexFrame.Q_POS), VertexCoord(TileCoord(4, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-6, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS), VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -4), HexFrame.Q_POS), VertexCoord(TileCoord(7, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, 1), HexFrame.Q_POS), VertexCoord(TileCoord(5, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -8), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-5, 3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-9, 10), HexFrame.Q_POS), VertexCoord(TileCoord(-7, 9), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 8), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 8), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -4), HexFrame.Q_POS), VertexCoord(TileCoord(3, -5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-10, 5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-8, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-6, 3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -9), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 3), HexFrame.Q_POS), VertexCoord(TileCoord(3, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_POS), VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -2), HexFrame.Q_POS), VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, 2), HexFrame.Q_POS), VertexCoord(TileCoord(8, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-5, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-6, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 1), HexFrame.Q_POS), VertexCoord(TileCoord(10, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-6, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(5, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_POS), VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -1), HexFrame.Q_POS), VertexCoord(TileCoord(7, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-5, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-10, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-8, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 8), HexFrame.Q_POS), VertexCoord(TileCoord(-10, 7), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_POS), VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-5, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-10, 7), HexFrame.Q_POS), VertexCoord(TileCoord(-8, 6), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-5, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 8), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 9), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-7, 9), HexFrame.Q_NEG), VertexCoord(TileCoord(-8, 10), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-8, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-6, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_POS), VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-5, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 5), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 8), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 9), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 6), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 7), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 8), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 8), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-12, 6), HexFrame.Q_NEG), VertexCoord(TileCoord(-13, 6), HexFrame.Q_POS))] = BigPipeBehav(10.0)

    # Edge-based pipes (ScrapPipeBehav - low conductance, 2.0 S)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-13, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-11, 5), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 2), HexFrame.Q_POS), VertexCoord(TileCoord(9, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -7), HexFrame.Q_POS), VertexCoord(TileCoord(8, -8), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 0), HexFrame.Q_POS), VertexCoord(TileCoord(9, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -10), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 0), HexFrame.Q_POS), VertexCoord(TileCoord(10, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(6, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -10), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -8), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -9), HexFrame.Q_POS), VertexCoord(TileCoord(8, -10), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, 1), HexFrame.Q_POS), VertexCoord(TileCoord(8, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 5), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(6, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(9, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(9, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-13, 8), HexFrame.Q_POS), VertexCoord(TileCoord(-11, 7), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -8), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -10), HexFrame.Q_POS), VertexCoord(TileCoord(9, -11), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 3), HexFrame.Q_POS), VertexCoord(TileCoord(9, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(7, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -11), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -10), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -7), HexFrame.Q_POS), VertexCoord(TileCoord(9, -8), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(9, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, 2), HexFrame.Q_POS), VertexCoord(TileCoord(10, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -7), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -8), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -10), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -8), HexFrame.Q_POS), VertexCoord(TileCoord(10, -9), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(9, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(8, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -8), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -9), HexFrame.Q_POS), VertexCoord(TileCoord(9, -10), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -11), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -10), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(6, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 1), HexFrame.Q_POS), VertexCoord(TileCoord(9, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(6, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, 3), HexFrame.Q_POS), VertexCoord(TileCoord(8, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -8), HexFrame.Q_POS), VertexCoord(TileCoord(9, -9), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -7), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-13, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-11, 3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -10), HexFrame.Q_POS), VertexCoord(TileCoord(10, -11), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -9), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -9), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    map.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-6, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-4, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)

    return map
end
