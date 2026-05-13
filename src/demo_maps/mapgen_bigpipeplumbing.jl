"""
    mapgen_bigpipeplumbing()

Advanced plumbing tutorial demonstrating high-flow pipe systems.

This map teaches:
- Using BigPipeBehav for high-conductance edge-based pipes (10.0 S)
- Tile-based multi-pipe components for hex tile connections
- Multiple gas tanks feeding into a common pipe network
- Complex pipe routing with both edge-based and tile-based pipes
"""
function mapgen_bigpipeplumbing()
    blueprint = ShipBlueprint()

    # Create multiple gas tanks
    # Using deepcopy for identical tanks to avoid shared state
    tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # Place four separate tank instances
    blueprint.components[TileCoord(2, -1)] = ComponentOnTile(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -1)] = ComponentOnTile(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -2)] = ComponentOnTile(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(4, -2)] = ComponentOnTile(deepcopy(tank_template), HexFrame.Q_NEG, :_blueprint)

    # Place a tile-based big pipe component on Q axis
    blueprint.components[TileCoord(0, -1)] = single_tile_pipe_on_tile(HexFrame.Q_POS, BigTilePipeBehavFrag(10.0))

    # Create a nozzle for thrust output
    nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = Float64(0.3f0),
        sprite = Symbol("AllNozzles_SmallNozzle")
    )
    blueprint.components[TileCoord(2, -3)] = ComponentOnTile(nozzle, HexFrame.R_POS, :_blueprint)

    # Add edge-based big pipes for high flow connections
    blueprint.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG),
            VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    blueprint.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG),
            VertexCoord(TileCoord(1, 1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    blueprint.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG),
            VertexCoord(TileCoord(1, -1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    # Define ship surface
    union!(blueprint.ship_tiles, Set([
        TileCoord(1, -2),
        TileCoord(4, -2),
        TileCoord(2, 0),
        TileCoord(-1, 0),
        TileCoord(1, 1),
        TileCoord(0, 1),
        TileCoord(2, -2),
        TileCoord(-1, 1),
        TileCoord(3, -2),
        TileCoord(1, -1),
        TileCoord(0, -1),
        TileCoord(2, -1),
        TileCoord(1, 0),
        TileCoord(0, 0),
        TileCoord(3, -1),
    ]))

    gamemap = GameMap(blueprint)
    return gamemap
end
