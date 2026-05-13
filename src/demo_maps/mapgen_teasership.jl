"""
    mapgen_teasership()

Hand-authored encoding of the teasership sandbox map.
Preserves the original four-ship layout and the few live switch states that were
already present in the saved map.
"""
function mapgen_teasership()
    map = GameMap()

    # Shared templates. Stateful behaviours are deep-copied at placement time.
    av_gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 50.0,
        max_voltage = 50.0,
        initial_charge = 40.0,
        series_conductance = 5.0
    )
    transfer_liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 35.0,
        series_conductance = 5.0
    )
    legacy_liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 100.0,
        max_voltage = 1.0,
        initial_charge = 80.0,
        series_conductance = 5.0
    )
    pressure_fed_tank = PressureFedTankCompBehav(
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
    transfer_pump = ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = 150000.0,
        initial_energy = 150000.0,
        max_conductance = 0.5,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(0.5, 0.0, 0.4 / BASE_UPS)
    )
    turbo_pump = TurboPumpCompBehav(
        max_pump_voltage = 50.0,
        series_conductance = 1.0,
    )
    tiny_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.2,
        sprite = :AllNozzles_TinyNozzle
    )
    small_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.5,
        sprite = :AllNozzles_SmallNozzle
    )
    medium_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.5,
        sprite = :AllNozzles_MediumNozzle
    )
    switched_tiny_nozzle = SwitchedNozzleCompBehav(
        throat_area = 0.2,
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
        limit_temperature_k = 400.0
    )
    tiny_on_off_valve = StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
        max_conductance = 1.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS)
    )
    open_tiny_on_off_valve = StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
        max_conductance = 1.0,
        min_conductance = 0.0,
        target_conductance = 1.0,
        growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS)
    )
    tiny_adjustable_valve = StandardValveCompBehav(SteppedSwitchBehavFrag, TinyValve;
        max_conductance = 1.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
        percentage_step_size = 0.05
    )

    # The save contains one armed nozzle and two partially-open valves.
    armed_switched_tiny_nozzle = SwitchedNozzleCompBehav(
        NozzleBehavFrag(
            HexFrame.NODE_INTERNAL_1,
            0.2,
            AutoDeactivationBehavFrag(),
            OverheatLimitBehavFrag(400.0, 5.3, 5.0)
        ),
        BoolSwitchBehavFrag(SwitchBehavFrag(
            RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_INTERNAL_1),
            2.0,
            0.0,
            calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
            HexFlowSwitchComponents.SwitchState(2.0, 0.0)
        ))
    )
    partially_open_legacy_valve = StandardValveCompBehav{SteppedSwitchBehavFrag, TinyValve}(
        SteppedSwitchBehavFrag(SwitchBehavFrag(
            RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
            1.0,
            0.0,
            calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            HexFlowSwitchComponents.SwitchState(0.07071068090999705, 0.0)
        ), 0.05)
    )
    partially_open_platform_valve = StandardValveCompBehav{SteppedSwitchBehavFrag, TinyValve}(
        SteppedSwitchBehavFrag(SwitchBehavFrag(
            RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
            1.0,
            0.0,
            calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            HexFlowSwitchComponents.SwitchState(0.01880301583656157, 0.0)
        ), 0.05)
    )

    scrap_pipe = ScrapPipeBehav()
    big_pipe = BigPipeBehav()

    # ===============================================================
    # Ship Construction
    # ===============================================================

    #= ---------- Ship :##Ship AV-551#655 ----------- =#
    blueprint_av_551 = ShipBlueprint()

    # Cold-gas tank cluster
    for tile in [
        TileCoord(3, -14),
        TileCoord(1, -13),
        TileCoord(1, -11),
        TileCoord(2, -13),
        TileCoord(1, -12),
        TileCoord(2, -12),
        TileCoord(3, -13),
        TileCoord(4, -14),
        TileCoord(3, -12),
        TileCoord(2, -14),
    ]
        blueprint_av_551.components[tile] = ComponentOnTile(deepcopy(av_gas_tank), HexFrame.Q_POS, :_blueprint)
    end

    # Two nozzles start closed; one preserves the armed save-state.
    for tile in [TileCoord(0, -12), TileCoord(0, -11)]
        blueprint_av_551.components[tile] = ComponentOnTile(deepcopy(switched_tiny_nozzle), HexFrame.Q_POS, :_blueprint)
    end
    blueprint_av_551.components[TileCoord(1, -14)] = ComponentOnTile(deepcopy(armed_switched_tiny_nozzle), HexFrame.S_NEG, :_blueprint)
    for (tile_a, axis_a, tile_b, axis_b) in [
        (TileCoord(3, -14), HexFrame.Q_NEG, TileCoord(2, -14), HexFrame.Q_POS),
        (TileCoord(4, -14), HexFrame.Q_NEG, TileCoord(3, -13), HexFrame.Q_POS),
        (TileCoord(2, -12), HexFrame.Q_NEG, TileCoord(1, -11), HexFrame.Q_POS),
        (TileCoord(1, -11), HexFrame.Q_POS, TileCoord(3, -12), HexFrame.Q_NEG),
        (TileCoord(2, -14), HexFrame.Q_NEG, TileCoord(1, -13), HexFrame.Q_POS),
        (TileCoord(0, -12), HexFrame.Q_POS, TileCoord(2, -13), HexFrame.Q_NEG),
        (TileCoord(3, -12), HexFrame.Q_NEG, TileCoord(2, -11), HexFrame.Q_POS),
        (TileCoord(4, -14), HexFrame.Q_NEG, TileCoord(3, -14), HexFrame.Q_POS),
        (TileCoord(1, -12), HexFrame.Q_POS, TileCoord(3, -13), HexFrame.Q_NEG),
        (TileCoord(3, -13), HexFrame.Q_NEG, TileCoord(2, -12), HexFrame.Q_POS),
        (TileCoord(3, -13), HexFrame.Q_NEG, TileCoord(2, -13), HexFrame.Q_POS),
        (TileCoord(1, -11), HexFrame.Q_NEG, TileCoord(0, -11), HexFrame.Q_POS),
        (TileCoord(2, -13), HexFrame.Q_NEG, TileCoord(1, -12), HexFrame.Q_POS),
        (TileCoord(0, -13), HexFrame.Q_POS, TileCoord(2, -14), HexFrame.Q_NEG),
        (TileCoord(2, -12), HexFrame.Q_NEG, TileCoord(1, -12), HexFrame.Q_POS),
        (TileCoord(2, -13), HexFrame.Q_POS, TileCoord(4, -14), HexFrame.Q_NEG),
        (TileCoord(2, -14), HexFrame.Q_NEG, TileCoord(1, -14), HexFrame.Q_POS),
        (TileCoord(2, -12), HexFrame.Q_POS, TileCoord(4, -13), HexFrame.Q_NEG),
        (TileCoord(0, -11), HexFrame.Q_POS, TileCoord(2, -12), HexFrame.Q_NEG),
        (TileCoord(3, -14), HexFrame.Q_NEG, TileCoord(2, -13), HexFrame.Q_POS),
    ]
        blueprint_av_551.pipe_behaviors[EdgeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = scrap_pipe
    end

    union!(blueprint_av_551.ship_tiles, Set{TileCoord}([
        TileCoord(2, -12),
        TileCoord(3, -14),
        TileCoord(3, -13),
        TileCoord(1, -13),
        TileCoord(4, -14),
        TileCoord(3, -12),
        TileCoord(1, -12),
        TileCoord(1, -11),
        TileCoord(2, -13),
        TileCoord(2, -14),
    ]))
    #= ---------- Ship :primary ----------- =#
    blueprint_primary = ShipBlueprint()

    for (tile, rotation) in [
        (TileCoord(4, -6), HexFrame.R_NEG),
        (TileCoord(1, -5), HexFrame.Q_POS),
    ]
        blueprint_primary.components[tile] = ComponentOnTile(deepcopy(transfer_pump), rotation, :_blueprint)
    end

    for tile in [
        TileCoord(5, -8),
        TileCoord(4, -8),
        TileCoord(2, -6),
        TileCoord(5, -7),
        TileCoord(3, -7),
        TileCoord(4, -9),
        TileCoord(4, -7),
        TileCoord(2, -7),
    ]
        blueprint_primary.components[tile] = ComponentOnTile(deepcopy(transfer_liquid_tank), HexFrame.Q_NEG, :_blueprint)
    end
    for (tile_a, axis_a, tile_b, axis_b) in [
        (TileCoord(1, -5), HexFrame.Q_POS, TileCoord(3, -6), HexFrame.Q_NEG),
        (TileCoord(4, -8), HexFrame.Q_NEG, TileCoord(3, -7), HexFrame.Q_POS),
        (TileCoord(-3, -4), HexFrame.Q_POS, TileCoord(-1, -5), HexFrame.Q_NEG),
        (TileCoord(4, -7), HexFrame.Q_POS, TileCoord(6, -8), HexFrame.Q_NEG),
        (TileCoord(4, -8), HexFrame.Q_NEG, TileCoord(3, -8), HexFrame.Q_POS),
        (TileCoord(2, -4), HexFrame.Q_POS, TileCoord(4, -5), HexFrame.Q_NEG),
        (TileCoord(3, -4), HexFrame.Q_NEG, TileCoord(2, -4), HexFrame.Q_POS),
        (TileCoord(4, -7), HexFrame.Q_NEG, TileCoord(3, -6), HexFrame.Q_POS),
        (TileCoord(0, -5), HexFrame.Q_NEG, TileCoord(-1, -4), HexFrame.Q_POS),
        (TileCoord(2, -7), HexFrame.Q_NEG, TileCoord(1, -6), HexFrame.Q_POS),
        (TileCoord(2, -7), HexFrame.Q_POS, TileCoord(4, -8), HexFrame.Q_NEG),
        (TileCoord(-4, -3), HexFrame.Q_POS, TileCoord(-2, -4), HexFrame.Q_NEG),
        (TileCoord(4, -5), HexFrame.Q_NEG, TileCoord(3, -5), HexFrame.Q_POS),
        (TileCoord(-1, -4), HexFrame.Q_POS, TileCoord(1, -5), HexFrame.Q_NEG),
        (TileCoord(3, -8), HexFrame.Q_NEG, TileCoord(2, -7), HexFrame.Q_POS),
        (TileCoord(2, -6), HexFrame.Q_NEG, TileCoord(1, -5), HexFrame.Q_POS),
        (TileCoord(4, -9), HexFrame.Q_NEG, TileCoord(3, -8), HexFrame.Q_POS),
        (TileCoord(-2, -4), HexFrame.Q_NEG, TileCoord(-3, -4), HexFrame.Q_POS),
        (TileCoord(4, -7), HexFrame.Q_NEG, TileCoord(3, -7), HexFrame.Q_POS),
        (TileCoord(3, -7), HexFrame.Q_POS, TileCoord(5, -8), HexFrame.Q_NEG),
        (TileCoord(1, -7), HexFrame.Q_POS, TileCoord(3, -8), HexFrame.Q_NEG),
        (TileCoord(3, -4), HexFrame.Q_NEG, TileCoord(2, -3), HexFrame.Q_POS),
        (TileCoord(2, -6), HexFrame.Q_NEG, TileCoord(1, -6), HexFrame.Q_POS),
        (TileCoord(3, -8), HexFrame.Q_POS, TileCoord(5, -9), HexFrame.Q_NEG),
        (TileCoord(5, -8), HexFrame.Q_NEG, TileCoord(4, -7), HexFrame.Q_POS),
        (TileCoord(2, -7), HexFrame.Q_NEG, TileCoord(1, -7), HexFrame.Q_POS),
        (TileCoord(-2, -4), HexFrame.Q_POS, TileCoord(0, -5), HexFrame.Q_NEG),
        (TileCoord(-1, -5), HexFrame.Q_NEG, TileCoord(-2, -4), HexFrame.Q_POS),
        (TileCoord(3, -6), HexFrame.Q_POS, TileCoord(5, -7), HexFrame.Q_NEG),
    ]
        blueprint_primary.pipe_behaviors[EdgeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = scrap_pipe
    end

    union!(blueprint_primary.ship_tiles, Set{TileCoord}([
        TileCoord(4, -8),
        TileCoord(3, -7),
        TileCoord(4, -9),
        TileCoord(2, -8),
        TileCoord(5, -7),
        TileCoord(3, -8),
        TileCoord(4, -6),
        TileCoord(5, -8),
        TileCoord(1, -5),
        TileCoord(2, -6),
        TileCoord(3, -9),
        TileCoord(1, -7),
        TileCoord(5, -9),
        TileCoord(4, -7),
        TileCoord(2, -5),
        TileCoord(2, -7),
        TileCoord(3, -6),
    ]))
    map = GameMap(blueprint_primary)
    merge_ship!(map, Symbol("##Ship AV-551#655"), blueprint_av_551)

    #= ---------- Ship :##old_primary#664 ----------- =#
    blueprint_old_primary = ShipBlueprint()

    for tile in [
        TileCoord(3, -3),
        TileCoord(2, 0),
        TileCoord(3, -2),
        TileCoord(1, -1),
        TileCoord(0, -1),
        TileCoord(1, 0),
        TileCoord(0, 0),
        TileCoord(-1, 0),
        TileCoord(0, 1),
        TileCoord(1, 1),
        TileCoord(2, -2),
        TileCoord(-1, 1),
        TileCoord(0, 2),
        TileCoord(2, -1),
        TileCoord(1, -2),
    ]
        blueprint_old_primary.components[tile] = ComponentOnTile(deepcopy(legacy_liquid_tank), HexFrame.Q_POS, :_blueprint)
    end

    for tile in [TileCoord(-5, -1), TileCoord(-5, 0), TileCoord(-5, 1)]
        blueprint_old_primary.components[tile] = ComponentOnTile(deepcopy(small_nozzle), HexFrame.Q_POS, :_blueprint)
    end

    blueprint_old_primary.components[TileCoord(-4, 0)] = ComponentOnTile(DecompChamberCompBehav(), HexFrame.Q_POS, :_blueprint)
    blueprint_old_primary.components[TileCoord(-4, 3)] = ComponentOnTile(DecompChamberCompBehav(), HexFrame.Q_POS, :_blueprint)
    blueprint_old_primary.components[TileCoord(-3, -1)] = single_tile_pipe_on_tile(HexFrame.S_POS, ScrapTilePipeBehavFrag())
    blueprint_old_primary.components[TileCoord(-3, 0)] = ComponentOnTile(deepcopy(turbo_pump), HexFrame.S_NEG, :_blueprint)
    blueprint_old_primary.components[TileCoord(-2, 2)] = ComponentOnTile(deepcopy(turbo_pump), HexFrame.Q_POS, :_blueprint)
    blueprint_old_primary.components[TileCoord(-4, -1)] = ComponentOnTile(deepcopy(tiny_on_off_valve), HexFrame.Q_POS, :_blueprint)
    blueprint_old_primary.components[TileCoord(-3, 2)] = ComponentOnTile(deepcopy(partially_open_legacy_valve), HexFrame.Q_POS, :_blueprint)
    blueprint_old_primary.components[TileCoord(-6, 4)] = ComponentOnTile(deepcopy(medium_nozzle), HexFrame.Q_POS, :_blueprint)
    for (tile_a, axis_a, tile_b, axis_b, behaviour) in [
        (TileCoord(1, -2), HexFrame.Q_NEG, TileCoord(0, -2), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-1, 0), HexFrame.Q_NEG, TileCoord(-2, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(0, 0), HexFrame.Q_NEG, TileCoord(-1, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-4, 3), HexFrame.Q_POS, TileCoord(-2, 2), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-4, 0), HexFrame.Q_NEG, TileCoord(-5, 1), HexFrame.Q_POS, big_pipe),
        (TileCoord(3, -3), HexFrame.Q_NEG, TileCoord(2, -3), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(0, 1), HexFrame.Q_NEG, TileCoord(-1, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-5, 3), HexFrame.Q_POS, TileCoord(-3, 2), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-2, 2), HexFrame.Q_POS, TileCoord(0, 1), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-3, 1), HexFrame.Q_POS, TileCoord(-1, 0), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-2, 1), HexFrame.Q_POS, TileCoord(0, 0), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(1, -2), HexFrame.Q_NEG, TileCoord(0, -1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-4, 3), HexFrame.Q_NEG, TileCoord(-5, 3), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-2, 0), HexFrame.Q_NEG, TileCoord(-3, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, 4), HexFrame.Q_POS, TileCoord(-4, 3), HexFrame.Q_NEG, big_pipe),
        (TileCoord(-1, 1), HexFrame.Q_POS, TileCoord(1, 0), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(2, -2), HexFrame.Q_NEG, TileCoord(1, -2), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-1, 0), HexFrame.Q_POS, TileCoord(1, -1), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(0, -1), HexFrame.Q_POS, TileCoord(2, -2), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(2, 0), HexFrame.Q_NEG, TileCoord(1, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(1, -1), HexFrame.Q_NEG, TileCoord(0, -1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-4, -1), HexFrame.Q_NEG, TileCoord(-5, -1), HexFrame.Q_POS, big_pipe),
        (TileCoord(-4, -1), HexFrame.Q_NEG, TileCoord(-5, 0), HexFrame.Q_POS, big_pipe),
        (TileCoord(0, 1), HexFrame.Q_POS, TileCoord(2, 0), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(0, 1), HexFrame.Q_NEG, TileCoord(-1, 2), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(0, 0), HexFrame.Q_NEG, TileCoord(-1, 0), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(1, 0), HexFrame.Q_NEG, TileCoord(0, 1), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(1, -2), HexFrame.Q_POS, TileCoord(3, -3), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-4, 0), HexFrame.Q_NEG, TileCoord(-5, 0), HexFrame.Q_POS, big_pipe),
    ]
        blueprint_old_primary.pipe_behaviors[EdgeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = behaviour
    end

    union!(blueprint_old_primary.ship_tiles, Set{TileCoord}([
        TileCoord(3, -3),
        TileCoord(2, 0),
        TileCoord(-4, 0),
        TileCoord(-3, -1),
        TileCoord(3, -2),
        TileCoord(1, -1),
        TileCoord(0, -1),
        TileCoord(-3, 0),
        TileCoord(1, 0),
        TileCoord(-4, 2),
        TileCoord(0, 0),
        TileCoord(-3, 1),
        TileCoord(-2, -1),
        TileCoord(-1, 0),
        TileCoord(1, 1),
        TileCoord(0, 1),
        TileCoord(2, -2),
        TileCoord(-4, 3),
        TileCoord(-4, 4),
        TileCoord(-1, 1),
        TileCoord(-2, 0),
        TileCoord(-3, 2),
        TileCoord(-2, 1),
        TileCoord(-3, 3),
        TileCoord(0, 2),
        TileCoord(-3, 4),
        TileCoord(-1, 2),
        TileCoord(2, -1),
        TileCoord(-5, 3),
        TileCoord(-2, 2),
        TileCoord(-4, -1),
        TileCoord(-5, 4),
        TileCoord(1, -2),
    ]))
    merge_ship!(map, Symbol("##old_primary#664"), blueprint_old_primary)

    #= ---------- Ship :##Platform BS-301#663 ----------- =#
    blueprint_platform_bs_301 = ShipBlueprint()

    for tile in [
        TileCoord(-4, -5),
        TileCoord(-4, -7),
        TileCoord(-5, -4),
        TileCoord(-4, -4),
        TileCoord(-5, -5),
        TileCoord(-4, -6),
    ]
        blueprint_platform_bs_301.components[tile] = ComponentOnTile(deepcopy(pressure_fed_tank), HexFrame.Q_POS, :_blueprint)
    end

    for tile in [TileCoord(-2, -7), TileCoord(-2, -8)]
        blueprint_platform_bs_301.components[tile] = ComponentOnTile(deepcopy(av_gas_tank), HexFrame.R_POS, :_blueprint)
    end

    for (tile, rotation) in [
        (TileCoord(-3, -10), HexFrame.Q_NEG),
        (TileCoord(-7, -6), HexFrame.Q_POS),
        (TileCoord(-7, -3), HexFrame.Q_POS),
        (TileCoord(-7, -5), HexFrame.Q_POS),
        (TileCoord(-7, -4), HexFrame.Q_POS),
        (TileCoord(-3, -8), HexFrame.Q_NEG),
        (TileCoord(-3, -9), HexFrame.Q_NEG),
    ]
        blueprint_platform_bs_301.components[tile] = ComponentOnTile(deepcopy(tiny_nozzle), rotation, :_blueprint)
    end

    blueprint_platform_bs_301.components[TileCoord(-6, -6)] = ComponentOnTile(DecompChamberCompBehav(), HexFrame.Q_POS, :_blueprint)
    blueprint_platform_bs_301.components[TileCoord(-4, -8)] = ComponentOnTile(DecompChamberCompBehav(), HexFrame.Q_NEG, :_blueprint)
    blueprint_platform_bs_301.components[TileCoord(-3, -7)] = ComponentOnTile(deepcopy(open_tiny_on_off_valve), HexFrame.Q_POS, :_blueprint)
    blueprint_platform_bs_301.components[TileCoord(-5, -6)] = ComponentOnTile(deepcopy(partially_open_platform_valve), HexFrame.S_NEG, :_blueprint)
    blueprint_platform_bs_301.components[TileCoord(-5, -7)] = ComponentOnTile(deepcopy(tiny_adjustable_valve), HexFrame.S_NEG, :_blueprint)
    for (tile_a, axis_a, tile_b, axis_b, behaviour) in [
        (TileCoord(-3, -5), HexFrame.Q_NEG, TileCoord(-4, -5), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -6), HexFrame.Q_NEG, TileCoord(-7, -5), HexFrame.Q_POS, big_pipe),
        (TileCoord(-5, -4), HexFrame.Q_NEG, TileCoord(-6, -3), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -5), HexFrame.Q_NEG, TileCoord(-7, -4), HexFrame.Q_POS, big_pipe),
        (TileCoord(0, -8), HexFrame.Q_NEG, TileCoord(-1, -8), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -4), HexFrame.Q_NEG, TileCoord(-7, -4), HexFrame.Q_POS, big_pipe),
        (TileCoord(-1, -8), HexFrame.Q_POS, TileCoord(1, -9), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-3, -8), HexFrame.Q_NEG, TileCoord(-4, -8), HexFrame.Q_POS, big_pipe),
        (TileCoord(-2, -9), HexFrame.Q_POS, TileCoord(0, -10), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-6, -5), HexFrame.Q_NEG, TileCoord(-7, -5), HexFrame.Q_POS, big_pipe),
        (TileCoord(-6, -4), HexFrame.Q_POS, TileCoord(-4, -5), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-4, -7), HexFrame.Q_NEG, TileCoord(-5, -6), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -4), HexFrame.Q_NEG, TileCoord(-7, -3), HexFrame.Q_POS, big_pipe),
        (TileCoord(-3, -4), HexFrame.Q_NEG, TileCoord(-4, -3), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-3, -8), HexFrame.Q_POS, TileCoord(-1, -9), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-3, -7), HexFrame.Q_NEG, TileCoord(-4, -6), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-3, -9), HexFrame.Q_NEG, TileCoord(-4, -9), HexFrame.Q_POS, big_pipe),
        (TileCoord(-6, -7), HexFrame.Q_POS, TileCoord(-4, -8), HexFrame.Q_NEG, big_pipe),
        (TileCoord(-3, -7), HexFrame.Q_NEG, TileCoord(-4, -7), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-3, -9), HexFrame.Q_NEG, TileCoord(-4, -8), HexFrame.Q_POS, big_pipe),
        (TileCoord(-4, -6), HexFrame.Q_NEG, TileCoord(-5, -6), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(3, -11), HexFrame.Q_NEG, TileCoord(2, -11), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-1, -10), HexFrame.Q_POS, TileCoord(1, -11), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-5, -5), HexFrame.Q_NEG, TileCoord(-6, -4), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -5), HexFrame.Q_POS, TileCoord(-4, -6), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(0, -9), HexFrame.Q_POS, TileCoord(2, -10), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-6, -3), HexFrame.Q_POS, TileCoord(-4, -4), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(2, -10), HexFrame.Q_NEG, TileCoord(1, -10), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-5, -4), HexFrame.Q_NEG, TileCoord(-6, -4), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(1, -9), HexFrame.Q_NEG, TileCoord(0, -9), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(0, -10), HexFrame.Q_NEG, TileCoord(-1, -10), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-3, -6), HexFrame.Q_NEG, TileCoord(-4, -6), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-3, -5), HexFrame.Q_NEG, TileCoord(-4, -4), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-5, -3), HexFrame.Q_POS, TileCoord(-3, -4), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-3, -6), HexFrame.Q_NEG, TileCoord(-4, -5), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-2, -7), HexFrame.Q_POS, TileCoord(0, -8), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(1, -10), HexFrame.Q_POS, TileCoord(3, -11), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-3, -10), HexFrame.Q_NEG, TileCoord(-4, -9), HexFrame.Q_POS, big_pipe),
        (TileCoord(-5, -5), HexFrame.Q_POS, TileCoord(-3, -6), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-5, -4), HexFrame.Q_POS, TileCoord(-3, -5), HexFrame.Q_NEG, scrap_pipe),
        (TileCoord(-1, -9), HexFrame.Q_NEG, TileCoord(-2, -9), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-6, -6), HexFrame.Q_NEG, TileCoord(-7, -6), HexFrame.Q_POS, big_pipe),
        (TileCoord(-5, -5), HexFrame.Q_NEG, TileCoord(-6, -5), HexFrame.Q_POS, scrap_pipe),
        (TileCoord(-4, -4), HexFrame.Q_NEG, TileCoord(-5, -3), HexFrame.Q_POS, scrap_pipe),
    ]
        blueprint_platform_bs_301.pipe_behaviors[EdgeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = behaviour
    end

    union!(blueprint_platform_bs_301.ship_tiles, Set{TileCoord}([
        TileCoord(-4, -5),
        TileCoord(-4, -7),
        TileCoord(-2, -7),
        TileCoord(-5, -4),
        TileCoord(-4, -4),
        TileCoord(-3, -6),
        TileCoord(-6, -6),
        TileCoord(-2, -8),
        TileCoord(-4, -8),
        TileCoord(-3, -7),
        TileCoord(-6, -5),
        TileCoord(-4, -9),
        TileCoord(-5, -6),
        TileCoord(-6, -4),
        TileCoord(-5, -5),
        TileCoord(-5, -7),
        TileCoord(-4, -6),
    ]))
    merge_ship!(map, Symbol("##Platform BS-301#663"), blueprint_platform_bs_301)

    return map
end
