#=
Scope: Tap-off-cycle turbopump tutorial map
Formatter: Runic
=#

"""
    mapgen_turbopumpintro2()

Second turbopump tutorial map. Demonstrates a tap-off-cycle engine layout with a
closed valve on the propellant side, a decomp chamber feeding the turbine, and a
cluster of partially filled monoprop tanks ready to be plumbed into a working engine.
"""
function mapgen_turbopumpintro2()
    blueprint = ShipBlueprint()

    # Liquid tanks -- 5 identical tanks with separate instances
    tank_template = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )
    blueprint.components[TileCoord(2, 0)] = PlacedComponent(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(2, -1)] = PlacedComponent(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(2, -2)] = PlacedComponent(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -1)] = PlacedComponent(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -2)] = PlacedComponent(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)

    # Engine core
    blueprint.components[TileCoord(0, 0)] = PlacedComponent(
        TurboPumpCompBehav(
            max_pump_voltage = 50.0,
            series_conductance = 1.0,
            max_turbine_conductance = 0.30000001192092896,
            cycle_efficiency = 0.6000000238418579,
            current_rpm = 0.0,
            max_rpm = 3000.0,
            rotor_inertia = 50.0,
            friction_coefficient = 0.002,
            drive_time_constant = 1.25,
        ),
        HexFrame.Q_POS,
        :_blueprint
    )
    blueprint.components[TileCoord(-1, 0)] = PlacedComponent(
        StandardValveCompBehav(
            SteppedSwitchBehavFrag, TinyValve;
            max_conductance = 1.0,
            min_conductance = 0.0,
            growth_factor = 1.1931663751602173,
            percentage_step_size = 0.05000000074505806,
            target_conductance = 0.0,
            current_conductance = 0.0
        ),
        HexFrame.Q_POS,
        :_blueprint
    )
    blueprint.components[TileCoord(-2, 1)] = PlacedComponent(DecompChamberCompBehav(), HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-4, 2)] = PlacedComponent(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 0.5,
            sprite = Symbol("AllNozzles_SmallNozzle")
        ),
        HexFrame.Q_POS,
        :_blueprint
    )

    # Engine core plumbing
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)

    # Pump outlet — left junction header and direct tank feed
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)

    # Left-side manifold: outer tanks → junctions → inner tanks
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)

    # Right-side manifold: inner tanks via centre hub to junctions to outer tanks
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)

    union!(
        blueprint.ship_tiles, Set(
            [
                TileCoord(-3, 1),
                TileCoord(-3, 2),
                TileCoord(-2, 0),
                TileCoord(-2, 1),
                TileCoord(-2, 2),
                TileCoord(-1, 0),
                TileCoord(-1, 1),
                TileCoord(0, -1),
                TileCoord(0, 0),
                TileCoord(0, 1),
                TileCoord(1, -1),
                TileCoord(1, 0),
                TileCoord(2, -2),
                TileCoord(2, -1),
                TileCoord(2, 0),
                TileCoord(3, -2),
                TileCoord(3, -1),
            ]
        )
    )

    gamemap = GameMap(blueprint)
    return gamemap
end
