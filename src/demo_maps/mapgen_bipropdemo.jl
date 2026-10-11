#=
Scope: Bipropellant demonstration map with pressure-fed fuel and oxidiser tanks
Formatter: Runic
=#

"""
    mapgen_bipropdemo()

Bipropellant demonstration map. Features a bipropellant combustion chamber fed by
pressure-fed fuel and oxidiser tanks, with separate flow control valves and a
cold-gas pressurant system.
"""
function mapgen_bipropdemo()
    blueprint = ShipBlueprint()

    # === Thrust cluster ===
    # Three tiny nozzles feeding a single bipropellant combustion chamber.
    nozzle_template = BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.2,
        sprite_variant = TINY_NOZZLE_SPRITE,
    )
    blueprint.components[TileCoord(-4, 1)] = PlacedComponent(nozzle_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-4, 2)] = PlacedComponent(nozzle_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(-4, 3)] = PlacedComponent(nozzle_template, HexFrame.Q_POS, :_blueprint)

    blueprint.components[TileCoord(-2, 1)] = PlacedComponent(
        BipropChamberCompBehav(fuel_conductance = 0.4, oxid_conductance = 1.0),
        HexFrame.Q_POS,
        :_blueprint,
    )

    # === Propellant flow control ===
    # Adjustable valve on the fuel side; on/off valve on the oxidiser side.
    blueprint.components[TileCoord(-1, -1)] = PlacedComponent(
        StandardValveCompBehav(
            SteppedSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
            percentage_step_size = 0.05,
        ),
        HexFrame.Q_POS,
        :_blueprint,
    )
    # Oxidiser valve has a reduced max conductance of 0.5.
    blueprint.components[TileCoord(-1, 2)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 0.5,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
        ),
        HexFrame.Q_POS,
        :_blueprint,
    )

    # === Fuel pressure-fed tanks ===
    fuel_tank_template = PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = 30.0,
            initial_gas_charge = 5.0,
            max_liquid_charge = 40.0,
            max_gas_pressure = 50.0,
            gas_node = HexFrame.NODE_Q_POS,
            initial_liquid_fluid = HexFluids.FUEL_LIQUID,
        ),
        (HexFrame.NODE_Q_NEG,),
        5.0,
        HexFluids.COLD_GAS,
        NoRotationBehavFrag(),
    )
    blueprint.components[TileCoord(0, -2)] = PlacedComponent(fuel_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(0, -1)] = PlacedComponent(fuel_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(1, -2)] = PlacedComponent(fuel_tank_template, HexFrame.Q_POS, :_blueprint)

    # === Oxidiser pressure-fed tanks ===
    oxid_tank_template = PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = 30.0,
            initial_gas_charge = 5.0,
            max_liquid_charge = 40.0,
            max_gas_pressure = 50.0,
            gas_node = HexFrame.NODE_Q_POS,
            initial_liquid_fluid = HexFluids.OXIDISER_LIQUID,
        ),
        (HexFrame.NODE_Q_NEG,),
        5.0,
        HexFluids.COLD_GAS,
        NoRotationBehavFrag(),
    )
    blueprint.components[TileCoord(0, 1)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(0, 2)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(0, 3)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(1, 0)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(1, 1)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(1, 2)] = PlacedComponent(oxid_tank_template, HexFrame.Q_POS, :_blueprint)

    # === Cold-gas pressurant control and tanks ===
    # On/off valve separating the gas tank ring from the pressure-fed tanks.
    blueprint.components[TileCoord(3, -2)] = PlacedComponent(
        StandardValveCompBehav(
            BoolSwitchBehavFrag, TINY_VALVE;
            max_conductance = 1.0,
            min_conductance = 0.0,
            growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
        ),
        HexFrame.Q_POS,
        :_blueprint,
    )

    gas_tank_template = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 50.0 / (HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64),
        max_voltage = 50.0,
        initial_charge = 40.0 / (HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64),
        series_conductance = 5.0,
    )
    blueprint.components[TileCoord(3, -4)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(3, -3)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(3, -1)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(3, 0)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(4, -4)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(4, -3)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)
    blueprint.components[TileCoord(4, -1)] = PlacedComponent(gas_tank_template, HexFrame.Q_POS, :_blueprint)

    # === Pipes ===

    # Nozzle exhaust outlets → biprop chamber (big pipes for high-throughput exhaust).
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 1), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 2), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-4, 3), HexFrame.Q_POS), VertexCoord(TileCoord(-2, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)

    # Propellant feed headers to the biprop chamber (big pipes).
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_NEG))] = BigPipeBehav(10.0)

    # Fuel liquid manifold: tanks → fuel flow valve.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS), VertexCoord(TileCoord(1, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)

    # Oxidiser liquid manifold: tanks → oxidiser flow valve.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_NEG), VertexCoord(TileCoord(-1, 3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 1), HexFrame.Q_POS), VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 2), HexFrame.Q_POS), VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 3), HexFrame.Q_POS), VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 1), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, 2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)

    # Pressurant distribution: gas tank ring → valve → pressure-fed tank gas inlets.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -2), HexFrame.Q_POS), VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, -1), HexFrame.Q_POS), VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, -2), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(3, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(1, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, 0), HexFrame.Q_POS), VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -3), HexFrame.Q_POS), VertexCoord(TileCoord(4, -4), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -2), HexFrame.Q_POS), VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(2, -1), HexFrame.Q_POS), VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG))] = ScrapPipeBehav(2.0)

    # Gas tank ring interconnects.
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -4), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -4), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -3), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -3), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -2), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -2), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, -1), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)
    blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(4, -1), HexFrame.Q_NEG), VertexCoord(TileCoord(3, 0), HexFrame.Q_POS))] = ScrapPipeBehav(2.0)

    # === Hull surface ===
    union!(
        blueprint.ship_tiles,
        Set(
            [
                TileCoord(-3, 1),
                TileCoord(-3, 2),
                TileCoord(-3, 4),
                TileCoord(-2, 0),
                TileCoord(-2, 1),
                TileCoord(-2, 2),
                TileCoord(-2, 3),
                TileCoord(-1, -2),
                TileCoord(-1, -1),
                TileCoord(-1, 0),
                TileCoord(-1, 1),
                TileCoord(-1, 2),
                TileCoord(-1, 3),
                TileCoord(0, -2),
                TileCoord(0, -1),
                TileCoord(0, 0),
                TileCoord(0, 1),
                TileCoord(0, 2),
                TileCoord(0, 3),
                TileCoord(1, -2),
                TileCoord(1, -1),
                TileCoord(1, 0),
                TileCoord(1, 1),
                TileCoord(1, 2),
                TileCoord(2, -3),
                TileCoord(2, -2),
                TileCoord(2, -1),
                TileCoord(2, 0),
                TileCoord(2, 1),
                TileCoord(2, 2),
                TileCoord(3, -4),
                TileCoord(3, -3),
                TileCoord(3, -2),
                TileCoord(3, -1),
                TileCoord(3, 0),
                TileCoord(4, -4),
                TileCoord(4, -3),
                TileCoord(4, -1),
            ]
        ),
    )

    gamemap = GameMap(blueprint)
    return gamemap
end
