"""
    mapgen_fluidtransfer()

Fluid transfer tutorial map demonstrating liquid pumping and decomposition.

This map teaches:
- Liquid tank arrays with monopropellant
- Electric transfer pumps for moving fluids between tanks
- Turbopump for pressurization
- Decomposition chamber for converting liquid to gas
- Gas nozzles for thrust generation
- Flow control with adjustable valves
"""
function mapgen_fluidtransfer()
    ship = ShipMap()
    components = Dict{TileCoord, ComponentOnTile}()
    pipes = Dict{EdgeCoord, PipeBehavior}()

    # Create 9 liquid tanks - each needs to be a separate instance
    # Right side tank array (6 tanks)
    tank_1 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_2 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_3 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_4 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_5 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_6 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    tank_7 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 1,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # Center/destination tank (nearly empty and stalled)
    # Using ThevininTankCompBehav direct struct construction to set internal stallstate
    dest_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag(
            HexFlowTankComponents.TankBehavFrag(
                RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND),
                25.0,  # max_charge
                1.0,    # max_voltage
                HexFlowTankComponents.TankState(Float64(0.0)),  # state
                StallBehavFrag(BinaryStateBehavFrag(true))  # stallstate - set to stalled
            )
        ),
        (HexFrame.NODE_Q_POS, HexFrame.NODE_S_POS, HexFrame.NODE_R_POS),  # out_nodes
        5.0,  # series_conductance
        HexFluids.MONOPROP_LIQUID  # fluid
    )

    # Create electric transfer pumps - each needs to be a separate instance
    pump_1 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.5,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    pump_2 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.5,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    pump_3 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.5,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    # Create turbopump with inactive turbine state
    # Note: Using direct struct construction to set turbine_active_state to false
    turbopump = TurboPumpCompBehav(
        PumpBehavFrag(50.0),
        1.0,
        Float64(-0.2f0),
        StallBehavFrag(BinaryStateBehavFrag(false)),
        BinaryStateBehavFrag(false)
    )

    # Create decomposition chamber
    decomp = DecompChamberCompBehav(expansion_factor = 5.0)

    # Create nozzles - separate instances
    nozzle_1 = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.0,
        sprite = Symbol("AllNozzles_MediumNozzle")
    )

    nozzle_2 = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.0,
        sprite = Symbol("AllNozzles_MediumNozzle")
    )

    # Create adjustable valve
    valve = BigAdjustableValveCompBehav(
        max_conductance = 2.0,
        min_conductance = 0.0,
        percentage_step_size = Float64(0.05f0),
        change_rate = Float64(0.25f0 / 60)
    )

    # Create tile-based pipe components
    pipe_tile_1 = ScrapTilePipeCompBehav()
    pipe_tile_2 = ScrapTilePipeCompBehav()

    # Place components on map
    # Liquid tanks
    components[TileCoord(5, -7)] = ComponentOnTile(tank_1, HexFrame.Q_NEG)
    components[TileCoord(5, -8)] = ComponentOnTile(tank_2, HexFrame.Q_NEG)
    components[TileCoord(6, -7)] = ComponentOnTile(tank_3, HexFrame.Q_NEG)
    components[TileCoord(6, -8)] = ComponentOnTile(tank_4, HexFrame.Q_NEG)
    components[TileCoord(6, -9)] = ComponentOnTile(tank_5, HexFrame.Q_NEG)
    components[TileCoord(7, -8)] = ComponentOnTile(tank_6, HexFrame.Q_NEG)
    components[TileCoord(7, -9)] = ComponentOnTile(tank_7, HexFrame.Q_NEG)
    components[TileCoord(0, 0)] = ComponentOnTile(dest_tank, HexFrame.Q_NEG)

    # Electric pumps
    components[TileCoord(4, -5)] = ComponentOnTile(pump_1, HexFrame.R_NEG)
    components[TileCoord(3, -7)] = ComponentOnTile(pump_2, HexFrame.Q_POS)
    components[TileCoord(0, -3)] = ComponentOnTile(pump_3, HexFrame.R_NEG)

    # Turbopump
    components[TileCoord(-4, 2)] = ComponentOnTile(turbopump, HexFrame.Q_POS)

    # Decomposition chamber
    components[TileCoord(-6, 3)] = ComponentOnTile(decomp, HexFrame.Q_POS)

    # Nozzles
    components[TileCoord(-7, 3)] = ComponentOnTile(nozzle_1, HexFrame.Q_POS)
    components[TileCoord(-7, 4)] = ComponentOnTile(nozzle_2, HexFrame.Q_POS)

    # Valve
    components[TileCoord(-2, 1)] = ComponentOnTile(valve, HexFrame.Q_POS)

    # Tile-based pipes
    components[TileCoord(3, -5)] = ComponentOnTile(pipe_tile_1, HexFrame.R_POS)
    components[TileCoord(-5, 2)] = ComponentOnTile(pipe_tile_2, HexFrame.Q_POS)

    # Add edge-based pipe behaviors
    # ScrapPipes (2.0 S)
    pipes[EdgeCoord(VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(2, -4), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_POS), VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -2), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(5, -7), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -7), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(1, -3), HexFrame.Q_POS), VertexCoord(TileCoord(3, -4), HexFrame.Q_NEG))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -3), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(5, -8), HexFrame.Q_NEG), VertexCoord(TileCoord(4, -7), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(3, -6), HexFrame.Q_POS), VertexCoord(TileCoord(5, -7), HexFrame.Q_NEG))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(4, -6), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -6), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(0, -1), HexFrame.Q_POS))] = ScrapPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-5, 2), HexFrame.Q_NEG))] = ScrapPipeBehav()

    # BigPipes (10.0 S)
    pipes[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 4), HexFrame.Q_POS))] = BigPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-4, 2), HexFrame.Q_NEG))] = BigPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(-6, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-7, 3), HexFrame.Q_POS))] = BigPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav()
    pipes[EdgeCoord(VertexCoord(TileCoord(-2, 1), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))] = BigPipeBehav()

    # Define ship surface
    surface = Set(
        [
            TileCoord(0, -2),
            TileCoord(2, -4),
            TileCoord(6, -9),
            TileCoord(5, -7),
            TileCoord(1, -1),
            TileCoord(4, -6),
            TileCoord(5, -8),
            TileCoord(0, -1),
            TileCoord(2, -3),
            TileCoord(7, -9),
            TileCoord(6, -7),
            TileCoord(-4, 2),
            TileCoord(-3, 1),
            TileCoord(0, 0),
            TileCoord(-1, 0),
            TileCoord(3, -5),
            TileCoord(3, -7),
            TileCoord(6, -8),
            TileCoord(-1, 1),
            TileCoord(3, -4),
            TileCoord(-3, 2),
            TileCoord(-2, 1),
            TileCoord(-6, 3),
            TileCoord(1, -3),
            TileCoord(0, -3),
            TileCoord(-5, 2),
            TileCoord(4, -5),
            TileCoord(4, -7),
            TileCoord(7, -8),
            TileCoord(-5, 3),
            TileCoord(3, -6),
            TileCoord(1, -2),
        ]
    )

    set_component!(ship, components)
    set_pipe!(ship, pipes)
    set_surface_tile!(ship, surface)

    return GameMap(ship)
end
