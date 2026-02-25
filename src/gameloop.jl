# ===============================================================
# Helper Functions for the Game Main Loop
# ===============================================================

using HexFlowTelemetry, FlowMap, FlowEngine, HexFlowProcGen
using StaticArrays
using LinearAlgebra

"Uses RenderEngine to initialise OpenGL objects needed for the game loop"
function init_opengl_objects()
    glmap::GLObjectMap = GLObjectMap()
    renderqueue::Vector{RenderCommand} = Vector{RenderCommand}()

    viewtransform_glubo_init(glmap)
    basesprite_glprog_init(glmap)
    texatlas1_gltex_init(glmap)
    liquidsprite_glprog_init(glmap)
    gassprite_glprog_init(glmap)
    particle_glprog_init(glmap)

    return glmap, renderqueue
end

"""
Renders frame by pushing render commands to the renderqueue and executing them.
Handles both background and foreground particle systems with proper layering.
"""
function custom_rendering!(
        renderqueue::Vector{RenderCommand},
        glmap::GLObjectMap,
        snapshot::FlowCalculatorSnapshot,
        shared_state::FlowCalculatorSharedState,
        inputstate::InputState,
        viewstate::ViewState
    )
    empty!(renderqueue)

    set_view_ubo(glmap, get_viewtransform(viewstate))

    # Render background particles FIRST (behind everything else)
    if !isnothing(viewstate.background_particles)
        @timeit render_loop_timer "Particle Systems" begin
            @timeit render_loop_timer "Background Particles" begin
                if !shared_state.is_paused # skip if paused
                    thrust_dust_particle_effect!(viewstate.background_particles, snapshot.gamestate, snapshot.gamemap)
                    update_particle_physics!(viewstate.background_particles, snapshot.gamestate, count_surface_tiles(snapshot.gamemap))
                end
                # Enable ship surface culling for background particles by passing gamemap
                render_particles!(glmap, viewstate.background_particles, viewstate, snapshot.timestamp, shared_state.actual_ups, snapshot.gamemap)
            end
        end
    end

    # Render queued elements (tiles, pipes, nodes)
    @timeit render_loop_timer "Sprite Rendering" begin
        @timeit render_loop_timer "Populate Render Queue" begin
            @timeit render_loop_timer "Ship Surface" ship_surface_queued_render!(renderqueue, glmap, snapshot.gamemap)
            @timeit render_loop_timer "Docking Beams" render_docking_beams!(renderqueue, glmap, snapshot.gamemap, snapshot.gamestate.ticks)
            @timeit render_loop_timer "Tiles" tile_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna, snapshot.gamestate)
            @timeit render_loop_timer "Ghosts" render_cursor_ghosts!(renderqueue, glmap, inputstate, snapshot.gamemap, snapshot.gamestate)
            @timeit render_loop_timer "Pipes" pipe_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.gamestate)
            @timeit render_loop_timer "Nodes" node_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna)
        end

        @timeit render_loop_timer "Execute Render Queue" glrender(glmap, renderqueue)
    end

    # Render foreground particles LAST (on top of tiles)
    if !isnothing(viewstate.foreground_particles)
        @timeit render_loop_timer "Particle Systems" begin
            @timeit render_loop_timer "Foreground Particles" begin
                if !shared_state.is_paused # skip if paused
                    tile_particle_spawn!(viewstate.foreground_particles, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna, snapshot.gamestate)
                    update_particle_physics!(viewstate.foreground_particles, snapshot.gamestate, count_surface_tiles(snapshot.gamemap))
                end
                # Disable ship surface culling for foreground particles by passing nothing as gamemap
                render_particles!(glmap, viewstate.foreground_particles, viewstate, snapshot.timestamp, shared_state.actual_ups, nothing)
            end
        end
    end

    return nothing
end

"Sets up the IPC data structures for the FlowCalculator task"
function setup_flowcalc_ipc(initial_snapshot::FlowCalculatorSnapshot)::FlowCalculatorIPC
    shared_state = FlowCalculatorSharedState()
    command_queue = create_command_queue(32)
    set_snapshot, get_snapshot = create_snapshot_storage(deepcopy(initial_snapshot))
    console_push, console_see = create_threadsafe_consolebuffer(50)

    return FlowCalculatorIPC(
        shared_state,
        command_queue,
        set_snapshot,
        get_snapshot,
        console_push,
        console_see
    )
end

"Creates input and view state structs, populating window and framebuffer sizes"
function init_input_viewstates(window::GLFW.Window)::Tuple{InputState, ViewState}
    inputstate = InputState(
        pendingcomponent = deepcopy(component_list[1]),
        pendingpipebehavior = ScrapPipeBehav()
    )
    viewstate = ViewState()

    winsize = GLFW.GetWindowSize(window)
    viewstate.window_width = winsize.width
    viewstate.window_height = winsize.height

    fbsize = GLFW.GetFramebufferSize(window)
    viewstate.fb_width = fbsize.width
    viewstate.fb_height = fbsize.height

    return inputstate, viewstate
end

"Handles user inputs and updates inputstate, viewstate, and enqueues commands to flowcalc_ipc"
function user_handler!(
        flowcalc_ipc::FlowCalculatorIPC,
        inputstate::InputState,
        viewstate::ViewState,
        snapshot::FlowCalculatorSnapshot,
        window::GLFW.Window
    )
    # Update ship bounds before input handling so limits are current
    update_ship_bounds!(viewstate, snapshot.gamemap)

    # Set time progression flag for input blocking (space map M key toggle)
    inputstate.gui_inputs[:time_progressing] = is_time_progressing(snapshot.gamemap)

    GLFW.PollEvents()
    cimgui_io = CImGui.GetIO()
    handle_inputs!(inputstate, viewstate, window, cimgui_io) # input handling (window sizes, cursor, keys, scroll)
    handle_flowcalc_sharedstate!(inputstate, flowcalc_ipc.shared_state, window, flowcalc_ipc.console_push)

    if !unsafe_load(cimgui_io.WantCaptureMouse) # don't handle mouse if clicking GUI
        flowcalc_tileplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_pipeplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_moveplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_deleteplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_interactor!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_surfaceeditor!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_swap_primary_ship!(flowcalc_ipc, inputstate, snapshot.gamemap, window)
        flowcalc_beam_depart!(flowcalc_ipc, inputstate, viewstate, snapshot.gamemap, window)
    end

    return update_lastinstate!(inputstate, window)
end

"Renders the CImGui UI elements, which mutates the inputstate"
function ui_rendering!(
        inputstate::InputState,
        flowcalc_ipc::FlowCalculatorIPC,
        snapshot::FlowCalculatorSnapshot,
        viewstate::ViewState,
        window::GLFW.Window,
        tutorial_hint::Union{Nothing, HintData} = nothing
    )
    pendingcomponent_typeupdate!(inputstate)
    
    # Calculate bounds for interactions
    max_view_bounds = get_max_reachable_bounds(viewstate)
    
    return ui_renderwrap() do
        ui_velocity_tracker_render(snapshot.gamestate, snapshot.gamemap, inputstate, flowcalc_ipc, max_view_bounds)
        ui_toolbar_render!(inputstate, GLFW.GetWindowSize(window), flowcalc_ipc.console_see)
        ui_propertybox_render!(inputstate, snapshot.gamemap, snapshot.derived, snapshot.mna, GLFW.GetWindowSize(window))
        ui_pause_menu_render!(inputstate, snapshot, window)
        ui_confirmation_popup_render!(inputstate, viewstate)
        ui_dev_utils_menu_render!(inputstate, flowcalc_ipc, snapshot, viewstate, GLFW.GetWindowSize(window), max_view_bounds)
        ui_spacemap_render!(inputstate, flowcalc_ipc, snapshot, GLFW.GetWindowSize(window), max_view_bounds)

        # Render hint box if hint data exists and is visible
        if !isnothing(tutorial_hint) && tutorial_hint.is_visible
            ui_hintbox_render!(tutorial_hint, inputstate, GLFW.GetWindowSize(window))
        end
    end
end

"Cleans up resources, windows, and requests FlowCalculator task termination"
function cleanup!(flowcalc_ipc::FlowCalculatorIPC, globjmap::GLObjectMap, window::GLFW.Window)
    @info "Requesting termination of FlowCalculator task"
    @atomic flowcalc_ipc.shared_state.should_exit = true

    @info "Cleaning up OpenGL resources"
    teardown_glmap(globjmap)
    return nothing
    # CImGui teardown handled by start menu now
end

# ===============================================================
# JLD2 Serialisation
# ===============================================================
# See: https://juliaio.github.io/JLD2.jl/stable/advanced/#Upgrading-old-structures-on-load
#
# We rely on `rconvert` to upgrade old on-disk NamedTuple representations
# into the current struct types when loading saves.
# Transient fields (such as event queues inside space-map state) are not
# expected to be valid on disk and are always rebuilt when constructing
# fresh runtime state after load. The use of `get()` with defaults below
# ensures that future field additions do not break loading of older saves.

import JLD2: rconvert

#= ---------- ShipMap (legacy FlowEngine upgrades) ----------- =#

"Conversion for old `ShipMap` saved representations"
JLD2.rconvert(::Type{FlowMap.ShipMap}, nt::NamedTuple) = FlowMap.ShipMap(
    components = get(nt, :components, Dict{TileCoord, ComponentOnTile}()),
    pipe_behaviors = get(nt, :pipe_behaviors, Dict{EdgeCoord, PipeBehavior}()),
    ship_tiles = get(nt, :ship_tiles, Set{TileCoord}([TileCoord(0, 0)])),
    docking_status = get(nt, :docking_status, FlowMap.ConnectedDockStat())
)

"Conversion for old `GameMap` saved representations that lack `space_map`"
JLD2.rconvert(::Type{FlowMap.GameMap}, nt::NamedTuple) = FlowMap.GameMap(
    ships = get(nt, :ships, Dict(:primary => FlowMap.ShipMap())),
    space_map = get(nt, :space_map, FlowMap.SpaceMapEmpty()),
)

#= ---------- SpaceMapEmpty ----------- =#

"Rebuild `SpaceMapEmpty` from a NamedTuple (JLD2 Upgrade path)."
JLD2.rconvert(::Type{SpaceMapEmpty}, nt::NamedTuple) = SpaceMapEmpty(
    velocity = get(nt, :velocity, SVector{2,Float64}(0.0, 0.0)),
)

#= ---------- ManoeuvreData ----------- =#

"""Rebuild `ManoeuvreData` from a NamedTuple (JLD2 Upgrade path).

Handles three legacy formats:
1. **Very old**: has `target_delta_v`/`intercept_delta_v` (no `main_burn_dv`). Uses vectors as-is.
2. **Legacy**: has `main_burn_dv` (ship-local) + `main_burn_direction` unit vector. Reconstructs
   space-map ΔV via `direction × magnitude`.
3. **Current**: has `main_burn_dv`/`decel_burn_dv` as full space-map vectors (no `main_burn_direction`).
"""
function JLD2.rconvert(::Type{ManoeuvreData}, nt::NamedTuple)
    if haskey(nt, :target_delta_v) && !haskey(nt, :main_burn_dv)
        # Very old format: target_delta_v → main_burn_dv, intercept_delta_v → decel_burn_dv
        main_dv  = get(nt, :target_delta_v,    SVector(0.0, 0.0))
        decel_dv = get(nt, :intercept_delta_v, SVector(0.0, 0.0))
    elseif haskey(nt, :main_burn_direction)
        # Legacy: reconstruct space-map ΔV from direction × magnitude
        dir_main  = get(nt, :main_burn_direction,  SVector(1.0, 0.0))
        dir_decel = get(nt, :decel_burn_direction, SVector(1.0, 0.0))
        main_dv   = dir_main  * norm(nt.main_burn_dv)
        decel_dv  = dir_decel * norm(nt.decel_burn_dv)
    else
        # Current format
        main_dv  = nt.main_burn_dv
        decel_dv = nt.decel_burn_dv
    end

    ManoeuvreData(
        phase              = get(nt, :phase, PHASE_WAIT_APPROACH),
        main_burn_dv       = main_dv,
        decel_burn_dv      = decel_dv,
        burn_target_dv     = get(nt, :burn_target_dv, SVector(0.0, 0.0)),
        burn_remaining_dv  = get(nt, :burn_remaining_dv, SVector(0.0, 0.0)),
        closest_approach_time = get(nt, :closest_approach_time, 0.0),
        intercept_time     = get(nt, :intercept_time, 0.0),
        target_encounter_index = get(nt, :target_encounter_index, 0),
        trajectory_start_pos  = get(nt, :trajectory_start_pos, SVector(0.0, 0.0)),
        trajectory_start_time = get(nt, :trajectory_start_time, 0.0),
        surplus_dv         = get(nt, :surplus_dv, 0.0),
        main_burn_position  = get(nt, :main_burn_position, SVector(0.0, 0.0)),
        decel_burn_position = get(nt, :decel_burn_position, SVector(0.0, 0.0)),
    )
end

#= ---------- SpaceMapState ----------- =#

"Rebuild `SpaceMapState` from a NamedTuple — event_queue is always fresh (rebuilt after load)."
JLD2.rconvert(::Type{SpaceMapState}, nt::NamedTuple) = SpaceMapState(
    seed               = get(nt, :seed, UInt32(0)),
    velocity           = get(nt, :velocity, SVector{2,Float64}(0.0, 0.0)),
    position           = get(nt, :position, SVector{2,Float64}(0.0, 0.0)),
    time_years         = get(nt, :time_years, 0.0),
    target_time_years  = get(nt, :target_time_years, 0.0),
    active_manoeuvre    = get(nt, :active_manoeuvre, nothing),
    encounter_points   = get(nt, :encounter_points, EncounterPoint[]),
    neg_disappear_line_x = get(nt, :neg_disappear_line_x, -1600.0),
    neg_spawn_line_x     = get(nt, :neg_spawn_line_x, -1500.0),
    pos_spawn_line_x     = get(nt, :pos_spawn_line_x, 1500.0),
    pos_disappear_line_x = get(nt, :pos_disappear_line_x, 1600.0),
    last_line_step_x   = get(nt, :last_line_step_x, 0.0),
    line_step_size     = get(nt, :line_step_size, 200.0),
    viewport_half_width  = get(nt, :viewport_half_width, 1000.0),
    viewport_half_height = get(nt, :viewport_half_height, 500.0),
)

function loadmap(mappath::Union{Nothing, String})::GameMap
    # gaurd clause for empty path
    if isnothing(mappath)
        @info "No map loaded..."
        return GameMap()        
    end

    # load attempts
    stored_gamemap::Union{GameMap, ShipMap, Nothing} = nothing
    if isnothing(stored_gamemap)
        try
            # The top-level `JLD2.rconvert` registration (above) handles
            # upgrading old `ShipMap` structs that lack `render_position_offset`.
            # Provide typemap so JLD2 will attempt an upgrade to current ShipMap
            typemap = Dict(
                "FlowEngine.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
                "FlowEngine.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
                "FlowEngine.DockingStatus" => JLD2.Upgrade(FlowMap.DockingStatus),
                "FlowEngine.ConnectedDockStat" => JLD2.Upgrade(FlowMap.ConnectedDockStat),
                "FlowEngine.ApproachingDockStat" => JLD2.Upgrade(FlowMap.ApproachingDockStat),
                "FlowEngine.DepartingDockStat" => JLD2.Upgrade(FlowMap.DepartingDockStat),
                "FlowEngine.RenderPosOffsetState" => JLD2.Upgrade(FlowMap.RenderPosOffsetState),
                "FlowMap.SpaceMapEmpty" => JLD2.Upgrade(FlowMap.SpaceMapEmpty),
                "FlowMap.SpaceMapState" => JLD2.Upgrade(FlowMap.SpaceMapState),
                "FlowMap.ManoeuvreData" => JLD2.Upgrade(FlowMap.ManoeuvreData),
            )

            # Use the functional API instead of macro so we can pass keyword args (typemap) safely
            stored_gamemap = JLD2.load(mappath, "stored_gamemap"; typemap=typemap)
        catch e
            @info "Standard map load failed:\n$e"
        end
    end

    # If a ShipMap was saved directly (legacy single-ship save), wrap it
    if stored_gamemap isa ShipMap
        @info "Loaded ShipMap directly from file; wrapping as GameMap"
        stored_gamemap = GameMap(stored_gamemap)
    end

    if isnothing(stored_gamemap)
        @info "Attempting legacy map load 1..."
        try
            @load mappath TileDict PipeBehaviorDict ShipSurface
            ship = ShipMap(components = TileDict, pipe_behaviors = PipeBehaviorDict, ship_tiles = ShipSurface)
            stored_gamemap = GameMap(ship)
        catch e
            @info "Legacy map load 1 failed:\n$e"
        end
    end

    if isnothing(stored_gamemap)
        @info "Attempting legacy map load 2..."
        try
            @load mappath TileDict PipeBehaviorDict
            ship = ShipMap(components = TileDict, pipe_behaviors = PipeBehaviorDict)
            stored_gamemap = GameMap(ship)
        catch e
            @info "Legacy map load 2 failed:\n$e"
        end
    end
    
    # final check
    if isnothing(stored_gamemap)
        @warn "All map loading attempts failed. Returning empty map."
        stored_gamemap = GameMap()
    end

    # Rebuild event queue if SpaceMapState loaded (BinaryMinHeap may not round-trip via JLD2)
    sm = stored_gamemap.space_map
    if sm isa SpaceMapState && !isempty(sm.encounter_points)
        rebuild_event_queue!(sm)
        @info "Rebuilt encounter event queue after map load" n_events=length(sm.event_queue)
    end

    return stored_gamemap
end

"""
Load a GameMap from various sources:
- `nothing`: Return an empty map
- `String`: Load from JLD2 file path
- `GameMap`: Return the GameMap directly (pass-through)
"""
function loadmap_from_source(map_source::Union{Nothing, String, GameMap, ShipMap})::GameMap
    if map_source isa GameMap
        @info "Using pre-generated GameMap"
        return map_source
    elseif map_source isa ShipMap
        @info "Wrapping pre-generated ShipMap as primary ship"
        return GameMap(map_source)
    else
        return loadmap(map_source)
    end
end

"Saves the gamemap to the specified path."
function savemap(gamemap::GameMap, mappath::Union{Nothing, String})
    if isnothing(mappath)
        @info "Map not saved..."
        return
    end

    try
        jldsave(mappath; stored_gamemap = gamemap)
        @info "Map saved as  $mappath"
    catch e
        @error "An error occurred while saving map: $e"
    end

    return nothing
end

# ===============================================================
# Game Main Loop
# ===============================================================

"Enter the main game loop with a map loaded from a file path (String), a pre-generated GameMap, or an empty map (nothing)."
function enter_gameloop(window::GLFW.Window; map_source::Union{Nothing, String, GameMap} = nothing, tutorial_hint::Union{Nothing, HintData} = nothing)
    #= Loop Setup =#
    ui_loadingscreen_render(window, "Instantiating game state")
    attach_glfw_callbacks!(window)
    g_inputstate, g_viewstate = init_input_viewstates(window)

    # Set OpenGL viewport to match current framebuffer size (important if window was resized before entering game loop)
    glViewport(0, 0, g_viewstate.fb_width, g_viewstate.fb_height)

    ui_loadingscreen_render(window, "Loading map")
    loaded_gamemap::GameMap = loadmap_from_source(map_source)
    initial_snapshot::FlowCalculatorSnapshot = FlowCalculatorSnapshot(
        gamemap = loaded_gamemap,
        timestamp = time()
    )

    ui_loadingscreen_render(window, "Setting up IPC")
    g_flowcalc_ipc = setup_flowcalc_ipc(initial_snapshot)

    ui_loadingscreen_render(window, "Initialising OpenGL Objects")
    g_globjmap, g_renderqueue = init_opengl_objects()

    # Initialize particle systems
    g_viewstate.background_particles = ParticleManager(0.03f0)  # Small size for dust
    g_viewstate.foreground_particles = ParticleManager(0.06f0)  # Larger size for exhaust

    GLFW.SwapInterval(1) # 0=Disable VSync, 1=Enable VSync
    glClearColor(0.114, 0.161, 0.318, 1.0) # Set background colour to space cadet blue

    ui_loadingscreen_render(window, "Starting FlowCalculator")
    g_flowcalc_task = Threads.@spawn flowcalculator_loop!(g_flowcalc_ipc, deepcopy(initial_snapshot))
    @info "FlowCalculator task spawned: $(g_flowcalc_task)"

    #= Main Loop =#
    ui_loadingscreen_render(window, "Entering main loop")

    while !g_inputstate.should_exit_gameloop
        g_viewstate.frame_count += 1
        updatefps(window)
        @timeit render_loop_timer "Get Snapshot" g_snapshot::FlowCalculatorSnapshot = g_flowcalc_ipc.get_snapshot()

        # RENDERING Start
        glClear(GL_COLOR_BUFFER_BIT)
        custom_rendering!(g_renderqueue, g_globjmap, g_snapshot, g_flowcalc_ipc.shared_state, g_inputstate, g_viewstate)
        @timeit render_loop_timer "UI Rendering" ui_rendering!(g_inputstate, g_flowcalc_ipc, g_snapshot, g_viewstate, window, tutorial_hint)
        GLFW.SwapBuffers(window)
        # RENDERING End

        @timeit render_loop_timer "User Input Handling" user_handler!(g_flowcalc_ipc, g_inputstate, g_viewstate, g_snapshot, window)

        handle_diagnostics(render_loop_diagnostic_config, g_viewstate.frame_count)
        print_gc_statistics()
    end # main loop

    cleanup!(g_flowcalc_ipc, g_globjmap, window)
    return g_inputstate.return_symbol
end # enter_gameloop
