#=
Scope: Representative headless precompilation for concrete tank component behaviours
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload

"Construct the supported one-port pressure-fed tank with representative fluid state."
function _precompile_pressurefed_tank(; liquid_charge::Float64 = 20.0, gas_charge::Float64 = 4.0)
    tank = PressureFedTankBehavFrag(
        initial_liquid_charge = liquid_charge,
        initial_gas_charge = gas_charge,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = HexFluids.MONOPROP_LIQUID,
    )
    return PressureFedTankCompBehav(tank, (HexFrame.NODE_Q_NEG,), 5.0, HexFluids.COLD_GAS)
end

"Provide mapped speculative sources and currents for a real reactivation probe."
function _precompile_tank_probe_state(placed::PlacedComponent{T}, tile::TileCoord, currents::NTuple{N, Float64}) where {T <: ComponentBehavior, N}
    probe = get_reactivation_probe(placed)::ReactivationProbe
    derived = DerivedMapState()
    mna = MNA_State()

    for (index, current) in enumerate(currents)
        rel_element = probe.rel_elements[index]
        if rel_element.active
            abs_element = map_element(rel_element, tile, index, placed.rotation, placed.mirrored)
            push!(derived.filteredelements, abs_element)
            mna.vsource_currents[abs_element.id] = current
        end
    end

    return derived, mna
end

@setup_workload begin
    tile = TileCoord(3, -2)
    rotation = HexFrame.Q_POS

    gas = ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 40.0,
        max_voltage = 50.0,
        initial_charge = 20.0,
        series_conductance = 5.0,
    )
    liquid = ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = 20.0,
        series_conductance = 5.0,
    )
    pressurefed = _precompile_pressurefed_tank()

    placed_gas = PlacedComponent(gas, rotation, :PrecompileShip)
    placed_liquid = PlacedComponent(liquid, rotation, :PrecompileShip)
    placed_pressurefed = PlacedComponent(pressurefed, rotation, :PrecompileShip)

    # Fake sprite metadata is sufficient to enqueue commands; no GL objects are created
    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    sprites = (
        :GasTank1_base, :GasTank1_fluidmask, :GasTank1_indicator,
        :LiquidTank1_base, :LiquidTank1_fluidmask, :LiquidTank1_indicator,
        :PressureFedTank1_base, :PressureFedTank1_fluidmask,
        :PressureFedTank1_liquidindicator, :PressureFedTank1_gasindicator,
    )
    for sprite in sprites
        glmap.sprites[sprite] = GLspriteData(
            :PrecompileAtlas,
            SVector{2, Float32}(0.1f0, 0.1f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
        )
    end
    queue = HexFlowRendering.SpriteRenderCommand[]

    derived = DerivedMapState()
    derived.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_INTERNAL_1)] = HexFluids.MONOPROP_LIQUID

    # Boundary states reach the actual probe and fluid-adoption paths
    gas_empty = PlacedComponent(ThevininTankCompBehav(GasTankBehavFrag, 3; fluid = HexFluids.COLD_GAS, max_charge = 40.0, max_voltage = 50.0, initial_charge = 0.0, series_conductance = 5.0), rotation, :PrecompileShip)
    liquid_empty = PlacedComponent(ThevininTankCompBehav(LiquidTankBehavFrag, 3; fluid = HexFluids.MONOPROP_LIQUID, max_charge = 40.0, max_voltage = 1.0, initial_charge = 0.0, series_conductance = 5.0), rotation, :PrecompileShip)
    pressurefed_empty = PlacedComponent(_precompile_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0), rotation, :PrecompileShip)
    pressurefed_overpressure = PlacedComponent(_precompile_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0), rotation, :PrecompileShip)

    @compile_workload begin
        # Normal update state uses only the mapped source entries and their currents
        mna = MNA_State()
        gas_source = first(produce_abs_elements(placed_gas, tile))
        mna.vsources[gas_source.id] = gas_source
        mna.vsource_currents[gas_source.id] = 5.0
        pressurefed_mna = MNA_State()
        for element in produce_abs_elements(placed_pressurefed, tile)[1:2]
            pressurefed_mna.vsources[element.id] = element
            pressurefed_mna.vsource_currents[element.id] = 5.0
        end

        gas_probe_derived, gas_probe_mna = _precompile_tank_probe_state(gas_empty, tile, (5.0,))
        liquid_probe_derived, liquid_probe_mna = _precompile_tank_probe_state(liquid_empty, tile, (5.0,))
        pressurefed_probe_derived, pressurefed_probe_mna = _precompile_tank_probe_state(pressurefed_empty, tile, (5.0, 5.0))
        overpressure_probe_derived, overpressure_probe_mna = _precompile_tank_probe_state(pressurefed_overpressure, tile, (-5.0, -5.0))

        for placed in (placed_gas, placed_liquid, placed_pressurefed)
            produce_rel_elements(placed.component)
            produce_rel_elements(placed)
            produce_abs_elements(placed, tile)
            produce_rel_fluid_declarations(placed)
            get_tunables(placed)
            get_component_wet_mass(placed)
            get_component_mass(placed)
            map_rotation(placed, HexFrame.S_POS)
            can_be_moved(placed)
            get_actions(placed)
            render_base_elem!(queue, placed; glmap = glmap, position = tile, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
            render_map_elem!(queue, placed; glmap = glmap, position = tile, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end

        get_component_wet_mass(placed_gas; fluid = HexFluids.COLD_GAS)
        get_component_wet_mass(placed_liquid; fluid = HexFluids.MONOPROP_LIQUID)
        get_component_wet_mass(placed_pressurefed; fluid = HexFluids.MONOPROP_LIQUID)

        set_tunables(placed_gas, (40.0, 50.0, 20.0, 5.0))
        set_tunables(liquid, (40.0, 1.0, 20.0, 5.0, HexFluids.MONOPROP_LIQUID))
        set_tunables(pressurefed, (40.0, 50.0, 20.0, 4.0, 5.0, HexFluids.MONOPROP_LIQUID))

        update_flowbehav!(placed_gas; tile = tile, mna_state = mna)
        update_flowbehav!(placed_liquid; tile = tile, mna_state = mna, derivedmapstate = derived)
        update_flowbehav!(placed_pressurefed; tile = tile, mna_state = pressurefed_mna, derivedmapstate = derived)
        produce_rel_fluid_declarations(liquid_empty)
        produce_rel_fluid_declarations(pressurefed_empty)
        render_base_elem!(queue, liquid_empty; glmap = glmap, position = tile, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))

        do_action!(placed_gas, :seal_tank)
        do_action!(placed_liquid, :seal_tank)
        do_action!(placed_pressurefed, :seal_both)

        get_reactivation_probe(gas_empty)
        classify_reactivation_probe(gas_empty; tile = tile, derivedmapstate = gas_probe_derived, mna_state = gas_probe_mna)
        commit_reactivation_probe!(gas_empty; tile = tile, derivedmapstate = gas_probe_derived, mna_state = gas_probe_mna)

        get_reactivation_probe(liquid_empty)
        classify_reactivation_probe(liquid_empty; tile = tile, derivedmapstate = liquid_probe_derived, mna_state = liquid_probe_mna)
        commit_reactivation_probe!(liquid_empty; tile = tile, derivedmapstate = liquid_probe_derived, mna_state = liquid_probe_mna)

        get_reactivation_probe(pressurefed_empty)
        classify_reactivation_probe(pressurefed_empty; tile = tile, derivedmapstate = pressurefed_probe_derived, mna_state = pressurefed_probe_mna)
        commit_reactivation_probe!(pressurefed_empty; tile = tile, derivedmapstate = pressurefed_probe_derived, mna_state = pressurefed_probe_mna)

        get_reactivation_probe(pressurefed_overpressure)
        classify_reactivation_probe(pressurefed_overpressure; tile = tile, derivedmapstate = overpressure_probe_derived, mna_state = overpressure_probe_mna)
        commit_reactivation_probe!(pressurefed_overpressure; tile = tile, derivedmapstate = overpressure_probe_derived, mna_state = overpressure_probe_mna)

        update_flowbehav!(liquid_empty; tile = tile, mna_state = mna, derivedmapstate = derived)
        update_flowbehav!(pressurefed_empty; tile = tile, mna_state = pressurefed_mna, derivedmapstate = derived)
    end
end
