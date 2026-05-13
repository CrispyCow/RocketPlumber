"""
    mapgen_liquidtransfer()

Fluid transfer sandbox map with three separate ships: the stranded primary craft,
a nearby tanker full of monopropellant, and a small debris hulk carrying a transfer pump.
"""
function mapgen_liquidtransfer()
    empty_liquid_tank_template = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 10.0,
        max_voltage = 1.0,
        initial_charge = 0.0,
        series_conductance = 5.0
    )

    full_liquid_tank_template = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 10.0,
        max_voltage = 1.0,
        initial_charge = 9.0,
        series_conductance = 5.0
    )

    gas_tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 50.0,
        max_voltage = 50.0,
        initial_charge = 40.0,
        series_conductance = 5.0
    )

    nozzle_template = SwitchedNozzleCompBehav(
        throat_area = 0.2,
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
        limit_temperature_k = 400.0
    )

    # Primary ship: empty monopropellant tanks and cold gas thrusters for manoeuvring.
    primary_blueprint = ShipBlueprint()
    for coord in (
            TileCoord(1, -2),
            TileCoord(-1, 0),
            TileCoord(0, 1),
            TileCoord(-1, 1),
            TileCoord(1, -1),
            TileCoord(0, -1),
            TileCoord(0, 0),
            TileCoord(1, 0),
        )
        primary_blueprint.components[coord] = ComponentOnTile(deepcopy(empty_liquid_tank_template), HexFrame.Q_POS, :_blueprint)
    end

    for coord in (TileCoord(-3, 2), TileCoord(-3, 1), TileCoord(-4, 2))
        primary_blueprint.components[coord] = ComponentOnTile(deepcopy(gas_tank_template), HexFrame.S_POS, :_blueprint)
    end

    for coord in (TileCoord(-4, 3), TileCoord(-4, 1))
        primary_blueprint.components[coord] = ComponentOnTile(deepcopy(nozzle_template), HexFrame.Q_POS, :_blueprint)
    end

    union!(primary_blueprint.ship_tiles, Set{TileCoord}([
        TileCoord(1, -2),
        TileCoord(-1, 0),
        TileCoord(0, 1),
        TileCoord(-1, 1),
        TileCoord(-3, 2),
        TileCoord(-2, 1),
        TileCoord(1, -1),
        TileCoord(0, -1),
        TileCoord(1, 0),
        TileCoord(-4, 2),
        TileCoord(-3, 1),
        TileCoord(0, 0),
    ]))

    # Tanker: a separate hull carrying the monopropellant reserve.
    tanker_blueprint = ShipBlueprint()
    for coord in (
            TileCoord(7, -6),
            TileCoord(6, -8),
            TileCoord(7, -5),
            TileCoord(7, -7),
            TileCoord(8, -7),
            TileCoord(6, -6),
            TileCoord(7, -8),
            TileCoord(6, -5),
            TileCoord(6, -7),
        )
        tanker_blueprint.components[coord] = ComponentOnTile(deepcopy(full_liquid_tank_template), HexFrame.Q_POS, :_blueprint)
    end

    union!(tanker_blueprint.ship_tiles, Set{TileCoord}([
        TileCoord(5, -6),
        TileCoord(7, -6),
        TileCoord(6, -8),
        TileCoord(5, -5),
        TileCoord(7, -5),
        TileCoord(7, -7),
        TileCoord(8, -7),
        TileCoord(6, -6),
        TileCoord(7, -8),
        TileCoord(6, -5),
        TileCoord(6, -7),
    ]))

    # Debris hulk: contains the transfer pump needed to move propellant across the gap.
    pump_holder_blueprint = ShipBlueprint()
    pump_holder_blueprint.components[TileCoord(-1, -4)] = ComponentOnTile(
        ElectricPumpCompBehav(
            ElectricTransferPump;
            pump_voltage = 2.0,
            max_energy = 50000.0,
            initial_energy = 50000.0,
            max_conductance = 0.5,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(0.5, 0.0, 0.4 / BASE_UPS)
        ),
        HexFrame.Q_NEG,
        :_blueprint
    )

    union!(pump_holder_blueprint.ship_tiles, Set{TileCoord}([
        TileCoord(-1, -4),
        TileCoord(-1, -3),
        TileCoord(0, -4),
    ]))

    gamemap = GameMap(primary_blueprint)
    merge_ship!(gamemap, Symbol("##Hull SW-326#631"), tanker_blueprint)
    merge_ship!(gamemap, Symbol("##Debris SW-326#633"), pump_holder_blueprint)
    return gamemap
end