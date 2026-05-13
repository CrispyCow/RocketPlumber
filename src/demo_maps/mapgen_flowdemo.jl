"""
Generate the flowdemo tutorial map.

This map demonstrates a simple cold gas thruster system with multiple gas tanks
arranged in a cluster, connected through a pipe network to 3 nozzles.
The map demonstrates fluid flow and pressure dynamics.
"""
function mapgen_flowdemo()
    blueprint = ShipBlueprint()

    # Ship surface - defines where components can be placed and where pipes can connect
    surface_tiles = Set(
        [
            TileCoord(-3, 5),
            TileCoord(-3, 3),
            TileCoord(-3, 2),
            TileCoord(-3, 1),
            TileCoord(-3, 0),
            TileCoord(-3, -2),
            TileCoord(-2, 5),
            TileCoord(-2, 4),
            TileCoord(-2, 2),
            TileCoord(-2, 1),
            TileCoord(-2, 0),
            TileCoord(-2, -3),
            TileCoord(-1, 4),
            TileCoord(-1, 3),
            TileCoord(-1, 1),
            TileCoord(-1, 0),
            TileCoord(-1, -1),
            TileCoord(-1, -2),
            TileCoord(-1, -3),
            TileCoord(0, 3),
            TileCoord(0, 1),
            TileCoord(0, 0),
            TileCoord(0, -3),
            TileCoord(1, 2),
            TileCoord(1, 1),
            TileCoord(1, 0),
            TileCoord(1, -1),
            TileCoord(1, -3),
            TileCoord(2, 1),
            TileCoord(2, -1),
            TileCoord(2, -2),
            TileCoord(2, -3),
            TileCoord(3, -2),
            TileCoord(4, -2),
            TileCoord(4, -3),
            TileCoord(5, -2),
            TileCoord(5, -3),
            TileCoord(6, -3),
            TileCoord(7, -3),
            TileCoord(7, -4),
            TileCoord(8, -3),
            TileCoord(8, -4),
            TileCoord(8, -5),
            TileCoord(9, -4),
            TileCoord(9, -5),
        ]
    )

    # Gas tanks - Create separate instances for each tank (stateful components)
    # Using deepcopy pattern for multiple identical tanks
    tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 190.0,
        series_conductance = 5.0
    )

    # Place tanks on map (using deepcopy to avoid shared state)
    blueprint.components[TileCoord(7, -3)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(7, -4)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(8, -3)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(8, -4)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(8, -5)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(9, -4)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(9, -5)] = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)

    # Nozzles - Create inline (only 3 nozzles, inline is cleaner)
    blueprint.components[TileCoord(-4, -2)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS, :_blueprint
    )

    blueprint.components[TileCoord(-4, 2)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS, :_blueprint
    )

    blueprint.components[TileCoord(-4, 6)] = ComponentOnTile(
        BasicNozzleCompBehav(
            connected_node = HexFrame.NODE_Q_POS,
            throat_area = 1.0,
            sprite = :AllNozzles_MediumNozzle
        ), HexFrame.Q_POS, :_blueprint
    )

    # Pipe network - Edge-based pipes connecting tanks to nozzles
    # ScrapPipes (2.0 S conductance)
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(3, 1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -6), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_POS), VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_POS), VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 6), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -6), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -2), HexFrame.Q_POS), VertexCoord(TileCoord(9, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_POS), VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(10, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_POS), VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_POS), VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(1, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS), VertexCoord(TileCoord(0, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_POS), VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(6, -2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_POS), VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 5), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_POS), VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -5), HexFrame.Q_POS), VertexCoord(TileCoord(9, -6), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_POS), VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -3), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_POS), VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 6), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_POS), VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_POS), VertexCoord(TileCoord(10, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_POS), VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -1), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 3), HexFrame.Q_POS), VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -5), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS), VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_POS), VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_POS), VertexCoord(TileCoord(10, -6), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()

    # BigPipes (10.0 S conductance)
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(5, -3), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -3), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_POS), VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 5), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(5, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS), VertexCoord(TileCoord(0, 4), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 2), HexFrame.Q_POS))] = BigPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = BigPipeBehav()

    union!(blueprint.ship_tiles, surface_tiles)

    gamemap = GameMap(blueprint)
    return gamemap
end
