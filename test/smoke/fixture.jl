#=
Scope: Scripted graphical smoke-test fixture loaded by the smoke-test launcher
Formatter: Runic
=#

"""Run the scripted graphical smoke-test fixture in an already-created window."""
function run_smoke_test_fixture(window::GLFW.Window; exit_tick::Int = 1200)
    teaser_map = mapgen_teasership()
    set_learning_system!(
        teaser_map,
        SandboxLearningState(tutorial_id = :teaser, level_index = 1),
    )

    reset_test_harness_stats!()

    # Generate a real encounter before the graphical session starts.
    encounter_seed = UInt32(43)
    class_config = get_encounter_system_config().encounter_class_configs[ENCOUNTER_SHIP]
    encounter_blueprint = generate_encounter(ENCOUNTER_SHIP, HexFluids.FUEL_LIQUID, 5.0, encounter_seed, class_config)
    encounter_name = generate_encounter_name(encounter_seed, ENCOUNTER_SHIP)

    # Settle the teaser, close its monoprop valve, then animate one tanker redock.
    # The encounter uses automatic docking after the redock animation has finished.
    test_commands::TestCommandSchedule = [
        make_test_step(120, make_test_action(TileCoord(-3, 7), :close_valve); expected_status = APPLIED, description = "Close monoprop platform valve"),
        make_test_step(240, make_test_redock_ship(Symbol("##Craft CL-204#148"), TileCoord(8, 0)); expected_status = APPLIED, description = "Redock oxidiser tanker"),
        make_test_step(460, make_test_add_encounter_ship(encounter_blueprint, encounter_name, encounter_seed); expected_status = APPLIED, description = "Dock generated encounter ship"),
        make_test_step(exit_tick; description = "Exit after encounter docks and settles"),
    ]

    @info "Smoke test running with $(length(test_commands)) scheduled entries; exit tick = $exit_tick ($(exit_tick / 60) simulated seconds)"
    sort!(test_commands, by = step -> step.tick, rev = true)
    frame_hook = (snapshot, inputstate, command_queue, flowcalc_task) ->
    test_system_tick!(test_commands, snapshot, inputstate, command_queue, flowcalc_task)
    result = enter_gameloop(window; map_source = teaser_map, frame_hook)
    @info "Smoke test exited cleanly (reason = $(result.exit_reason))"
    wait_for_test_harness_resolution()
    print_test_harness_summary()

    # Mirror the canonical shutdown from `enter_start_menu` so the OS window is
    # destroyed and CImGui/ImPlot release their contexts.
    @info "Tearing down ImGui and destroying GLFW window"
    ui_teardown()
    GLFW.DestroyWindow(window)
    @info "Smoke test shutdown complete"

    return !test_harness_failed() && isempty(test_commands) && result.exit_reason == EXIT_QUIT
end
