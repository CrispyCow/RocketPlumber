#=
Scope: Representative headless precompilation for production valve specialisations
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    growth = calculate_growth_factor(2.0, 0.0, 2.0 / BASE_UPS)
    stepped_large = PlacedComponent(StandardValveCompBehav(SteppedSwitchBehavFrag, LARGE_VALVE; max_conductance = 2.0, growth_factor = growth), HexFrame.Q_POS, :PrecompileShip)
    stepped_tiny = PlacedComponent(StandardValveCompBehav(SteppedSwitchBehavFrag, TINY_VALVE; max_conductance = 2.0, growth_factor = growth), HexFrame.Q_POS, :PrecompileShip)
    bool_large = PlacedComponent(StandardValveCompBehav(BoolSwitchBehavFrag, LARGE_VALVE; max_conductance = 2.0, growth_factor = growth), HexFrame.Q_POS, :PrecompileShip)
    bool_tiny = PlacedComponent(StandardValveCompBehav(BoolSwitchBehavFrag, TINY_VALVE; max_conductance = 2.0, growth_factor = growth), HexFrame.Q_POS, :PrecompileShip)
    tile = TileCoord(2, -1)

    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    sprites = (
        :Valves_Large_fluidmask, :Valves_Tiny_fluidmask,
        :Valves_Large_valvebody, :Valves_Tiny_valvebody,
        :Valves_Large_static, :Valves_Tiny_static,
        :Valves_Adjustable_controlbox, :Valves_OnOff_controlbox,
        :Valves_actpointline, :Valves_setpointarrow,
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
    derived.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_Q_POS)] = HexFluids.COLD_GAS
    liquid_derived = DerivedMapState()
    liquid_derived.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_Q_POS)] = HexFluids.MONOPROP_LIQUID

    @compile_workload begin
        for placed in (stepped_large, stepped_tiny, bool_large, bool_tiny)
            produce_rel_elements(placed.component)
            produce_rel_elements(placed)
            produce_abs_elements(placed, tile)
            get_tunables(placed)
            get_actions(placed)
            placed = update_flowbehav(placed; tile = tile)
            placed = on_click(placed; unrotated_clicksite = CartesianCoord(0.0, 0.5))
            render_base_elem!(queue, placed; glmap = glmap, position = tile, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
            render_map_elem!(queue, placed; glmap = glmap, position = tile, derivedmapstate = derived, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end

        # Liquid uses a different rendering callee from the representative gas state
        render_map_elem!(queue, stepped_large; glmap = glmap, position = tile, derivedmapstate = liquid_derived, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))

        for placed in (stepped_large, stepped_tiny)
            placed = set_tunables(placed, (2.0, 0.0, growth, 0.05))
            placed, _ = do_action(placed, :step_valve_open)
        end
        for placed in (bool_large, bool_tiny)
            placed = set_tunables(placed, (2.0, 0.0, growth))
            placed, _ = do_action(placed, :open_valve)
        end
    end
end
