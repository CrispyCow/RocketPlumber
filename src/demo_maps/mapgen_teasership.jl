#=
Scope: Five-ship teasership2 sandbox map with biprop engine, cold-gas tugs, and monoprop platform
Formatter: Runic
=#

"""
    mapgen_teasership()

Hand-authored encoding of the teasership2 sandbox map.
Five-ship layout: a biprop engine (:primary), two liquid-propellant tankers
(oxidiser and fuel), a cold-gas manoeuvring craft, and a monoprop refuelling
platform.
"""
function mapgen_teasership()

    # Shared immutable templates

    oxidiser_liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.OXIDISER_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )
    fuel_liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.FUEL_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )
    cold_gas_tank = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 50.0,
        max_voltage = 50.0,
        initial_charge = 40.0,
        series_conductance = 5.0
    )
    monoprop_liquid_tank = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 30.0,
        series_conductance = 5.0
    )
    # Partially pressurised -- gas charge is 5.0, not empty.
    pressure_fed_monoprop_tank = PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = 30.0,
            initial_gas_charge = 5.0,
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
    turbo_pump = TurboPumpCompBehav(
        max_pump_voltage = 50.0,
        series_conductance = 1.0,
    )
    small_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.5,
        sprite_variant = SMALL_NOZZLE_SPRITE
    )
    medium_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 1.5,
        sprite_variant = MEDIUM_NOZZLE_SPRITE
    )
    tiny_nozzle = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.2,
        sprite_variant = TINY_NOZZLE_SPRITE
    )
    # Valves are armed (target = max) but not yet open (current = 0).
    open_large_valve = StandardValveCompBehav(
        BoolSwitchBehavFrag, LARGE_VALVE;
        max_conductance = 4.0,
        growth_factor = calculate_growth_factor(4.0, 0.0, 2.0 / BASE_UPS),
        target_conductance = 4.0,
        current_conductance = 0.0
    )
    # Fully open -- both target and current at max.
    open_tiny_valve = StandardValveCompBehav(
        BoolSwitchBehavFrag, TINY_VALVE;
        max_conductance = 1.0,
        growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
        target_conductance = 1.0,
        current_conductance = 1.0
    )
    scrap_pipe = ScrapPipeBehav()
    big_pipe = BigPipeBehav()

    # Standard cold-gas switched nozzle, armed but not yet open.
    # Internal construction is required to set target_conductance to max
    # because the public constructor always starts closed.
    armed_cold_gas_nozzle = SwitchedNozzleCompBehav(
        NozzleBehavFrag(
            HexFrame.NODE_INTERNAL_1,
            0.2,
            AutoDeactivationState(),
            OverheatLimitBehavFrag(400.0, 1.0, 0.3)
        ),
        BoolSwitchBehavFrag(
            SwitchBehavFrag(
                RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_INTERNAL_1),
                2.0,
                0.0,
                calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
                HexFlowSwitchComponents.SwitchState(2.0, 0.0)
            )
        )
    )

    # ===============================================================
    # Ship Construction
    # ===============================================================

    #= ---------- Ship :primary (biprop engine) ---------- =#
    blueprint_primary = ShipBlueprint()

    for (tile, rotation) in [
            (TileCoord(-7, -3), HexFrame.Q_POS),
            (TileCoord(-6, -4), HexFrame.Q_POS),
        ]
        blueprint_primary.components[tile] = PlacedComponent(small_nozzle, rotation, :_blueprint)
    end
    blueprint_primary.components[TileCoord(-7, -2)] = PlacedComponent(medium_nozzle, HexFrame.Q_POS, :_blueprint)

    for (tile, rotation) in [
            (TileCoord(-5, -3), HexFrame.Q_POS),
            (TileCoord(-2, -5), HexFrame.R_NEG),
        ]
        blueprint_primary.components[tile] = PlacedComponent(BipropChamberCompBehav(), rotation, :_blueprint)
    end

    blueprint_primary.components[TileCoord(-3, -5)] = PlacedComponent(turbo_pump, HexFrame.R_NEG, :_blueprint)
    # Mirrored turbopump on the other side.
    blueprint_primary.components[TileCoord(-3, -3)] = PlacedComponent(turbo_pump, HexFrame.S_NEG, true, :_blueprint)

    for tile in [TileCoord(-2, -6), TileCoord(-2, -3)]
        blueprint_primary.components[tile] = PlacedComponent(open_large_valve, HexFrame.Q_POS, :_blueprint)
    end
    blueprint_primary.components[TileCoord(-2, -4)] = PlacedComponent(open_tiny_valve, HexFrame.Q_POS, :_blueprint)

    for (tile_a, axis_a, tile_b, axis_b, behaviour) in [
            (TileCoord(-7, -3), HexFrame.Q_POS, TileCoord(-5, -3), HexFrame.Q_NEG, big_pipe),
            (TileCoord(-7, -2), HexFrame.Q_POS, TileCoord(-5, -3), HexFrame.Q_NEG, big_pipe),
            (TileCoord(-6, -3), HexFrame.Q_POS, TileCoord(-6, -4), HexFrame.Q_POS, big_pipe),
            (TileCoord(-5, -3), HexFrame.Q_NEG, TileCoord(-6, -3), HexFrame.Q_POS, big_pipe),
            (TileCoord(-4, -4), HexFrame.Q_POS, TileCoord(-2, -5), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-4, -4), HexFrame.Q_NEG, TileCoord(-4, -4), HexFrame.Q_POS, big_pipe),
            (TileCoord(-4, -3), HexFrame.Q_POS, TileCoord(-2, -4), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-4, -3), HexFrame.Q_NEG, TileCoord(-4, -3), HexFrame.Q_POS, big_pipe),
            (TileCoord(-3, -4), HexFrame.Q_NEG, TileCoord(-3, -5), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-3, -4), HexFrame.Q_NEG, TileCoord(-3, -4), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-3, -3), HexFrame.Q_NEG, TileCoord(-3, -4), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, -5), HexFrame.Q_NEG, TileCoord(-3, -5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, -4), HexFrame.Q_POS, TileCoord(-2, -5), HexFrame.Q_POS, scrap_pipe),
        ]
        blueprint_primary.pipe_behaviors[PipeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = behaviour
    end

    union!(
        blueprint_primary.ship_tiles, Set{TileCoord}(
            [
                TileCoord(-6, -3),
                TileCoord(-5, -4),
                TileCoord(-5, -3),
                TileCoord(-4, -4),
                TileCoord(-4, -3),
                TileCoord(-3, -5),
                TileCoord(-3, -4),
                TileCoord(-3, -3),
                TileCoord(-3, -2),
                TileCoord(-2, -6),
                TileCoord(-2, -5),
                TileCoord(-2, -4),
                TileCoord(-2, -3),
                TileCoord(-1, -5),
                TileCoord(-1, -4),
            ]
        )
    )

    #= ---------- Ship ##Craft CL-204#148 (oxidiser tanker) ---------- =#
    blueprint_cl_204 = ShipBlueprint()

    for tile in [
            TileCoord(-1, 0),
            TileCoord(-1, 1),
            TileCoord(0, -2),
            TileCoord(0, -1),
            TileCoord(0, 0),
            TileCoord(0, 1),
            TileCoord(0, 2),
            TileCoord(1, -2),
            TileCoord(1, -1),
            TileCoord(1, 0),
            TileCoord(1, 1),
            TileCoord(2, -4),
            TileCoord(2, -3),
            TileCoord(2, -2),
            TileCoord(2, -1),
            TileCoord(2, 0),
            TileCoord(3, -3),
            TileCoord(3, -2),
            TileCoord(3, -1),
            TileCoord(4, -4),
            TileCoord(4, -3),
            TileCoord(4, -2),
            TileCoord(4, -1),
            TileCoord(4, 0),
            TileCoord(5, -5),
            TileCoord(5, -4),
            TileCoord(5, -3),
            TileCoord(5, -2),
            TileCoord(5, -1),
        ]
        blueprint_cl_204.components[tile] = PlacedComponent(oxidiser_liquid_tank, HexFrame.Q_NEG, :_blueprint)
    end

    for (tile_a, axis_a, tile_b, axis_b) in [
            (TileCoord(-2, -3), HexFrame.Q_POS, TileCoord(-1, -3), HexFrame.Q_POS),
            (TileCoord(-2, -2), HexFrame.Q_POS, TileCoord(-2, -3), HexFrame.Q_POS),
            (TileCoord(-2, -2), HexFrame.Q_POS, TileCoord(0, -2), HexFrame.Q_NEG),
            (TileCoord(-1, -3), HexFrame.Q_POS, TileCoord(1, -3), HexFrame.Q_NEG),
            (TileCoord(-1, -1), HexFrame.Q_POS, TileCoord(1, -2), HexFrame.Q_NEG),
            (TileCoord(-1, 1), HexFrame.Q_POS, TileCoord(1, 0), HexFrame.Q_NEG),
            (TileCoord(0, -2), HexFrame.Q_POS, TileCoord(2, -3), HexFrame.Q_NEG),
            (TileCoord(0, -2), HexFrame.Q_NEG, TileCoord(-1, -1), HexFrame.Q_POS),
            (TileCoord(0, 0), HexFrame.Q_POS, TileCoord(2, -1), HexFrame.Q_NEG),
            (TileCoord(0, 1), HexFrame.Q_POS, TileCoord(2, 0), HexFrame.Q_NEG),
            (TileCoord(0, 1), HexFrame.Q_NEG, TileCoord(-1, 1), HexFrame.Q_POS),
            (TileCoord(1, -3), HexFrame.Q_NEG, TileCoord(0, -2), HexFrame.Q_POS),
            (TileCoord(1, -2), HexFrame.Q_POS, TileCoord(3, -3), HexFrame.Q_NEG),
            (TileCoord(1, -2), HexFrame.Q_NEG, TileCoord(0, -1), HexFrame.Q_POS),
            (TileCoord(1, -1), HexFrame.Q_POS, TileCoord(3, -2), HexFrame.Q_NEG),
            (TileCoord(1, -1), HexFrame.Q_NEG, TileCoord(0, -1), HexFrame.Q_POS),
            (TileCoord(1, -1), HexFrame.Q_NEG, TileCoord(0, 0), HexFrame.Q_POS),
            (TileCoord(1, 0), HexFrame.Q_NEG, TileCoord(0, 0), HexFrame.Q_POS),
            (TileCoord(1, 0), HexFrame.Q_NEG, TileCoord(0, 1), HexFrame.Q_POS),
            (TileCoord(2, -3), HexFrame.Q_NEG, TileCoord(1, -2), HexFrame.Q_POS),
            (TileCoord(2, -2), HexFrame.Q_POS, TileCoord(4, -3), HexFrame.Q_NEG),
            (TileCoord(2, -1), HexFrame.Q_NEG, TileCoord(1, -1), HexFrame.Q_POS),
            (TileCoord(3, -3), HexFrame.Q_POS, TileCoord(5, -4), HexFrame.Q_NEG),
            (TileCoord(3, -3), HexFrame.Q_NEG, TileCoord(2, -2), HexFrame.Q_POS),
            (TileCoord(3, -2), HexFrame.Q_POS, TileCoord(5, -3), HexFrame.Q_NEG),
            (TileCoord(4, -3), HexFrame.Q_NEG, TileCoord(3, -3), HexFrame.Q_POS),
            (TileCoord(4, -3), HexFrame.Q_NEG, TileCoord(3, -2), HexFrame.Q_POS),
            (TileCoord(5, -3), HexFrame.Q_NEG, TileCoord(4, -2), HexFrame.Q_POS),
            (TileCoord(5, -2), HexFrame.Q_NEG, TileCoord(4, -2), HexFrame.Q_POS),
            (TileCoord(5, -2), HexFrame.Q_NEG, TileCoord(4, -1), HexFrame.Q_POS),
            (TileCoord(5, -1), HexFrame.Q_NEG, TileCoord(4, -1), HexFrame.Q_POS),
        ]
        blueprint_cl_204.pipe_behaviors[PipeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = big_pipe
    end

    union!(
        blueprint_cl_204.ship_tiles, Set{TileCoord}(
            [
                TileCoord(-1, 0),
                TileCoord(-1, 1),
                TileCoord(0, -2),
                TileCoord(0, -1),
                TileCoord(0, 0),
                TileCoord(0, 1),
                TileCoord(0, 2),
                TileCoord(1, -2),
                TileCoord(1, -1),
                TileCoord(1, 0),
                TileCoord(1, 1),
                TileCoord(2, -4),
                TileCoord(2, -3),
                TileCoord(2, -2),
                TileCoord(2, -1),
                TileCoord(2, 0),
                TileCoord(3, -3),
                TileCoord(3, -2),
                TileCoord(3, -1),
                TileCoord(4, -4),
                TileCoord(4, -3),
                TileCoord(4, -2),
                TileCoord(4, -1),
                TileCoord(4, 0),
                TileCoord(5, -5),
                TileCoord(5, -4),
                TileCoord(5, -3),
                TileCoord(5, -2),
                TileCoord(5, -1),
            ]
        )
    )

    #= ---------- Ship ##Craft XB-882#144 (fuel tanker) ---------- =#
    blueprint_xb_882_144 = ShipBlueprint()

    for tile in [
            TileCoord(1, -10),
            TileCoord(1, -9),
            TileCoord(1, -8),
            TileCoord(2, -11),
            TileCoord(2, -10),
            TileCoord(2, -9),
            TileCoord(2, -8),
            TileCoord(3, -11),
            TileCoord(3, -10),
            TileCoord(3, -9),
            TileCoord(3, -8),
            TileCoord(3, -7),
            TileCoord(4, -12),
            TileCoord(4, -11),
            TileCoord(4, -10),
            TileCoord(4, -9),
            TileCoord(4, -8),
            TileCoord(5, -12),
            TileCoord(5, -11),
            TileCoord(5, -10),
            TileCoord(5, -9),
            TileCoord(6, -13),
            TileCoord(6, -12),
        ]
        blueprint_xb_882_144.components[tile] = PlacedComponent(fuel_liquid_tank, HexFrame.Q_POS, :_blueprint)
    end

    for (tile_a, axis_a, tile_b, axis_b) in [
            (TileCoord(-2, -6), HexFrame.Q_POS, TileCoord(-1, -7), HexFrame.Q_POS),
            (TileCoord(-1, -7), HexFrame.Q_POS, TileCoord(0, -8), HexFrame.Q_POS),
            (TileCoord(-1, -7), HexFrame.Q_POS, TileCoord(0, -7), HexFrame.Q_POS),
            (TileCoord(0, -8), HexFrame.Q_POS, TileCoord(2, -9), HexFrame.Q_NEG),
            (TileCoord(1, -9), HexFrame.Q_POS, TileCoord(3, -10), HexFrame.Q_NEG),
            (TileCoord(2, -10), HexFrame.Q_POS, TileCoord(4, -11), HexFrame.Q_NEG),
            (TileCoord(2, -9), HexFrame.Q_POS, TileCoord(4, -10), HexFrame.Q_NEG),
            (TileCoord(2, -9), HexFrame.Q_NEG, TileCoord(1, -9), HexFrame.Q_POS),
            (TileCoord(2, -8), HexFrame.Q_POS, TileCoord(4, -9), HexFrame.Q_NEG),
            (TileCoord(3, -11), HexFrame.Q_POS, TileCoord(5, -12), HexFrame.Q_NEG),
            (TileCoord(3, -10), HexFrame.Q_NEG, TileCoord(2, -10), HexFrame.Q_POS),
            (TileCoord(3, -10), HexFrame.Q_NEG, TileCoord(2, -9), HexFrame.Q_POS),
            (TileCoord(3, -9), HexFrame.Q_POS, TileCoord(5, -10), HexFrame.Q_NEG),
            (TileCoord(4, -12), HexFrame.Q_POS, TileCoord(6, -13), HexFrame.Q_NEG),
            (TileCoord(4, -12), HexFrame.Q_NEG, TileCoord(3, -11), HexFrame.Q_POS),
            (TileCoord(4, -11), HexFrame.Q_NEG, TileCoord(3, -11), HexFrame.Q_POS),
            (TileCoord(4, -10), HexFrame.Q_NEG, TileCoord(3, -9), HexFrame.Q_POS),
            (TileCoord(4, -9), HexFrame.Q_NEG, TileCoord(3, -9), HexFrame.Q_POS),
            (TileCoord(5, -12), HexFrame.Q_NEG, TileCoord(4, -12), HexFrame.Q_POS),
            (TileCoord(5, -10), HexFrame.Q_NEG, TileCoord(4, -10), HexFrame.Q_POS),
        ]
        blueprint_xb_882_144.pipe_behaviors[PipeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = big_pipe
    end

    union!(
        blueprint_xb_882_144.ship_tiles, Set{TileCoord}(
            [
                TileCoord(1, -10),
                TileCoord(1, -9),
                TileCoord(1, -8),
                TileCoord(2, -11),
                TileCoord(2, -10),
                TileCoord(2, -9),
                TileCoord(2, -8),
                TileCoord(3, -11),
                TileCoord(3, -10),
                TileCoord(3, -9),
                TileCoord(3, -8),
                TileCoord(3, -7),
                TileCoord(4, -12),
                TileCoord(4, -11),
                TileCoord(4, -10),
                TileCoord(4, -9),
                TileCoord(4, -8),
                TileCoord(5, -12),
                TileCoord(5, -11),
                TileCoord(5, -10),
                TileCoord(5, -9),
                TileCoord(6, -13),
                TileCoord(6, -12),
            ]
        )
    )

    #= ---------- Ship ##Craft XB-882#150 (cold-gas manoeuvring) ---------- =#
    blueprint_xb_882_150 = ShipBlueprint()

    for tile in [
            TileCoord(-7, 3),
            TileCoord(-7, 4),
            TileCoord(-6, 3),
            TileCoord(-6, 4),
            TileCoord(-6, 5),
            TileCoord(-5, 2),
            TileCoord(-5, 3),
            TileCoord(-5, 4),
            TileCoord(-4, 1),
            TileCoord(-4, 2),
        ]
        blueprint_xb_882_150.components[tile] = PlacedComponent(cold_gas_tank, HexFrame.R_NEG, :_blueprint)
    end

    # Standard armed nozzles (axial orientation).
    for tile in [TileCoord(-7, 5), TileCoord(-6, 6)]
        blueprint_xb_882_150.components[tile] = PlacedComponent(armed_cold_gas_nozzle, HexFrame.R_NEG, :_blueprint)
    end

    # Diagonal nozzles -- tuned throat areas from in-game adjustments.
    blueprint_xb_882_150.components[TileCoord(-6, 2)] = PlacedComponent(
        SwitchedNozzleCompBehav(
            NozzleBehavFrag(
                HexFrame.NODE_INTERNAL_1,
                0.1561048474162817,
                AutoDeactivationState(),
                OverheatLimitBehavFrag(400.0, 1.0, 0.3)
            ),
            BoolSwitchBehavFrag(
                SwitchBehavFrag(
                    RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_INTERNAL_1),
                    1.122096948325634,
                    0.0,
                    1.6521566588887608,
                    HexFlowSwitchComponents.SwitchState(1.122096948325634, 0.0)
                )
            )
        ),
        HexFrame.S_NEG,
        :_blueprint
    )
    blueprint_xb_882_150.components[TileCoord(-5, 1)] = PlacedComponent(
        SwitchedNozzleCompBehav(
            NozzleBehavFrag(
                HexFrame.NODE_INTERNAL_1,
                0.15860411077737807,
                AutoDeactivationState(),
                OverheatLimitBehavFrag(400.0, 1.0, 0.3)
            ),
            BoolSwitchBehavFrag(
                SwitchBehavFrag(
                    RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_INTERNAL_1),
                    1.1720822155475616,
                    0.0,
                    1.6360695216571548,
                    HexFlowSwitchComponents.SwitchState(1.1720822155475616, 0.0)
                )
            )
        ),
        HexFrame.S_NEG,
        :_blueprint
    )

    # Closed feed valve.
    blueprint_xb_882_150.components[TileCoord(-4, 3)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS)
        ),
        HexFrame.S_POS,
        :_blueprint
    )

    for (tile_a, axis_a, tile_b, axis_b) in [
            (TileCoord(-7, 5), HexFrame.Q_POS, TileCoord(-5, 4), HexFrame.Q_NEG),
            (TileCoord(-6, 3), HexFrame.Q_POS, TileCoord(-4, 2), HexFrame.Q_NEG),
            (TileCoord(-6, 4), HexFrame.Q_POS, TileCoord(-4, 3), HexFrame.Q_NEG),
            (TileCoord(-6, 4), HexFrame.Q_NEG, TileCoord(-7, 5), HexFrame.Q_POS),
            (TileCoord(-5, 2), HexFrame.Q_NEG, TileCoord(-6, 3), HexFrame.Q_POS),
            (TileCoord(-5, 4), HexFrame.Q_NEG, TileCoord(-6, 4), HexFrame.Q_POS),
            (TileCoord(-4, 2), HexFrame.Q_NEG, TileCoord(-5, 3), HexFrame.Q_POS),
            (TileCoord(-4, 3), HexFrame.Q_NEG, TileCoord(-5, 3), HexFrame.Q_POS),
            (TileCoord(-4, 4), HexFrame.Q_POS, TileCoord(-2, 4), HexFrame.Q_NEG),
            (TileCoord(-3, 3), HexFrame.Q_NEG, TileCoord(-4, 4), HexFrame.Q_POS),
            (TileCoord(-2, 4), HexFrame.Q_NEG, TileCoord(-1, 4), HexFrame.Q_NEG),
        ]
        blueprint_xb_882_150.pipe_behaviors[PipeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = scrap_pipe
    end

    union!(
        blueprint_xb_882_150.ship_tiles, Set{TileCoord}(
            [
                TileCoord(-7, 3),
                TileCoord(-7, 4),
                TileCoord(-6, 3),
                TileCoord(-6, 4),
                TileCoord(-6, 5),
                TileCoord(-5, 2),
                TileCoord(-5, 3),
                TileCoord(-5, 4),
                TileCoord(-4, 1),
                TileCoord(-4, 2),
                TileCoord(-4, 3),
            ]
        )
    )

    #= ---------- Ship ##Platform HX-034#152 (monoprop platform) ---------- =#
    blueprint_platform = ShipBlueprint()

    for tile in [
            TileCoord(1, 4),
            TileCoord(1, 5),
            TileCoord(1, 6),
            TileCoord(1, 7),
            TileCoord(2, 4),
            TileCoord(2, 5),
            TileCoord(2, 6),
            TileCoord(2, 7),
            TileCoord(3, 4),
            TileCoord(3, 5),
            TileCoord(3, 6),
            TileCoord(4, 4),
            TileCoord(4, 5),
        ]
        blueprint_platform.components[tile] = PlacedComponent(monoprop_liquid_tank, HexFrame.Q_POS, :_blueprint)
    end

    for tile in [
            TileCoord(-2, 5),
            TileCoord(-2, 6),
            TileCoord(-2, 7),
            TileCoord(-2, 8),
            TileCoord(-1, 5),
            TileCoord(-1, 6),
            TileCoord(-1, 7),
        ]
        blueprint_platform.components[tile] = PlacedComponent(pressure_fed_monoprop_tank, HexFrame.Q_POS, :_blueprint)
    end

    for tile in [TileCoord(-6, 11), TileCoord(-6, 12)]
        blueprint_platform.components[tile] = PlacedComponent(small_nozzle, HexFrame.Q_POS, :_blueprint)
    end
    for tile in [TileCoord(-5, 7), TileCoord(-5, 8)]
        blueprint_platform.components[tile] = PlacedComponent(tiny_nozzle, HexFrame.Q_POS, :_blueprint)
    end

    for tile in [TileCoord(-4, 7), TileCoord(-4, 11)]
        blueprint_platform.components[tile] = PlacedComponent(DecompChamberCompBehav(), HexFrame.Q_POS, :_blueprint)
    end

    blueprint_platform.components[TileCoord(-2, 10)] = PlacedComponent(turbo_pump, HexFrame.Q_POS, :_blueprint)

    # Valve at (-3, 7): armed open (target = max, current = 0).
    blueprint_platform.components[TileCoord(-3, 7)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            target_conductance = 1.0,
            current_conductance = 0.0
        ),
        HexFrame.S_POS,
        :_blueprint
    )
    # Valve at (-1, 8): closed.
    blueprint_platform.components[TileCoord(-1, 8)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS)
        ),
        HexFrame.Q_NEG,
        :_blueprint
    )
    # Stepped valve at (-3, 10): partially open target.
    blueprint_platform.components[TileCoord(-3, 10)] = PlacedComponent(
        StandardValveCompBehav(
            SteppedSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            percentage_step_size = 0.05,
            target_conductance = 0.031939676627404275,
            current_conductance = 0.0
        ),
        HexFrame.Q_POS,
        :_blueprint
    )
    # Large valve at (-1, 9): armed open (target = max, current = 0).
    blueprint_platform.components[TileCoord(-1, 9)] = PlacedComponent(
        open_large_valve, HexFrame.R_NEG, :_blueprint
    )

    for (tile_a, axis_a, tile_b, axis_b, behaviour) in [
            (TileCoord(-6, 11), HexFrame.Q_POS, TileCoord(-4, 11), HexFrame.Q_NEG, big_pipe),
            (TileCoord(-6, 12), HexFrame.Q_POS, TileCoord(-4, 11), HexFrame.Q_NEG, big_pipe),
            (TileCoord(-5, 11), HexFrame.Q_POS, TileCoord(-3, 10), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-4, 7), HexFrame.Q_NEG, TileCoord(-5, 7), HexFrame.Q_POS, big_pipe),
            (TileCoord(-4, 7), HexFrame.Q_NEG, TileCoord(-5, 8), HexFrame.Q_POS, big_pipe),
            (TileCoord(-4, 11), HexFrame.Q_POS, TileCoord(-2, 10), HexFrame.Q_NEG, big_pipe),
            (TileCoord(-4, 11), HexFrame.Q_NEG, TileCoord(-5, 11), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-3, 6), HexFrame.Q_POS, TileCoord(-1, 5), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-3, 7), HexFrame.Q_POS, TileCoord(-1, 6), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-3, 8), HexFrame.Q_POS, TileCoord(-1, 7), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-3, 9), HexFrame.Q_POS, TileCoord(-1, 8), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, 5), HexFrame.Q_POS, TileCoord(0, 4), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, 5), HexFrame.Q_NEG, TileCoord(-3, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 6), HexFrame.Q_POS, TileCoord(0, 5), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, 6), HexFrame.Q_NEG, TileCoord(-3, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 6), HexFrame.Q_NEG, TileCoord(-3, 7), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 7), HexFrame.Q_POS, TileCoord(0, 6), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, 7), HexFrame.Q_NEG, TileCoord(-3, 7), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 7), HexFrame.Q_NEG, TileCoord(-3, 8), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 8), HexFrame.Q_POS, TileCoord(0, 7), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(-2, 8), HexFrame.Q_NEG, TileCoord(-3, 8), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-2, 8), HexFrame.Q_NEG, TileCoord(-3, 9), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-1, 4), HexFrame.Q_NEG, TileCoord(-2, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(-1, 8), HexFrame.Q_POS, TileCoord(0, 7), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 4), HexFrame.Q_NEG, TileCoord(-1, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 5), HexFrame.Q_NEG, TileCoord(-1, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 5), HexFrame.Q_NEG, TileCoord(-1, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 6), HexFrame.Q_NEG, TileCoord(-1, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 6), HexFrame.Q_NEG, TileCoord(-1, 7), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 7), HexFrame.Q_POS, TileCoord(2, 6), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(0, 7), HexFrame.Q_NEG, TileCoord(-1, 7), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(0, 8), HexFrame.Q_POS, TileCoord(2, 7), HexFrame.Q_NEG, big_pipe),
            (TileCoord(0, 8), HexFrame.Q_NEG, TileCoord(0, 8), HexFrame.Q_POS, big_pipe),
            (TileCoord(1, 5), HexFrame.Q_POS, TileCoord(3, 4), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(1, 6), HexFrame.Q_POS, TileCoord(3, 5), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(1, 7), HexFrame.Q_POS, TileCoord(3, 6), HexFrame.Q_NEG, big_pipe),
            (TileCoord(2, 5), HexFrame.Q_POS, TileCoord(4, 4), HexFrame.Q_NEG, scrap_pipe),
            (TileCoord(2, 6), HexFrame.Q_POS, TileCoord(4, 5), HexFrame.Q_NEG, big_pipe),
            (TileCoord(2, 6), HexFrame.Q_NEG, TileCoord(1, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(2, 7), HexFrame.Q_NEG, TileCoord(1, 7), HexFrame.Q_POS, big_pipe),
            (TileCoord(3, 4), HexFrame.Q_NEG, TileCoord(2, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(3, 5), HexFrame.Q_NEG, TileCoord(2, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(3, 5), HexFrame.Q_NEG, TileCoord(2, 6), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(3, 6), HexFrame.Q_NEG, TileCoord(2, 6), HexFrame.Q_POS, big_pipe),
            (TileCoord(4, 4), HexFrame.Q_NEG, TileCoord(3, 5), HexFrame.Q_POS, scrap_pipe),
            (TileCoord(4, 5), HexFrame.Q_NEG, TileCoord(3, 5), HexFrame.Q_POS, big_pipe),
        ]
        blueprint_platform.pipe_behaviors[PipeCoord(VertexCoord(tile_a, axis_a), VertexCoord(tile_b, axis_b))] = behaviour
    end

    union!(
        blueprint_platform.ship_tiles, Set{TileCoord}(
            [
                TileCoord(-5, 11),
                TileCoord(-4, 7),
                TileCoord(-4, 10),
                TileCoord(-4, 11),
                TileCoord(-3, 6),
                TileCoord(-3, 7),
                TileCoord(-3, 8),
                TileCoord(-3, 9),
                TileCoord(-3, 10),
                TileCoord(-3, 11),
                TileCoord(-2, 5),
                TileCoord(-2, 6),
                TileCoord(-2, 7),
                TileCoord(-2, 8),
                TileCoord(-2, 9),
                TileCoord(-2, 10),
                TileCoord(-1, 5),
                TileCoord(-1, 6),
                TileCoord(-1, 7),
                TileCoord(-1, 8),
                TileCoord(-1, 9),
                TileCoord(0, 5),
                TileCoord(0, 6),
                TileCoord(0, 7),
                TileCoord(0, 8),
                TileCoord(0, 9),
                TileCoord(1, 4),
                TileCoord(1, 5),
                TileCoord(1, 6),
                TileCoord(1, 7),
                TileCoord(1, 8),
                TileCoord(2, 4),
                TileCoord(2, 5),
                TileCoord(2, 6),
                TileCoord(2, 7),
                TileCoord(3, 4),
                TileCoord(3, 5),
                TileCoord(3, 6),
                TileCoord(4, 4),
                TileCoord(4, 5),
            ]
        )
    )

    map = GameMap(blueprint_primary)
    merge_ship!(map, Symbol("##Craft CL-204#148"), blueprint_cl_204)
    merge_ship!(map, Symbol("##Craft XB-882#144"), blueprint_xb_882_144)
    merge_ship!(map, Symbol("##Craft XB-882#150"), blueprint_xb_882_150)
    merge_ship!(map, Symbol("##Platform HX-034#152"), blueprint_platform)
    return map
end
