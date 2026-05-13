"""
    mapgen_controllingcoldgas()

Cold gas control tutorial. Demonstrates a simple RCS layout with switched nozzles
and multiple gas tanks, teaching players how to control thrust direction.
"""
function mapgen_controllingcoldgas()
    blueprint = ShipBlueprint()

    # Gas tanks -- 6 identical cold gas tanks with separate instances
    tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 50.0,
        max_voltage = 50.0,
        initial_charge = 40.0,
        series_conductance = 5.0
    )
    blueprint.components[TileCoord(-1, 0)]  = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(-2, 0)]  = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(-1, 1)]  = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(-2, 1)]  = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(0, 0)]   = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)
    blueprint.components[TileCoord(-2, 2)]  = ComponentOnTile(deepcopy(tank_template), HexFrame.R_NEG, :_blueprint)

    # Switched nozzles -- 5 identical nozzles with separate instances
    nozzle_template = SwitchedNozzleCompBehav(
        throat_area = 0.2,
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
        limit_temperature_k = 400.0
    )
    blueprint.components[TileCoord(-4, 3)]  = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-4, 1)]  = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-4, 2)]  = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(1, -1)]  = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(1, 0)]   = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_NEG, :_blueprint)

    # Pipes -- connect left-side nozzles to tanks
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 0), HexFrame.Q_NEG))] = ScrapPipeBehav()
    blueprint.pipe_behaviors[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav()

    # Ship surface
    union!(blueprint.ship_tiles, Set([
        TileCoord(-1, 0),
        TileCoord(-1, 1),
        TileCoord(-2, 0),
        TileCoord(-3, 2),
        TileCoord(-2, 2),
        TileCoord(-3, 1),
        TileCoord(0, 0),
        TileCoord(-2, 1),
    ]))

    gamemap = GameMap(blueprint)
    return gamemap
end
