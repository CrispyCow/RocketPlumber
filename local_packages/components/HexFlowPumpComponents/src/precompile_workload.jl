#=
Scope: Representative headless precompilation for concrete turbopump and electric-pump behaviours
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload

"Provide fake sprite metadata sufficient for command construction without GL objects."
function _precompile_pump_glmap()
    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    sprites = (
        :TurboPump1_fluidmask, :TurboPump1_speedmask, :TurboPump1_rotor, :TurboPump1_static,
        :TurboPump1_genturbine, :TurboPump1_vibepart, :TurboPump1_smoke_1, :TurboPump1_smoke_2, :TurboPump1_smoke_3,
        :ElectroPump1_chargemask, :ElectroPump1_static, :ElectroPump1_vibe, :ElectroPump1_rotor,
        :ElectroTransferPump_chargemask, :ElectroTransferPump_fluidmask, :ElectroTransferPump_static, :ElectroTransferPump_rotor,
    )
    for sprite in sprites
        glmap.sprites[sprite] = GLspriteData(:PrecompileAtlas, SVector{2, Float32}(0.1f0, 0.1f0), SVector{2, Float32}(0.0f0, 0.0f0), SVector{2, Float32}(256.0f0, 256.0f0), SVector{2, Float32}(256.0f0, 256.0f0), SVector{2, Float32}(0.0f0, 0.0f0))
    end
    return glmap
end

"Build a production-like electric-pump specialisation with a partially charged store."
function _precompile_electric_pump(variant::ElectricPumpVariant)
    return ElectricPumpCompBehav(variant; pump_voltage = 50.0, max_energy = 200.0, initial_energy = 100.0, max_conductance = 1.0, min_conductance = 0.0, growth_factor = calculate_growth_factor(1.0, 0.0, 1.0 / BASE_UPS))
end

@setup_workload begin
    tile = TileCoord(3, -2)
    rotation = HexFrame.Q_POS
    turbo = TurboPumpCompBehav(max_pump_voltage = 50.0, series_conductance = 1.0, current_rpm = 1500.0)
    electric_turbo = _precompile_electric_pump(ELECTRIC_TURBO_PUMP)
    electric_transfer = _precompile_electric_pump(ELECTRIC_TRANSFER_PUMP)
    placed = (
        PlacedComponent(turbo, rotation, true, :PrecompileShip),
        PlacedComponent(electric_turbo, rotation, :PrecompileShip),
        PlacedComponent(electric_transfer, rotation, :PrecompileShip),
    )
    glmap = _precompile_pump_glmap()
    queue = HexFlowRendering.SpriteRenderCommand[]
    mna = MNA_State()
    snapshot = MNA_StateSnapshot()
    derived = DerivedMapState()
    turbine_node = map_element(HexFrame.NODE_S_POS, tile, rotation, true)
    inlet_node = map_element(HexFrame.NODE_Q_NEG, tile, rotation)
    derived.nodeactualfluids[turbine_node] = HexFluids.COLD_GAS
    derived.node_temperatures[turbine_node] = 800.0
    derived.nodeactualfluids[inlet_node] = HexFluids.MONOPROP_LIQUID
    mna.node_voltages[turbine_node] = 5.0
    snapshot.node_voltages[turbine_node] = 5.0
    mna.vsource_currents[ElementID(tile, 1)] = -0.2
    snapshot.vsource_currents[ElementID(tile, 1)] = -0.2

    @compile_workload begin
        for component in placed
            produce_rel_elements(component.component)
            produce_rel_elements(component)
            produce_abs_elements(component, tile)
            produce_rel_fluid_declarations(component)
            get_tunables(component)
            get_component_mass(component)
            get_actions(component)
            render_base_elem!(queue, component; glmap = glmap, position = tile, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
            render_map_elem!(queue, component; glmap = glmap, position = tile, derivedmapstate = derived, mna_state = snapshot, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end
        turbo_placed = placed[1]
        turbo_placed = set_tunables(turbo_placed, (50.0, 1.0, 0.3, 1500.0, 3000.0, 50.0, 0.002, 0.6, 0.0, 1.25, 1500.0, 30.0, 0.7))
        for component in placed[2:3]
            component = set_tunables(component, (50.0, 100.0, 200.0, 1.0, 0.0))
            component = on_click(component; unrotated_clicksite = CartesianCoord(0.0, 0.5))
            component, _ = do_action(component, :pump_on)
            component = update_flowbehav(component; tile = tile, mna_state = mna)
        end
        map_mirroring(turbo_placed, true)
        turbo_placed = on_click(turbo_placed; unrotated_clicksite = CartesianCoord(0.0, 0.5))
        turbo_placed, _ = do_action(turbo_placed, :repair_component)
        get_component_temperature(turbo_placed)
        turbo_placed = update_flowbehav(turbo_placed; tile = tile, mna_state = mna, derivedmapstate = derived)

        # A reverse turbine flow reaches the real reactivation probe path
        mna.node_voltages[turbine_node] = -5.0
        turbo_placed = update_flowbehav(turbo_placed; tile = tile, mna_state = mna, derivedmapstate = derived)
        probe = get_reactivation_probe(turbo_placed)
        turbine_element = map_element(probe.rel_elements[3], tile, 3, rotation, true)
        push!(derived.filteredelements, turbine_element)
        mna.node_voltages[turbine_node] = 5.0
        classify_reactivation_probe(turbo_placed; tile = tile, derivedmapstate = derived, mna_state = mna)
        turbo_placed = commit_reactivation_probe(turbo_placed; tile = tile, derivedmapstate = derived, mna_state = mna)
        produce_rel_elements(turbo_placed)
    end
end
