#=
Scope: Fluid-flow demonstration tutorial map
Formatter: Runic
=#

"""
    mapgen_flowdemo()

Generate the flow-demo tutorial map: seven cold-gas tanks feed three nozzles
through the saved 187-pipe network.
"""
function mapgen_flowdemo()
    blueprint = ShipBlueprint()

    # Stateful components need independent instances at every placement.
    tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200.0,
        max_voltage = 50.0,
        initial_charge = 190.0,
        series_conductance = 5.0,
    )
    for tile in (
            TileCoord(7, -4), TileCoord(7, -3), TileCoord(8, -5), TileCoord(8, -4),
            TileCoord(8, -3), TileCoord(9, -5), TileCoord(9, -4)
        )
        blueprint.components[tile] =
            PlacedComponent(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    end

    nozzle_template = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.0,
        sprite = :AllNozzles_MediumNozzle,
    )
    for tile in (TileCoord(-4, -2), TileCoord(-4, 2), TileCoord(-4, 6))
        blueprint.components[tile] =
            PlacedComponent(deepcopy(nozzle_template), HexFrame.Q_POS, :_blueprint)
    end

    # Pipe network; each endpoint is copied from the saved map.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-4, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-4, 6), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-3, 6), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS), VertexCoord(TileCoord(0, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_POS), VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(0, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 2), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS), VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-3, 6), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-2, 5), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(1, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS), VertexCoord(TileCoord(1, 3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-2, 5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 4), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_POS), VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_POS), VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_POS), VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(3, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(0, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -4), HexFrame.Q_POS), VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_POS), VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(3, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(2, 1), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_POS), VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_POS), VertexCoord(TileCoord(6, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_POS), VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_POS), VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -3), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_POS), VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(6, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(5, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -5), HexFrame.Q_POS), VertexCoord(TileCoord(9, -6), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_POS), VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_POS), VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(6, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(7, -2), HexFrame.Q_POS), VertexCoord(TileCoord(9, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_POS), VertexCoord(TileCoord(10, -6), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_POS), VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_POS), VertexCoord(TileCoord(10, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(7, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(9, -6), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(9, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(9, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(9, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(8, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(10, -6), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -5), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(10, -5), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(10, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(9, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    # Surface tiles
    union!(blueprint.ship_tiles, Set([
        TileCoord(-3, -2),
        TileCoord(-3, 0),
        TileCoord(-3, 1),
        TileCoord(-3, 2),
        TileCoord(-3, 3),
        TileCoord(-3, 5),
        TileCoord(-2, -3),
        TileCoord(-2, 0),
        TileCoord(-2, 1),
        TileCoord(-2, 2),
        TileCoord(-2, 4),
        TileCoord(-2, 5),
        TileCoord(-1, -3),
        TileCoord(-1, -2),
        TileCoord(-1, -1),
        TileCoord(-1, 0),
        TileCoord(-1, 1),
        TileCoord(-1, 3),
        TileCoord(-1, 4),
        TileCoord(0, -3),
        TileCoord(0, 0),
        TileCoord(0, 1),
        TileCoord(0, 3),
        TileCoord(1, -3),
        TileCoord(1, -1),
        TileCoord(1, 0),
        TileCoord(1, 1),
        TileCoord(1, 2),
        TileCoord(2, -3),
        TileCoord(2, -2),
        TileCoord(2, -1),
        TileCoord(2, 1),
        TileCoord(3, -2),
        TileCoord(4, -3),
        TileCoord(4, -2),
        TileCoord(5, -3),
        TileCoord(5, -2),
        TileCoord(6, -3),
        TileCoord(7, -4),
        TileCoord(7, -3),
        TileCoord(8, -5),
        TileCoord(8, -4),
        TileCoord(8, -3),
        TileCoord(9, -5),
        TileCoord(9, -4),
    ]))

    gamemap = GameMap(blueprint)
    return gamemap
end
