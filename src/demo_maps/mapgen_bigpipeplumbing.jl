#=
Scope: High-flow pipe plumbing tutorial map
Formatter: Runic
=#

"""
    mapgen_bigpipeplumbing()

Advanced plumbing tutorial demonstrating high-flow pipe systems.

This map teaches:
- Using BigPipeBehav for high-conductance pipe segments (10.0 S)
- Mixing side-span and tile-crossing pipe routes
- Multiple gas tanks feeding into a common pipe network
- Complex pipe routing across several pipe segment spans
"""
function mapgen_bigpipeplumbing()
    blueprint = ShipBlueprint()

    # Create multiple gas tanks
    tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # Place four tanks sharing the immutable template
    blueprint.components[TileCoord(2, -1)] = PlacedComponent(tank_template, HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -1)] = PlacedComponent(tank_template, HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(3, -2)] = PlacedComponent(tank_template, HexFrame.Q_NEG, :_blueprint)
    blueprint.components[TileCoord(4, -2)] = PlacedComponent(tank_template, HexFrame.Q_NEG, :_blueprint)

    # Place a tile-based big pipe component on Q axis
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)

    # Create a nozzle for thrust output
    nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = Float64(0.3f0),
        sprite_variant = SMALL_NOZZLE_SPRITE
    )
    blueprint.components[TileCoord(2, -3)] = PlacedComponent(nozzle, HexFrame.R_POS, :_blueprint)

    # Add big pipes for high flow connections
    blueprint.pipe_behaviors[
        PipeCoord(
            VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG),
            VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    blueprint.pipe_behaviors[
        PipeCoord(
            VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG),
            VertexCoord(TileCoord(1, 1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    blueprint.pipe_behaviors[
        PipeCoord(
            VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG),
            VertexCoord(TileCoord(1, -1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    # Define ship surface
    union!(
        blueprint.ship_tiles, Set(
            [
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
            ]
        )
    )

    gamemap = GameMap(blueprint)
    return gamemap
end
