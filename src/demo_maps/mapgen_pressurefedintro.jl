"""
    mapgen_pressurefedintro()

Pressure-fed propulsion tutorial map.

This map teaches the relationship between pressurising gas, liquid fuel storage,
valves, and a decomposition chamber feeding a larger nozzle.
"""
function mapgen_pressurefedintro()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()

    # Liquid supply tanks feeding the pressure-fed tanks.
    liquid_tank_template = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )

    components[TileCoord(-2, 3)] = ComponentOnTile(deepcopy(liquid_tank_template), HexFrame.Q_POS)
    components[TileCoord(-1, 2)] = ComponentOnTile(deepcopy(liquid_tank_template), HexFrame.Q_POS)
    components[TileCoord(-1, 3)] = ComponentOnTile(deepcopy(liquid_tank_template), HexFrame.Q_POS)
    components[TileCoord(-2, 2)] = ComponentOnTile(deepcopy(liquid_tank_template), HexFrame.Q_POS)

    # Pressure-fed liquid tanks start with fuel loaded but no pressurising gas.
    pressure_fed_tank_template = PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = 30.0,
            initial_gas_charge = 0.0,
            max_liquid_charge = 40.0,
            max_gas_pressure = 50.0,
            gas_node = HexFrame.NODE_Q_POS,
            initial_liquid_fluid = HexFluids.MONOPROP_LIQUID
        ),
        (HexFrame.NODE_Q_NEG,),
        5.0,
        HexFluids.COLD_GAS,
        NoRotationBehavFrag()
    )

    components[TileCoord(0, -1)] = ComponentOnTile(deepcopy(pressure_fed_tank_template), HexFrame.Q_POS)
    components[TileCoord(0, 0)] = ComponentOnTile(deepcopy(pressure_fed_tank_template), HexFrame.Q_POS)

    # Cold-gas pressurant source.
    components[TileCoord(3, -4)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 100.0,
            max_voltage = 50.0,
            initial_charge = 90.0,
            series_conductance = 5.0
        ),
        HexFrame.Q_POS
    )

    # Feed control and reaction hardware.
    components[TileCoord(-2, 0)] = ComponentOnTile(
        StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
            max_conductance = 1.0,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            target_conductance = 0.0,
            current_conductance = 0.0
        ),
        HexFrame.Q_POS
    )
    components[TileCoord(-4, 0)] = ComponentOnTile(BasicDecompChamber, HexFrame.Q_POS)
    components[TileCoord(-6, 2)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.5,
            sprite = :AllNozzles_SmallNozzle
        ),
        HexFrame.Q_POS
    )

    set_component!(ship, components)

    # Liquid feed plumbing from the tanks through the valve and decomposition chamber.
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(-6, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 1), HexFrame.Q_NEG)),
        BigPipeBehav()
    )

    # Cold-gas pressurant plumbing feeding the pressure-fed tanks.
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -3), HexFrame.Q_POS)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS)),
        ScrapPipeBehav()
    )
    set_pipe!(
        ship,
        EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG)),
        ScrapPipeBehav()
    )

    ship.ship_tiles = Set([
        TileCoord(3, -3),
        TileCoord(2, -4),
        TileCoord(-2, 3),
        TileCoord(-4, 0),
        TileCoord(-3, -1),
        TileCoord(-4, 1),
        TileCoord(1, -1),
        TileCoord(0, -1),
        TileCoord(-1, -1),
        TileCoord(2, -3),
        TileCoord(-3, 0),
        TileCoord(-2, -1),
        TileCoord(-3, 1),
        TileCoord(0, 0),
        TileCoord(-5, 0),
        TileCoord(-1, 0),
        TileCoord(3, -5),
        TileCoord(0, 1),
        TileCoord(2, -2),
        TileCoord(-5, 1),
        TileCoord(-1, 1),
        TileCoord(-2, 0),
        TileCoord(3, -4),
        TileCoord(-2, 1),
        TileCoord(-5, 2),
        TileCoord(2, -1),
        TileCoord(4, -5),
        TileCoord(-1, 2),
        TileCoord(-1, 3),
        TileCoord(-2, 2),
        TileCoord(-4, -1),
        TileCoord(1, -2),
        TileCoord(4, -4),
    ])

    return GameMap(ship)
end