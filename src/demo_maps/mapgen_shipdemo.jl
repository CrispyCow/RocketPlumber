"""
Ship Demo Map

A large demonstration map featuring:
- Multiple cold gas tanks for RCS (Reaction Control System) thrusters
- Multiple monopropellant liquid tanks for main propulsion
- Turbopump-driven propulsion system with decomposition chambers
- Electric pumps for fuel transfer and backup systems
- Switched nozzles for precise thrust control
- Adjustable valves for flow regulation
- Complex piping network with both ScrapPipe and BigPipe connections

This map demonstrates a complete spacecraft propulsion architecture with:
- RCS system for attitude control
- Main propulsion for delta-V maneuvers
- Fuel transfer capabilities
- Redundant systems
"""
function mapgen_shipdemo()
    map = GameMap()

    # === Gas Tanks (Cold Gas for RCS) ===
    # Create separate instances for each gas tank to avoid shared state
    gas_tank_1 = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    gas_tank_2 = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    gas_tank_3 = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    gas_tank_4 = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    gas_tank_5 = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 200,
        max_voltage = 50,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # === Liquid Tanks (Monopropellant) ===
    # Create separate instances for each liquid tank
    liquid_tank_1 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_2 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_3 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_4 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_5 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_6 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_7 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_8 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_9 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    liquid_tank_10 = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 200,
        max_voltage = 5,
        initial_charge = 150,
        series_conductance = 5.0
    )

    # === Decomposition Chambers ===
    decomp_1 = DecompChamberCompBehav(expansion_factor = 5.0)

    decomp_2 = DecompChamberCompBehav(expansion_factor = 5.0)

    # === Turbopump ===
    turbopump = TurboPumpCompBehav(
        pump_voltage = 50.0,
        series_conductance = 1.0,
        turbine_gain = -0.2,
    )

    # === Electric Pumps ===
    elec_turbopump = ElectricPumpCompBehav(
        ElectricTurboPump;
        pump_voltage = 50.0,
        max_energy = 100000.0,
        initial_energy = 100000.0,
        max_conductance = 1.0,
        min_conductance = 0.0,
        change_rate = 1.0 / 60
    )

    # Create separate instances for electric transfer pumps
    elec_transfer_1 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.2,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    elec_transfer_2 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.2,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    elec_transfer_3 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.2,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    elec_transfer_4 = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 1000000.0,
        initial_energy = 1000000.0,
        max_conductance = 0.2,
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )

    # === Adjustable Valve ===
    adj_valve = BigAdjustableValveCompBehav(
        max_conductance = 2.0,
        min_conductance = 0.0,
        percentage_step_size = 0.05,
        change_rate = 0.25 / 60
    )

    # === Nozzles ===
    # Small nozzles for RCS
    small_nozzle_1 = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.3,
        sprite = Symbol("AllNozzles_SmallNozzle")
    )

    small_nozzle_2 = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.3,
        sprite = Symbol("AllNozzles_SmallNozzle")
    )

    # === Place Tiles ===
    # Gas tanks
    map.tiles[TileCoord(4, 1)] = ComponentOnTile(gas_tank_1, HexFrame.R_POS)
    map.tiles[TileCoord(5, 0)] = ComponentOnTile(gas_tank_2, HexFrame.S_POS)
    map.tiles[TileCoord(4, -6)] = ComponentOnTile(gas_tank_3, HexFrame.R_POS)
    map.tiles[TileCoord(4, 0)] = ComponentOnTile(gas_tank_4, HexFrame.R_POS)
    map.tiles[TileCoord(4, -5)] = ComponentOnTile(gas_tank_5, HexFrame.R_POS)
    map.tiles[TileCoord(5, -6)] = ComponentOnTile(
        ThevininTankCompBehav(
            GasTankBehavFrag, 3;
            fluid = HexFluids.COLD_GAS,
            max_charge = 200,
            max_voltage = 50,
            initial_charge = 150,
            series_conductance = 5.0
        ), HexFrame.R_POS
    )

    # Liquid tanks
    map.tiles[TileCoord(5, -4)] = ComponentOnTile(liquid_tank_1, HexFrame.Q_NEG)
    map.tiles[TileCoord(6, -5)] = ComponentOnTile(liquid_tank_2, HexFrame.Q_NEG)
    map.tiles[TileCoord(9, -5)] = ComponentOnTile(liquid_tank_3, HexFrame.Q_NEG)
    map.tiles[TileCoord(6, -4)] = ComponentOnTile(liquid_tank_4, HexFrame.Q_NEG)
    map.tiles[TileCoord(5, -2)] = ComponentOnTile(liquid_tank_5, HexFrame.Q_NEG)
    map.tiles[TileCoord(11, -6)] = ComponentOnTile(liquid_tank_6, HexFrame.Q_POS)
    map.tiles[TileCoord(6, -2)] = ComponentOnTile(liquid_tank_7, HexFrame.Q_NEG)
    map.tiles[TileCoord(7, -3)] = ComponentOnTile(liquid_tank_8, HexFrame.Q_NEG)
    map.tiles[TileCoord(5, -3)] = ComponentOnTile(liquid_tank_9, HexFrame.Q_NEG)
    map.tiles[TileCoord(7, -5)] = ComponentOnTile(liquid_tank_10, HexFrame.Q_NEG)
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

    # Decomposition chambers
    map.tiles[TileCoord(-1, -1)] = ComponentOnTile(decomp_1, HexFrame.Q_POS)
    map.tiles[TileCoord(-1, 1)] = ComponentOnTile(decomp_2, HexFrame.Q_POS)

    # Pumps
    map.tiles[TileCoord(1, 0)] = ComponentOnTile(elec_turbopump, HexFrame.Q_POS)
    map.tiles[TileCoord(1, -2)] = ComponentOnTile(turbopump, HexFrame.Q_POS)
    map.tiles[TileCoord(8, -5)] = ComponentOnTile(elec_transfer_1, HexFrame.S_NEG)
    map.tiles[TileCoord(10, -6)] = ComponentOnTile(elec_transfer_2, HexFrame.Q_NEG)
    map.tiles[TileCoord(8, -4)] = ComponentOnTile(elec_transfer_3, HexFrame.R_NEG)
    map.tiles[TileCoord(10, -5)] = ComponentOnTile(elec_transfer_4, HexFrame.Q_POS)

    # Valve
    map.tiles[TileCoord(3, -3)] = ComponentOnTile(adj_valve, HexFrame.Q_POS)

    # RCS Nozzles
    map.tiles[TileCoord(-3, 2)] = ComponentOnTile(small_nozzle_1, HexFrame.Q_POS)
    map.tiles[TileCoord(-3, 0)] = ComponentOnTile(small_nozzle_2, HexFrame.Q_POS)

    # Switched nozzles (create separate instances for each)
    map.tiles[TileCoord(-2, 4)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(0, -4)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(0, 3)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(-2, -3)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.S_NEG
    )
    map.tiles[TileCoord(2, 2)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.R_NEG
    )
    map.tiles[TileCoord(2, -5)] = ComponentOnTile(
        SwitchedNozzleCompBehav(
            throat_area = 0.1,
            connected_node = HexFrame.NODE_Q_POS,
            max_conductance = 2.0,
            min_conductance = 0.0,
            change_rate = 6.0 / 60
        ), HexFrame.S_NEG
    )

    # Tile-based pipes
    map.tiles[TileCoord(1, 2)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, 1)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-1, 3)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(1, -4)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(-1, -3)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, -5)] = ComponentOnTile(
        ScrapTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )

    map.tiles[TileCoord(0, -2)] = ComponentOnTile(
        BigTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 10.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )
    map.tiles[TileCoord(3, -1)] = ComponentOnTile(
        BigTilePipeCompBehav(
            BasicElemBehavFrag(
                RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 10.0, CONST_RESISTOR)
            )
        ),
        HexFrame.Q_NEG
    )

    # === Edge-based Pipes ===
    # BigPipe connections
    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(8, -3), HexFrame.Q_NEG),
            VertexCoord(TileCoord(7, -3), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(8, -6), HexFrame.Q_NEG),
            VertexCoord(TileCoord(7, -5), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG),
            VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS),
            VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS),
            VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(3, -3), HexFrame.Q_POS),
            VertexCoord(TileCoord(5, -4), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(1, 0), HexFrame.Q_POS),
            VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(3, -1), HexFrame.Q_POS),
            VertexCoord(TileCoord(5, -2), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-3, 2), HexFrame.Q_POS),
            VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(1, -2), HexFrame.Q_POS),
            VertexCoord(TileCoord(3, -3), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-3, 0), HexFrame.Q_POS),
            VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-2, -1), HexFrame.Q_POS),
            VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG)
        ),
    ] = BigPipeBehav(10.0)

    # ScrapPipe connections
    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(1, 2), HexFrame.Q_POS),
            VertexCoord(TileCoord(3, 1), HexFrame.Q_NEG)
        ),
    ] = ScrapPipeBehav(2.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS),
            VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG)
        ),
    ] = ScrapPipeBehav(2.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(1, -4), HexFrame.Q_POS),
            VertexCoord(TileCoord(3, -5), HexFrame.Q_NEG)
        ),
    ] = ScrapPipeBehav(2.0)

    map.pipe_behaviors[
        EdgeCoord(
            VertexCoord(TileCoord(-1, -3), HexFrame.Q_POS),
            VertexCoord(TileCoord(1, -4), HexFrame.Q_NEG)
        ),
    ] = ScrapPipeBehav(2.0)

    # === Ship Surface ===
    map.ship_surface = Set(
        [
            TileCoord(2, -4),
            TileCoord(2, 0),
            TileCoord(-2, 3),
            TileCoord(5, -1),
            TileCoord(4, 1),
            TileCoord(5, -5),
            TileCoord(-2, -2),
            TileCoord(3, -2),
            TileCoord(5, -4),
            TileCoord(5, 0),
            TileCoord(4, -6),
            TileCoord(0, -1),
            TileCoord(7, -2),
            TileCoord(4, -3),
            TileCoord(6, -1),
            TileCoord(-1, -1),
            TileCoord(6, -5),
            TileCoord(9, -5),
            TileCoord(0, 0),
            TileCoord(6, -4),
            TileCoord(-1, 0),
            TileCoord(1, 1),
            TileCoord(9, -4),
            TileCoord(2, -2),
            TileCoord(8, -6),
            TileCoord(-2, 1),
            TileCoord(8, -3),
            TileCoord(5, -2),
            TileCoord(1, 2),
            TileCoord(3, 1),
            TileCoord(1, -3),
            TileCoord(11, -6),
            TileCoord(4, -1),
            TileCoord(4, -5),
            TileCoord(-1, 3),
            TileCoord(-2, 2),
            TileCoord(4, -4),
            TileCoord(4, 0),
            TileCoord(3, -3),
            TileCoord(0, -2),
            TileCoord(6, -2),
            TileCoord(7, -6),
            TileCoord(-1, -2),
            TileCoord(7, -3),
            TileCoord(2, 1),
            TileCoord(1, -1),
            TileCoord(8, -5),
            TileCoord(10, -6),
            TileCoord(2, -3),
            TileCoord(8, -4),
            TileCoord(1, -4),
            TileCoord(1, 0),
            TileCoord(-2, -1),
            TileCoord(3, -1),
            TileCoord(5, -6),
            TileCoord(4, -2),
            TileCoord(3, -5),
            TileCoord(5, -3),
            TileCoord(0, 1),
            TileCoord(-1, 1),
            TileCoord(7, -5),
            TileCoord(3, -4),
            TileCoord(3, 0),
            TileCoord(-2, 0),
            TileCoord(7, -4),
            TileCoord(0, 2),
            TileCoord(0, -3),
            TileCoord(6, -6),
            TileCoord(6, -3),
            TileCoord(-1, 2),
            TileCoord(-1, -3),
            TileCoord(9, -6),
            TileCoord(2, -1),
            TileCoord(10, -5),
            TileCoord(1, -2),
        ]
    )

    return map
end
