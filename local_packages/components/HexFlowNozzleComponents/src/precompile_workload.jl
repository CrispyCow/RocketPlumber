#=
Scope: Representative headless precompilation for concrete nozzle and chamber behaviours
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload

"Provide fake sprite metadata sufficient for command construction without GL objects."
function _precompile_nozzle_glmap()
    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    sprites = (
        :PrecompileNozzle, :AllNozzles_SwitchedTinyNozzle_bkg, :AllNozzles_SwitchedTinyNozzle_valve,
        :AllNozzles_SwitchedTinyNozzle_fluidmask, :DecompChamber1_gas_fluidmask, :DecompChamber1_frame,
        :CombustionChamber1_gas_fluidmask, :CombustionChamber1_frame,
        (:DecompChamber1_liquid_fluidmask_1, :DecompChamber1_liquid_fluidmask_2, :DecompChamber1_liquid_fluidmask_3, :DecompChamber1_liquid_fluidmask_4)...,
        (:CombustionChamber1_fuel_fluidmask_1, :CombustionChamber1_fuel_fluidmask_2, :CombustionChamber1_fuel_fluidmask_3, :CombustionChamber1_fuel_fluidmask_4)...,
        (:CombustionChamber1_ox_fluidmask_1, :CombustionChamber1_ox_fluidmask_2, :CombustionChamber1_ox_fluidmask_3, :CombustionChamber1_ox_fluidmask_4)...,
    )
    for sprite in sprites
        glmap.sprites[sprite] = GLspriteData(:PrecompileAtlas, SVector{2, Float32}(0.1f0, 0.1f0), SVector{2, Float32}(0.0f0, 0.0f0), SVector{2, Float32}(256.0f0, 256.0f0), SVector{2, Float32}(256.0f0, 256.0f0), SVector{2, Float32}(0.0f0, 0.0f0))
    end
    return glmap
end

@setup_workload begin
    tile = TileCoord(3, -2)
    rotation = HexFrame.Q_POS
    basic = BasicNozzleCompBehav(connected_node = HexFrame.NODE_Q_POS, throat_area = 0.2, sprite = :PrecompileNozzle)
    switched = SwitchedNozzleCompBehav(throat_area = 0.2, connected_node = HexFrame.NODE_Q_POS, max_conductance = 2.0, min_conductance = 0.0, growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS))
    decomp = DecompChamberCompBehav()
    biprop = BipropChamberCompBehav()
    placed = (
        PlacedComponent(basic, rotation, :PrecompileShip),
        PlacedComponent(switched, rotation, :PrecompileShip),
        PlacedComponent(decomp, rotation, :PrecompileShip),
        PlacedComponent(biprop, rotation, true, :PrecompileShip),
    )
    glmap = _precompile_nozzle_glmap()
    queue = HexFlowRendering.SpriteRenderCommand[]
    manager = ParticleManager()
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0))
    mna = MNA_State()
    snapshot = MNA_StateSnapshot()
    derived = DerivedMapState()
    inlet = map_element(HexFrame.NODE_Q_POS, tile, rotation)
    derived.nodeactualfluids[inlet] = HexFluids.MONOPROP_GAS
    derived.node_temperatures[inlet] = 800.0
    mna.node_voltages[inlet] = 100.0
    snapshot.node_voltages[inlet] = 100.0
    for (node, fluid) in ((HexFrame.NODE_R_NEG, HexFluids.FUEL_LIQUID), (HexFrame.NODE_S_NEG, HexFluids.OXIDISER_LIQUID), (HexFrame.NODE_Q_NEG, HexFluids.BIPROP_EXHAUST))
        derived.nodeactualfluids[map_element(node, tile, rotation, true)] = fluid
    end
    derived.nodeactualfluids[map_element(HexFrame.NODE_INTERNAL_1, tile, rotation)] = HexFluids.MONOPROP_GAS
    snapshot.vsource_currents[ElementID(tile, 1)] = 0.2
    snapshot.vsource_currents[ElementID(tile, 2)] = 0.2
    mna.vsource_currents[ElementID(tile, 1)] = 0.2
    mna.vsource_currents[ElementID(tile, 2)] = 0.2

    @compile_workload begin
        for component in placed
            produce_rel_elements(component.component)
            produce_rel_elements(component)
            produce_abs_elements(component, tile)
            produce_rel_fluid_declarations(component)
            get_tunables(component)
            get_component_mass(component)
            render_base_elem!(queue, component; glmap = glmap, position = tile, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end
        set_tunables(placed[1], (0.2, 3000.0, 2.0, 5.0))
        set_tunables(placed[2], (0.2, 400.0, 1.0, 0.3, 2.0, 0.0, 1.0))
        set_tunables(placed[3], (800.0,))
        set_tunables(placed[4], (0.4, 1.0, 2.5))
        placement_valid(placed[1], tile, gamemap)
        placement_valid(placed[2], tile, gamemap)
        get_actions(placed[1])
        get_actions(placed[2])
        on_click!(placed[2]; unrotated_clicksite = CartesianCoord(0.0, 0.5))
        do_action!(placed[2], :open_valve)
        do_action!(placed[1], :repair_component)
        do_action!(placed[2], :repair_component)
        get_component_temperature(placed[1])
        get_component_temperature(placed[2])
        get_thrust(placed[1]; tile = tile, mna_state = mna, derivedmapstate = derived)
        get_thrust(placed[2]; tile = tile, mna_state = mna, derivedmapstate = derived)
        collect_effect_particles!(manager, placed[1]; tile = tile, derivedmapstate = derived, mna_state = snapshot, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0))
        collect_effect_particles!(manager, placed[2]; tile = tile, derivedmapstate = derived, mna_state = snapshot, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0))
        map_mirroring(placed[4], true)
        update_flowbehav!(placed[1]; tile = tile, mna_state = mna, derivedmapstate = derived)
        update_flowbehav!(placed[2]; tile = tile, mna_state = mna, derivedmapstate = derived)
        update_flowbehav!(placed[4]; tile = tile, mna_state = mna, derivedmapstate = derived)
        for component in placed
            render_map_elem!(queue, component; glmap = glmap, position = tile, derivedmapstate = derived, mna_state = snapshot, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end

        # The live update deactivates a chamber on reverse flow; probes run on inactive states
        deactivate!(basic.nozzle)
        deactivate!(switched.nozzle)
        deactivate!(biprop.state.auto_deactivation)
        basic_probe = get_reactivation_probe(placed[1])
        switched_probe = get_reactivation_probe(placed[2])
        biprop_probe = get_reactivation_probe(placed[4])
        for (component, probe) in ((placed[1], basic_probe), (placed[2], switched_probe))
            abs_element = map_element(only(probe.rel_elements), tile, 1, rotation)
            push!(derived.filteredelements, abs_element)
            mna.node_voltages[abs_element.connections.v1] = 100.0
            classify_reactivation_probe(component; tile = tile, derivedmapstate = derived, mna_state = mna)
            commit_reactivation_probe!(component; tile = tile, derivedmapstate = derived, mna_state = mna)
        end
        get_reactivation_probe(placed[4])
        classify_reactivation_probe(placed[4]; tile = tile, derivedmapstate = derived, mna_state = mna)
        commit_reactivation_probe!(placed[4]; tile = tile, derivedmapstate = derived, mna_state = mna)
        produce_rel_elements(placed[4])
    end
end
