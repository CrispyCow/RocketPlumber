#=
Scope: Representative headless game-session precompilation
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    glmap = GLObjectMap()
    glmap.textures[:TileTextureAtlas1] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    RenderEngine.setup_glsprite!(glmap, :TileTextureAtlas1, HexFlowRendering.texture_atlas_dir())

    @compile_workload begin
        # compile map generation scripts
        gamemap = mapgen_teasership()
        mapgen_basicplumbing()
        mapgen_bigpipeplumbing()
        mapgen_flowdemo()
        mapgen_pressurefedintro()
        mapgen_turbopumpintro2()
        mapgen_liquidtransfer()
        mapgen_bipropdemo()

        # compile procgen of the starter ship
        starter_seed = UInt32(42)
        explorer_map = GameMap(generate_starter_ship(starter_seed))
        initialise_spacemap!(explorer_map, starter_seed, get_encounter_system_config())
        initialise_explorer_opening_capture!(explorer_map)

        # compile encounter ship procgen
        encounter_seed = UInt32(43)
        class_config = get_encounter_system_config().encounter_class_configs[ENCOUNTER_SHIP]
        encounter_blueprint = generate_encounter(ENCOUNTER_SHIP, HexFluids.FUEL_LIQUID, 5.0, encounter_seed, class_config)
        encounter_ship_optimal_dir!(explorer_map, encounter_blueprint, generate_encounter_name(encounter_seed, ENCOUNTER_SHIP), encounter_seed)

        # Compile current-format save/load of the freshly generated map
        # Future historical migration coverage belongs in persistence tests
        mktempdir() do directory
            save_path = joinpath(directory, "precompile_map.jld2")
            save_game(gamemap, save_path)
            @assert isfile(save_path)
            loaded_bundle = loadmap_bundle(save_path)
            @assert typeof(loaded_bundle.gamemap.components) === typeof(gamemap.components)
            @assert typeof(loaded_bundle.gamemap.pipe_behaviors) === typeof(gamemap.pipe_behaviors)
            @assert loaded_bundle.gamemap.components == gamemap.components
            @assert loaded_bundle.gamemap.pipe_behaviors == gamemap.pipe_behaviors
            @assert length(loaded_bundle.gamemap.ships) == length(gamemap.ships)
        end

        initial_snapshot = FlowCalculatorSnapshot(
            gamemap = gamemap,
            gamestate = GameState(estimated_min_delta_v = estimate_min_delta_v(gamemap)),
            timestamp = 0.0,
        )
        ipc = setup_flowcalc_ipc(initial_snapshot)

        # Mirror the calculator-owned state and one-time loop initialisation
        calculator_snapshot = deepcopy(initial_snapshot)
        calculator_map = calculator_snapshot.gamemap
        derived = calculator_snapshot.derived
        mna = MNA_State()
        gamestate = calculator_snapshot.gamestate
        scratchpad = HexFlowCalculator.CalculatorScratchpad()
        scheduler = HexFlowCalculator.ReactivationScheduler()
        @atomic ipc.shared_state.target_spacemap_time = get_target_time(calculator_map.space_map)

        HexFlowCalculator.step_flowcalc_sim!(calculator_map, derived, mna, gamestate, scratchpad, scheduler, ipc, false, 1.0)

        response_channel = Channel{CommandStatus}(1)
        command = create_do_action_command(ipc.command_queue, TileCoord(0, 0), :seal_tank; response_channel)
        @assert try_enqueue_command!(ipc.command_queue, command)
        HexFlowCalculator.step_flowcalc_sim!(calculator_map, derived, mna, gamestate, scratchpad, scheduler, ipc, false, 2.0)
        @assert isready(response_channel)
        @assert take!(response_channel) === APPLIED

        snapshot = ipc.get_snapshot()
        inputstate = InputState()
        renderqueue = SpriteRenderCommand[]
        populate_renderqueue!(renderqueue, glmap, snapshot, inputstate)
    end
end
