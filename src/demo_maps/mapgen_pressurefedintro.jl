#=
Scope: Pressure-fed propulsion tutorial map
Formatter: Runic
=#

"""
    mapgen_pressurefedintro()

Pressure-fed propulsion tutorial map.

This map teaches the relationship between pressurising gas, liquid fuel storage,
valves, and a decomposition chamber feeding a larger nozzle.
"""
function mapgen_pressurefedintro()
    blueprint = ShipBlueprint()

    # Liquid supply tanks feeding the pressure-fed tanks.
    liquid_tank_template = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )

    blueprint.components[TileCoord(-2, 3)] = PlacedComponent(liquid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-1, 2)] = PlacedComponent(liquid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-1, 3)] = PlacedComponent(liquid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-2, 2)] = PlacedComponent(liquid_tank_template, HexFrame.Q_POS, :_blueprint)

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

    blueprint.components[TileCoord(0, -1)] = PlacedComponent(pressure_fed_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(0, 0)] = PlacedComponent(pressure_fed_tank_template, HexFrame.Q_POS, :_blueprint)

    # Cold-gas pressurant source.
    blueprint.components[TileCoord(3, -4)] = PlacedComponent(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 100.0,
            max_voltage = 50.0,
            initial_charge = 90.0,
            series_conductance = 5.0
        ),
        HexFrame.Q_POS,
        :_blueprint
    )

    # Feed control and reaction hardware.
    blueprint.components[TileCoord(-2, 0)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            target_conductance = 0.0,
            current_conductance = 0.0
        ),
        HexFrame.Q_POS,
        :_blueprint
    )
    blueprint.components[TileCoord(-4, 0)] = PlacedComponent(BasicDecompChamber, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-6, 2)] = PlacedComponent(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.5,
            sprite_variant = SMALL_NOZZLE_SPRITE
        ),
        HexFrame.Q_POS,
        :_blueprint
    )

    # Liquid feed plumbing from the tanks through the valve and decomposition chamber.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-6, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 1), HexFrame.Q_NEG))] = BigPipeBehav()

    # Cold-gas pressurant plumbing feeding the pressure-fed tanks.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = ScrapPipeBehav()

    union!(
        blueprint.ship_tiles, Set(
            [
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
            ]
        )
    )

    gamemap = GameMap(blueprint)
    return gamemap
end
