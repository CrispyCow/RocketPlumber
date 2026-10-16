#=
Scope: Main game-session orchestration, rendering, input, calculator IPC, and shutdown
Formatter: Runic
=#

# ===============================================================
# Helper Functions for the Game Main Loop
# ===============================================================

using HexFlowTelemetry, FlowMap, FlowEngine, HexFlowProcGen, HexFluids, HexFlowControl
using StaticArrays
using LinearAlgebra

"Initialise the OpenGL objects and render queues used by the game loop."
function init_opengl_objects()
    glmap::GLObjectMap = GLObjectMap()
    renderqueue = Vector{SpriteRenderCommand}()
    sizehint!(renderqueue, 512)
    scratch_renderqueue = Vector{SpriteRenderCommand}(undef, 512)  # pre-allocated sort scratch tied to the render queue

    viewtransform_glubo_init(glmap)
    basesprite_glprog_init(glmap)
    texatlas1_gltex_init(glmap)
    liquidsprite_glprog_init(glmap)
    gassprite_glprog_init(glmap)
    particle_glprog_init(glmap)

    return glmap, renderqueue, scratch_renderqueue
end

"Populate world sprite commands from the current calculator snapshot."
function populate_renderqueue!(renderqueue::Vector{SpriteRenderCommand}, glmap::GLObjectMap, snapshot::FlowCalculatorSnapshot, inputstate::InputState)
    @timeit render_loop_timer "Populate Render Queue" begin
        @timeit render_loop_timer "Ship Surface" ship_surface_queued_render!(renderqueue, glmap, snapshot.gamemap; selected_ship = highlighted_ship(inputstate))
        @timeit render_loop_timer "Docking Beams" render_docking_beams!(renderqueue, glmap, snapshot.gamemap, snapshot.gamestate.ticks)
        @timeit render_loop_timer "Tiles" tile_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna, snapshot.gamestate)
        @timeit render_loop_timer "Ghosts" render_cursor_ghosts!(renderqueue, glmap, inputstate, snapshot.gamemap, snapshot.gamestate)
        @timeit render_loop_timer "Pipes" pipe_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.gamestate)
        @timeit render_loop_timer "Nodes" node_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna)
    end

    return nothing
end

"Render a frame with background particles, queued sprites, and foreground particles."
function custom_rendering!(
        renderqueue::Vector{SpriteRenderCommand},
        scratch_renderqueue::Vector{SpriteRenderCommand},
        glmap::GLObjectMap,
        snapshot::FlowCalculatorSnapshot,
        shared_state::FlowCalculatorSharedState,
        inputstate::InputState,
        viewstate::ViewState
    )
    empty!(renderqueue)

    set_view_ubo(glmap, get_viewtransform(viewstate))

    # Background particles behind the ship
    if !isnothing(viewstate.background_particles)
        @timeit render_loop_timer "Particle Systems" begin
            @timeit render_loop_timer "Background Particles" begin
                if !shared_state.is_paused
                    thrust_dust_particle_effect!(viewstate.background_particles, snapshot.gamestate, snapshot.gamemap, snapshot.derived)
                    update_particle_physics!(viewstate.background_particles, snapshot.gamestate)
                end
                # Passing the map enables ship-surface culling
                render_particles!(glmap, viewstate.background_particles, viewstate, snapshot.timestamp, shared_state.actual_ups, snapshot.gamemap)
            end
        end
    end

    # Queued world sprites
    @timeit render_loop_timer "Sprite Rendering" begin
        populate_renderqueue!(renderqueue, glmap, snapshot, inputstate)
        @timeit render_loop_timer "Execute Render Queue" glrender(glmap, renderqueue, scratch_renderqueue)
    end

    # Foreground particles above the ship
    if !isnothing(viewstate.foreground_particles)
        @timeit render_loop_timer "Particle Systems" begin
            @timeit render_loop_timer "Foreground Particles" begin
                if !shared_state.is_paused
                    tile_particle_spawn!(viewstate.foreground_particles, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna, snapshot.gamestate)
                    update_particle_physics!(viewstate.foreground_particles, snapshot.gamestate)
                end
                # No map disables ship-surface culling
                render_particles!(glmap, viewstate.foreground_particles, viewstate, snapshot.timestamp, shared_state.actual_ups, nothing)
            end
        end
    end

    return nothing
end

"Set up the IPC data structures for the FlowCalculator task."
function setup_flowcalc_ipc(initial_snapshot::FlowCalculatorSnapshot)::FlowCalculatorIPC
    shared_state = FlowCalculatorSharedState()
    command_queue = create_command_queue(32)
    publish_snapshot, get_snapshot = create_snapshot_storage(initial_snapshot)
    console_push, console_see = create_threadsafe_consolebuffer()

    return FlowCalculatorIPC(
        shared_state,
        command_queue,
        publish_snapshot,
        get_snapshot,
        console_push,
        console_see,
    )
end

"Create input and view state populated with the window and framebuffer sizes."
function init_input_viewstates(window::GLFW.Window)::Tuple{InputState, ViewState}
    inputstate = InputState()
    viewstate = ViewState()

    winsize = GLFW.GetWindowSize(window)
    viewstate.window_width = winsize.width
    viewstate.window_height = winsize.height

    fbsize = GLFW.GetFramebufferSize(window)
    viewstate.fb_width = fbsize.width
    viewstate.fb_height = fbsize.height

    return inputstate, viewstate
end

"Handle user input, update render-owned state, and enqueue calculator commands."
function user_handler!(
        flowcalc_ipc::FlowCalculatorIPC,
        inputstate::InputState,
        viewstate::ViewState,
        snapshot::FlowCalculatorSnapshot,
        window::GLFW.Window,
    )
    # Synchronise state used by input handlers
    update_ship_bounds!(viewstate, snapshot.gamemap)

    inputstate.gui_inputs[:time_progressing] = is_time_progressing(snapshot.gamemap)
    inputstate.gui_inputs[:galaxy_escape_active] = is_galaxy_escape_active(snapshot.gamemap)
    current_time_years = get_time_years(snapshot.gamemap)
    inputstate.gui_inputs[:current_spacemap_time] = something(current_time_years, 0.0)
    inputstate.gui_inputs[:consume_right_click] = false

    # Reconcile selection and popups with the latest snapshot
    # Move completion must translate selection before stale source coordinates are pruned
    poll_move_completion!(inputstate, snapshot.gamemap)

    # Prune selected elements that no longer exist or have moved onto a render-offset ship.
    prune_selection!(
        coord -> has_component(snapshot.gamemap, coord) && !is_on_offset_ship(coord, snapshot.gamemap),
        coord -> has_pipe(snapshot.gamemap, coord) && !is_on_offset_ship(coord, snapshot.gamemap), inputstate
    )
    popup = inputstate.action_popup
    if !isnothing(popup)
        target = popup.target
        stale_component_popup = target isa ComponentPopupTarget &&
            (
            selected_element_count(inputstate) != 1 ||
                !has_selected_component(inputstate, target.coord) ||
                !has_component(snapshot.gamemap, target.coord) ||
                is_on_offset_ship(target.coord, snapshot.gamemap)
        )
        stale_group_popup = target isa ElementGroupPopupTarget &&
            (
            selected_element_count(inputstate) < 2 ||
                Set(target.component_coords) != selected_component_coords(inputstate) ||
                Set(target.pipe_coords) != selected_pipe_coords(inputstate)
        )
        stale_ship_popup = target isa ShipPopupTarget &&
            (
            !has_ship(snapshot.gamemap, target.ship_name) ||
                get_ship_render_offset(snapshot.gamemap, target.ship_name) != AxialCoord(0.0, 0.0)
        )
        (stale_component_popup || stale_group_popup || stale_ship_popup) && dismiss_action_popup!(inputstate)
    end

    cimgui_io = CImGui.GetIO()
    handle_inputs!(inputstate, viewstate, flowcalc_ipc.shared_state, window, cimgui_io)
    mouse_captured = unsafe_load(cimgui_io.WantCaptureMouse)

    # Dispatch interaction mode
    state = placement_state(inputstate)
    if is_standard_family_state(state)
        flowcalc_standard_interaction!(
            flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, window;
            mouse_captured = mouse_captured,
        )

        if !mouse_captured && placement_state(inputstate) isa PlacementReadyState
            flowcalc_rightclick_action!(inputstate, snapshot.gamemap, window)
        end
    elseif state isa PlacementRedockState
        _handle_redock_click!(inputstate, flowcalc_ipc, window; mouse_captured = mouse_captured)
    elseif state isa PlacementTileState
        flowcalc_tileplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, window; mouse_captured = mouse_captured)
    elseif state isa PlacementDeleteState
        flowcalc_deleteplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, window; mouse_captured = mouse_captured)
    elseif state isa PlacementSurfaceEditState
        flowcalc_surfaceeditor!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, window; mouse_captured = mouse_captured)
    end

    return update_lastinstate!(inputstate, window)
end

"Render the CImGui UI elements, mutating render-owned input state."
function ui_rendering!(
        inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, timelapse_recorder::TimelapseRecorder, snapshot::FlowCalculatorSnapshot,
        viewstate::ViewState, window::GLFW.Window;
        learning_state::Union{Nothing, LearningSystemState} = nothing,
        session_timing::PlaySessionTiming,
        completed_gamemap::Union{Nothing, GameMap},
        escape_save_state::EscapeSaveState,
    )
    if !isnothing(completed_gamemap)
        ui_renderwrap() do
            ui_galaxy_escape_victory_render!(completed_gamemap, inputstate, flowcalc_ipc, timelapse_recorder, window, escape_save_state)
            ui_notifications_render!(GLFW.GetWindowSize(window), flowcalc_ipc.console_see)
        end
        return nothing
    end

    # Update interaction bounds
    max_view_bounds = calc_max_reachable_bounds(viewstate)
    set_max_reachable_bounds!(flowcalc_ipc.shared_state, max_view_bounds)

    ui_renderwrap() do
        if !isnothing(learning_state) && is_sandbox_learning(learning_state)
            active_entry = get_active_entry(learning_state)
            if !isnothing(active_entry)
                ui_tutorial_banner_render!(active_entry.definition.title, GLFW.GetWindowSize(window))
            end
        end

        if !inputstate.spacemap_active
            ui_velocity_tracker_render!(snapshot.gamestate, snapshot.gamemap, inputstate, flowcalc_ipc)
            ui_propertybox_render!(inputstate, snapshot.gamemap, snapshot.derived, snapshot.mna, GLFW.GetWindowSize(window), flowcalc_ipc)
            ui_action_popup_render!(inputstate, viewstate, flowcalc_ipc.command_queue, snapshot.gamemap)
            ui_dev_utils_menu_render!(
                inputstate, flowcalc_ipc, timelapse_recorder, snapshot, viewstate,
                GLFW.GetWindowSize(window), max_view_bounds;
                session_timing = session_timing,
            )
        end

        ui_pause_menu_render!(inputstate, flowcalc_ipc, timelapse_recorder, snapshot, window, learning_state; session_timing = session_timing)
        ui_spacemap_render!(inputstate, flowcalc_ipc, snapshot, GLFW.GetWindowSize(window), max_view_bounds)

        if !isnothing(learning_state)
            ui_learning_system_render!(learning_state, inputstate, GLFW.GetWindowSize(window))
        end

        ui_explorer_opening_wake_render!(snapshot.gamemap, inputstate, GLFW.GetWindowSize(window))
        ui_notifications_render!(GLFW.GetWindowSize(window), flowcalc_ipc.console_see)
    end
    return nothing
end

"""
Requests termination of the FlowCalculator task, waits for it to exit, then
tears down OpenGL resources. Waiting guarantees the background thread has
stopped before callers destroy the window or exit the Julia process.
"""
function cleanup!(flowcalc_ipc::FlowCalculatorIPC, flowcalc_task::Task, globjmap::GLObjectMap, window::GLFW.Window)
    @info "Requesting termination of FlowCalculator task"
    @atomic flowcalc_ipc.shared_state.should_exit = true

    @info "Waiting for FlowCalculator task to exit"
    wait(flowcalc_task)
    collect_telemetry!()

    @info "Cleaning up OpenGL resources"
    teardown_glmap(globjmap)
    return nothing
end

# Application persistence

"Save a map or bundle with the Rocket Plumber version from root package metadata."
function save_game(map::Union{GameMap, GameMapBundle}, save_path::String)
    HexFlowPersistence.savemap(map, save_path; game_version = Base.pkgversion(@__MODULE__))
    return nothing
end

"Write calculator crash diagnostics with the root package version."
function write_game_crash_dump(payload::NamedTuple)
    return HexFlowPersistence.write_crash_dump(payload; game_version = Base.pkgversion(@__MODULE__), directory = crashes_dir())
end

# Map-source dispatch

"Dispatch map loading from multiple source types."
function loadmap_from_source(map_source::Union{Nothing, String, GameMap, ShipState})::GameMap
    map_source isa GameMap && (@info "Using pre-generated GameMap"; return map_source)
    map_source isa ShipState && (@info "Wrapping ShipState as primary ship"; return GameMap(map_source))
    isnothing(map_source) && (@info "No map path provided; starting empty."; return GameMap())
    return loadmap(map_source)
end

"Load a map source together with any time-lapse history available from a file source."
function loadmap_bundle_from_source(map_source::Union{Nothing, String, GameMap, ShipState})::GameMapBundle
    map_source isa String && return loadmap_bundle(map_source)
    return GameMapBundle(loadmap_from_source(map_source))
end

# ===============================================================
# Game Main Loop
# ===============================================================

"Result of `enter_gameloop`, including the map and its optional time-lapse."
@kwdef struct GameLoopResult
    exit_reason::ExitReason
    tutorial_id::Union{Nothing, Symbol} = nothing
    saved_bundle::GameMapBundle
end

"Build the runtime learning state from the loaded map's learning-system type."
function build_learning_runtime_state(gamemap::GameMap; initial_active_tutorial_id::Union{Nothing, Symbol} = nothing)::Union{Nothing, LearningSystemState}
    learning_system = get_learning_system(gamemap)
    learning_system isa NoLearningSystem && return nothing

    all_entries = get_learning_entries()
    effective_entries = if learning_system isa SandboxLearningState
        get_sandbox_learning_entries()
    else
        filter(e -> haskey(learning_system.tutorials, e.id), all_entries)
    end
    sorted_entries = sort(effective_entries; by = entry -> entry.priority)

    hint_id = if learning_system isa SandboxLearningState
        learning_system.tutorial_id
    else
        initial_active_tutorial_id
    end

    return LearningSystemState(
        map_learning = learning_system,
        entries = sorted_entries,
        active_hint_id = hint_id,
    )
end

"Capture a detached map with the render-owned session state materialised."
function capture_session_gamemap(
        gamemap::GameMap, session_timing::PlaySessionTiming, learning_state::Union{Nothing, LearningSystemState},
    )::GameMap
    captured_gamemap = deepcopy(gamemap)
    set_recorded_play_time_seconds!(captured_gamemap, get_current_play_time_seconds(session_timing))
    if !isnothing(learning_state)
        set_learning_system!(captured_gamemap, deepcopy(learning_state.map_learning))
    end
    return captured_gamemap
end

"Build a fresh-session map from an escape attempt's recoverable departure checkpoint."
function capture_galaxy_escape_restart_gamemap(
        gamemap::GameMap, session_timing::PlaySessionTiming,
        learning_state::Union{Nothing, LearningSystemState},
    )::Union{Nothing, GameMap}
    can_abort_galaxy_escape(gamemap) || return nothing
    pre_escape_map = get_pre_escape_map(gamemap)::GameMap
    return capture_session_gamemap(pre_escape_map, session_timing, learning_state)
end

"Return whether ordinary periodic capture should be suppressed for the current render state."
function is_timelapse_capture_suppressed(inputstate::InputState, gamemap::GameMap; window_focused::Bool)::Bool
    return inputstate.spacemap_active ||
        inputstate.escape_menu_active ||
        !window_focused ||
        is_galaxy_escape_active(gamemap)
end

"Apply the render-owned save boundary and persist the current map/history bundle."
function save_current_map(
        recorder::TimelapseRecorder, snapshot::FlowCalculatorSnapshot, session_timing::PlaySessionTiming,
        learning_state::Union{Nothing, LearningSystemState}, save_path::String,
    )
    gamemap_to_save = capture_session_gamemap(snapshot.gamemap, session_timing, learning_state)
    if !is_galaxy_escape_active(snapshot.gamemap)
        capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    end
    save_game(GameMapBundle(gamemap_to_save, snapshot_timelapse_history(recorder)), save_path)
    return nothing
end

"Persist a pre-escape map as the final normal ship frame without capturing escape flight."
function save_pre_escape_map(recorder::TimelapseRecorder, gamemap::GameMap, save_path::String)
    pre_escape_map = get_pre_escape_map(gamemap)::GameMap
    capture_timelapse_frame!(recorder, pre_escape_map)
    save_game(GameMapBundle(pre_escape_map, snapshot_timelapse_history(recorder)), save_path)
    return nothing
end

"Enter the main game loop with a loaded, generated, or empty map. An optional frame hook receives the current snapshot, input state, command queue, and calculator task."
function enter_gameloop(
        window::GLFW.Window;
        map_source::Union{Nothing, String, GameMap, ShipState} = nothing,
        initial_bundle::Union{Nothing, GameMapBundle} = nothing,
        initial_active_tutorial_id::Union{Nothing, Symbol} = nothing,
        frame_hook::Union{Nothing, Function} = nothing,
        window_mode::WindowModeState = WindowModeState(),
    )::GameLoopResult

    # Initialise session state
    expected_render_thread_id = Threads.threadid()
    ui_loadingscreen_render(window, "Instantiating game state")
    attach_glfw_callbacks!(window)
    g_inputstate, g_viewstate = init_input_viewstates(window)

    # The window may have been resized before entering the game loop
    glViewport(0, 0, g_viewstate.fb_width, g_viewstate.fb_height)

    ui_loadingscreen_render(window, "Loading map")
    loaded_bundle = isnothing(initial_bundle) ? loadmap_bundle_from_source(map_source) : initial_bundle
    loaded_gamemap::GameMap = loaded_bundle.gamemap
    timelapse_recorder = TimelapseRecorder(loaded_bundle.timelapse)
    session_timing = PlaySessionTiming(get_recorded_play_time_seconds(loaded_gamemap))
    completed_gamemap::Union{Nothing, GameMap} = nothing
    restart_gamemap::Union{Nothing, GameMap} = nothing
    learning_state = build_learning_runtime_state(loaded_gamemap; initial_active_tutorial_id)
    initial_snapshot::FlowCalculatorSnapshot = FlowCalculatorSnapshot(
        gamemap = loaded_gamemap,
        gamestate = GameState(estimated_min_delta_v = estimate_min_delta_v(loaded_gamemap)),
        timestamp = time()
    )

    ui_loadingscreen_render(window, "Setting up IPC")
    g_flowcalc_ipc = setup_flowcalc_ipc(initial_snapshot)

    ui_loadingscreen_render(window, "Initialising OpenGL Objects")
    g_globjmap, g_renderqueue, g_scratch_renderqueue = init_opengl_objects()

    # Initialise rendering state
    g_viewstate.background_particles = ParticleManager(0.03f0)  # Small dust particles
    g_viewstate.foreground_particles = ParticleManager(0.06f0)  # Larger exhaust particles

    GLFW.SwapInterval(1)  # Enable VSync
    glClearColor(0.114, 0.161, 0.318, 1.0)  # Space cadet blue

    g_recording = RecordingState()
    escape_save_state = EscapeSaveState()

    ui_loadingscreen_render(window, "Starting FlowCalculator")
    g_flowcalc_task = Threads.@spawn flowcalculator_loop!(
        g_flowcalc_ipc, deepcopy(initial_snapshot);
        crash_dump_writer = write_game_crash_dump,
    )
    @info "FlowCalculator task spawned: $(g_flowcalc_task)"

    # MAIN LOOP
    ui_loadingscreen_render(window, "Entering main loop")

    while isnothing(g_inputstate.exit_reason) && !GLFW.WindowShouldClose(window)
        # Guard against the render loop changing threads, which can cause GLFW/OpenGL issues
        current_render_thread_id = Threads.threadid()
        if current_render_thread_id != expected_render_thread_id
            @warn "Render loop changed Julia threads" expected_render_thread_id current_render_thread_id maxlog = 1
        end

        g_viewstate.frame_count += 1
        updatefps(window, g_inputstate.is_recording ? "(RECORDING)" : "")
        # Keep this snapshot in use through all frame processing; only acquire again at the next frame.
        @timeit render_loop_timer "Get Snapshot" g_snapshot::FlowCalculatorSnapshot = g_flowcalc_ipc.get_snapshot()

        if !isnothing(frame_hook)
            frame_hook(g_snapshot, g_inputstate, g_flowcalc_ipc.command_queue, g_flowcalc_task)
        end

        # Advance the learning system
        if !isnothing(learning_state) && isnothing(completed_gamemap)
            learning_inputs = LearningInputs(
                gamemap = g_snapshot.gamemap,
                derivedmapstate = g_snapshot.derived,
                gamestate = g_snapshot.gamestate,
                inputstate = g_inputstate,
                viewstate = g_viewstate,
                flowcalc_shared_state = g_flowcalc_ipc.shared_state,
            )
            learning_system_tick!(learning_state, learning_inputs)
        end

        # Render the frame
        glClear(GL_COLOR_BUFFER_BIT)
        if isnothing(completed_gamemap)
            custom_rendering!(
                g_renderqueue, g_scratch_renderqueue, g_globjmap, g_snapshot,
                g_flowcalc_ipc.shared_state, g_inputstate, g_viewstate,
            )
        end
        escape_save_pending = !isnothing(escape_save_state.pending_path)
        @timeit render_loop_timer "UI Rendering" ui_rendering!(
            g_inputstate, g_flowcalc_ipc, timelapse_recorder, g_snapshot, g_viewstate, window;
            learning_state = learning_state,
            session_timing = session_timing,
            completed_gamemap = completed_gamemap,
            escape_save_state = escape_save_state,
        )

        # Resolve escape transitions
        if g_inputstate.exit_reason == EXIT_RESTART
            restart_gamemap = capture_galaxy_escape_restart_gamemap(
                g_snapshot.gamemap, session_timing, learning_state,
            )
            if !isnothing(restart_gamemap)
                @atomic :monotonic g_flowcalc_ipc.shared_state.should_exit = true
            else
                g_inputstate.exit_reason = nothing
                g_flowcalc_ipc.console_push("This escape attempt does not contain a recoverable pre-departure map.")
            end
        elseif g_inputstate.galaxy_escape_completion_requested
            g_inputstate.galaxy_escape_completion_requested = false

            # The displayed snapshot defines the result; only this detached copy becomes render-owned.
            completed_gamemap = capture_session_gamemap(g_snapshot.gamemap, session_timing, learning_state)
            @atomic :monotonic g_flowcalc_ipc.shared_state.should_exit = true
        end
        # Capture on the frame after the save dialog closed, with the victory UI fully rendered
        if escape_save_pending
            finish_escape_save!(
                escape_save_state,
                path -> begin
                    fb_size = GLFW.GetFramebufferSize(window)
                    capture_screenshot!(g_recording, Int32(fb_size.width), Int32(fb_size.height), path)
                end,
                g_flowcalc_ipc.console_push,
            )
        end
        recording_tick!(g_recording, g_inputstate, g_viewstate, window, g_flowcalc_ipc.console_push)
        GLFW.SwapBuffers(window)

        # Process input against the displayed snapshot
        GLFW.PollEvents()
        poll_window_mode!(window_mode, window)

        if isnothing(completed_gamemap) && isnothing(restart_gamemap)
            @timeit render_loop_timer "User Input Handling" user_handler!(g_flowcalc_ipc, g_inputstate, g_viewstate, g_snapshot, window)
        else
            poll_windowstate!(g_viewstate, window)
        end

        # Capture time-lapse history during ordinary play
        if isnothing(completed_gamemap) && isnothing(restart_gamemap)
            capture_suppressed = is_timelapse_capture_suppressed(
                g_inputstate, g_snapshot.gamemap;
                window_focused = GLFW.GetWindowAttrib(window, GLFW.FOCUSED) != 0,
            )
            maybe_capture_timelapse!(
                timelapse_recorder, g_snapshot;
                capture_suppressed, now = Float64(time_ns()) / 1.0e9,
            )
        end

        handle_diagnostics(render_loop_diagnostic_config, g_viewstate.frame_count)

        # Let Julia service pending tasks and timer wake-ups between frames.
        yield()
    end

    # Materialise the session result
    result_snapshot = g_flowcalc_ipc.get_snapshot()
    if !isnothing(restart_gamemap)
        saved_bundle = GameMapBundle(restart_gamemap, snapshot_timelapse_history(timelapse_recorder))
    elseif isnothing(completed_gamemap)
        if timelapse_recorder.enabled && !is_galaxy_escape_active(result_snapshot.gamemap)
            capture_timelapse_frame!(timelapse_recorder, result_snapshot.gamemap; snapshot_timestamp = result_snapshot.timestamp)
        end
        saved_map = capture_session_gamemap(result_snapshot.gamemap, session_timing, learning_state)
        saved_bundle = GameMapBundle(saved_map, snapshot_timelapse_history(timelapse_recorder))
    else
        saved_bundle = GameMapBundle(completed_gamemap, snapshot_timelapse_history(timelapse_recorder))
    end
    reason = something(g_inputstate.exit_reason, EXIT_QUIT)
    result = GameLoopResult(
        exit_reason = reason,
        tutorial_id = g_inputstate.pending_sandbox_id,
        saved_bundle = saved_bundle,
    )

    # Shut down session resources
    if g_recording.is_recording
        stop_recording!(g_recording, g_flowcalc_ipc.console_push)
    end

    cleanup!(g_flowcalc_ipc, g_flowcalc_task, g_globjmap, window)

    return result
end
