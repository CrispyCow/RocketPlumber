# ===============================================================
# Helper Functions for the Game Main Loop
# ===============================================================

using HexFlowTelemetry

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
                    thrust_dust_particle_effect!(viewstate.background_particles, snapshot.gamestate, snapshot.derived)
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
            @timeit render_loop_timer "Tiles" tile_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.mna, snapshot.gamestate)
            @timeit render_loop_timer "Ghosts" render_cursor_ghosts!(renderqueue, glmap, inputstate, snapshot.gamemap, snapshot.gamestate)
            @timeit render_loop_timer "Pipes" pipe_queued_render!(renderqueue, glmap, snapshot.gamemap, snapshot.derived, snapshot.gamestate)
            @timeit render_loop_timer "Nodes" node_queued_render!(renderqueue, glmap, snapshot.derived, snapshot.mna)
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
    GLFW.PollEvents()
    cimgui_io = CImGui.GetIO()
    handle_inputs!(inputstate, viewstate, window, cimgui_io) # input handling (window sizes, cursor, keys, scroll)
    handle_flowcalc_sharedstate!(inputstate, flowcalc_ipc.shared_state, window, flowcalc_ipc.console_push)

    if !unsafe_load(cimgui_io.WantCaptureMouse) # don't handle mouse if clicking GUI
        flowcalc_tileplacer!(flowcalc_ipc.command_queue, inputstate, flowcalc_ipc.console_push)
        flowcalc_pipeplacer!(flowcalc_ipc.command_queue, inputstate, flowcalc_ipc.console_push)
        flowcalc_moveplacer!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
        flowcalc_deleteplacer!(flowcalc_ipc.command_queue, inputstate, flowcalc_ipc.console_push)
        flowcalc_interactor!(flowcalc_ipc.command_queue, inputstate, flowcalc_ipc.console_push)
        flowcalc_surfaceeditor!(flowcalc_ipc.command_queue, inputstate, snapshot.gamemap, flowcalc_ipc.console_push)
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
    return ui_renderwrap() do
        ui_timer_render(
            snapshot.gamestate.ticks,
            viewstate.frame_count,
            (@atomic flowcalc_ipc.shared_state.actual_ups),
            snapshot.gamestate.thrust,
            snapshot.gamestate.impulse
        )
        ui_toolbar_render!(inputstate, GLFW.GetWindowSize(window), flowcalc_ipc.console_see)
        ui_propertybox_render!(inputstate, snapshot.gamemap, snapshot.derived, snapshot.mna, GLFW.GetWindowSize(window))
        ui_pause_menu_render!(inputstate, snapshot, window)
        ui_dev_utils_menu_render!(inputstate, flowcalc_ipc, GLFW.GetWindowSize(window))

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

function loadmap(mappath::Union{Nothing, String})::GameMap
    TileDict = Dict{TileCoord, ComponentOnTile}()
    PipeBehaviorDict = Dict{EdgeCoord, PipeBehavior}()
    ShipSurface = Set{TileCoord}()

    if isnothing(mappath)
        # leave map empty
        @info "No map loaded..."
    else
        try
            @load mappath TileDict PipeBehaviorDict ShipSurface
            @info "Map $mappath loaded successfully"
        catch e
            # Handle old maps without ShipSurface gracefully
            try
                @load mappath TileDict PipeBehaviorDict
                @info "Map $mappath loaded (legacy format, no ship surface)"
            catch e2
                @error "An error occurred while loading map: $e2"
            end
        end
    end

    return GameMap(tiles = TileDict, pipe_behaviors = PipeBehaviorDict, ship_surface = ShipSurface)
end

"""
Load a GameMap from various sources:
- `nothing`: Return an empty map
- `String`: Load from JLD2 file path
- `GameMap`: Return the GameMap directly (pass-through)
"""
function loadmap_from_source(map_source::Union{Nothing, String, GameMap})::GameMap
    if map_source isa GameMap
        @info "Using pre-generated GameMap"
        return map_source
    else
        return loadmap(map_source)
    end
end

"Opens the save map dialogue in the terminal"
function savemap(gamemap::GameMap, mappath::Union{Nothing, String})
    if isnothing(mappath)
        @info "Map not saved..."
        return
    end

    try
        TileDict = gamemap.tiles
        PipeBehaviorDict = gamemap.pipe_behaviors
        ShipSurface = gamemap.ship_surface
        @save mappath TileDict PipeBehaviorDict ShipSurface
        @info "Map saved as  $mappath"
    catch e
        @error "An error occurred while saving map: $e"
    end

    return nothing
end

# ===============================================================
# UI Elements
# ===============================================================

#= ---------- UI Layout Constants ---------- =#

const toolbarheight = 200.0
const propertyboxwidth = 350.0
const hintboxwidth = 350.0
const hintboxheight = 400.0
const statistics_box_width = 300.0

#= ---------- Window Configuration ---------- =#

const DEFAULT_WINDOW_FLAGS = CImGui.ImGuiWindowFlags_NoTitleBar |
    CImGui.ImGuiWindowFlags_NoResize |
    CImGui.ImGuiWindowFlags_NoMove

#= ---------- Mode Configuration ---------- =#

const STANDARD_MODE_CONFIG = (
    (INSPECT, "[1] Inspect"),
    (MOVE, "[2] Move"),
    (PIPE, "[3] Place Pipes"),
    (DELETE, "[4] Delete"),
)
const EDITOR_MODE_CONFIG = (
    STANDARD_MODE_CONFIG...,
    (TILE, "[5] Create Tile"),
    (SURFACE_EDIT, "[6] Edit Surface"),
)

#= ---------- Pipe Type Configuration ---------- =#

const PIPE_TYPES = (
    ("Scrap Pipe", ScrapPipeBehav),
    ("Big Pipe", BigPipeBehav),
)

#= ---------- Helper Functions ---------- =#

# Helper Functions
to_float(nt::NamedTuple) = NamedTuple{keys(nt)}(Float64.(values(nt)))

"Sets up and begins a window with position, size, and flags"
function ui_window_setup(title::String, pos, size, flags)
    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize(size, CImGui.ImGuiCond_Always)
    return CImGui.Begin(title, C_NULL, flags)
end

"Convenience wrapper for ui_window_setup with default flags"
function ui_window(title::String, pos, size; flags = DEFAULT_WINDOW_FLAGS)
    return ui_window_setup(title, pos, size, flags)
end

"""
Generic tunable editor that returns updated tunable values.
Displays input fields for each tunable property and returns the modified values as a tuple.
"""
function edit_tunables!(tunables_tuple)
    tunables = collect(tunables_tuple)
    cfloat_array = similar(tunables, Cfloat)

    for (index, props) in enumerate(tunables)
        CImGui.PushID(index)
        cfloat_array[index] = Cfloat(props.current_val)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.SetNextItemWidth(100.0)
        @c CImGui.InputFloat(props.unit_desc, pointer(cfloat_array, index), 0.0, 100.0, "%.3f")
        CImGui.Separator()
        CImGui.PopID()
    end

    return tuple(cfloat_array...)
end

"""Helper to enqueue a map-override command on the flow calculator command queue."""
function enqueue_map_override!(flowcalc_ipc::FlowCalculatorIPC, gamemap::GameMap)
    cmd = create_map_override_command(flowcalc_ipc.command_queue, deepcopy(gamemap))
    try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
    return nothing
end

"""Read and write a `UInt32` scalar from `inputstate.gui_inputs` using ImGui.
Returns the updated `UInt32` value."""
function gui_input_u32!(inputstate::InputState, key::Symbol, label::String, default::UInt32)
    one::UInt32 = UInt32(1)
    val::UInt32 = haskey(inputstate.gui_inputs, key) ? inputstate.gui_inputs[key] : default
    @cref CImGui.InputScalar(label, CImGui.ImGuiDataType_U32, &val, &one)
    inputstate.gui_inputs[key] = val
    return val
end

"""Read and write an `Int64` scalar from `inputstate.gui_inputs` using ImGui.
Returns the updated `Int64` value."""
function gui_input_s64!(inputstate::InputState, key::Symbol, label::String, default::Int64)
    one::Int64 = Int64(1)
    val::Int64 = haskey(inputstate.gui_inputs, key) ? inputstate.gui_inputs[key] : default
    @cref CImGui.InputScalar(label, CImGui.ImGuiDataType_S64, &val, &one)
    inputstate.gui_inputs[key] = val
    return val
end

"""Read and write a `Float64` double from `inputstate.gui_inputs` using ImGui.
Optional `fmt` controls the displayed format string.
Returns the updated `Float64` value."""
function gui_input_double!(inputstate::InputState, key::Symbol, label::String, default::Float64; step_small::Float64 = 0.01, step_fast::Float64 = 0.1, fmt::String = "%.3f")
    val::Float64 = haskey(inputstate.gui_inputs, key) ? inputstate.gui_inputs[key] : default
    @cref CImGui.InputDouble(label, &val, step_small, step_fast, fmt)
    inputstate.gui_inputs[key] = val
    return val
end

"""Read and write an `Int32` listbox selection from `inputstate.gui_inputs`.
`names` is a Vector{String} shown in the ListBox. Returns updated `Int32` index."""
function gui_listbox_int!(inputstate::InputState, key::Symbol, label::String, names::Vector{String}, default::Int32)
    val::Int32 = haskey(inputstate.gui_inputs, key) ? inputstate.gui_inputs[key] : default
    @cref CImGui.ListBox(label, &val, names)
    inputstate.gui_inputs[key] = val
    return val
end

"Returns mode description text based on current placement mode"
const MODE_DESCRIPTIONS = Dict(
    TILE => "Configuring TILE for placement...",
    PIPE => "Configuring PIPE for placement...",
    INSPECT => "Inspecting hovered part..."
)
mode_description(mode::PlacementModes) = get(MODE_DESCRIPTIONS, mode, "No properties available")

"Returns text description for a tile coordinate"
coord_description(tile::TileCoord) = "($(tile.q), $(tile.r))"

"Returns text description for a vertex coordinate"
function coord_description(vert::VertexCoord)
    direction = if vert.dir == HexFrame.Q_POS
        "Right"
    elseif vert.dir == HexFrame.Q_NEG
        "Left"
    else
        "(ERR: improper vertex)"
    end
    return "$direction node of $(coord_description(vert.tile))"
end

"Format a number with 6 significant figures, using scientific notation if needed"
function format_value(val::Float64)::String
    abs_val = abs(val)

    if abs_val == 0.0
        return "0.00000"
    elseif abs_val >= 1.0e6 || abs_val < 1.0e-3
        # Use scientific notation for very large or very small numbers
        return @sprintf("%.5e", val)
    else
        # Determine decimal places needed for 6 sig figs
        # For values >= 1, we need 6 - floor(log10(abs_val)) - 1 decimal places
        # For values < 1, we need 5 + ceil(abs(log10(abs_val))) decimal places
        if abs_val >= 1.0
            sig_decimals = max(0, 6 - floor(Int, log10(abs_val)) - 1)
            return @sprintf("%.*f", sig_decimals, val)
        else
            sig_decimals = 5 + ceil(Int, abs(log10(abs_val)))
            return @sprintf("%.*f", sig_decimals, val)
        end
    end
end

"Displays component tunables in read-only format matching edit_tunables! style"
function display_component_values!(tunables_tuple::NTuple{N, TunableProps}) where {N}
    if N == 0
        CImGui.Text("No configurable values")
        return nothing
    end

    for (index, props) in enumerate(tunables_tuple)
        CImGui.PushID(index)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.Text("$(format_value(props.current_val)) $(props.unit_desc)")
        CImGui.Separator()

        CImGui.PopID()
    end
    return nothing
end

"Displays circuit element details in the property inspector"
function display_element_details!(elements::Vector{AbsoluteElement}, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    if isempty(elements)
        CImGui.Text("No elements")
        return nothing
    end

    for (index, element) in enumerate(elements)
        CImGui.PushID(index)

        props = get_tunables(element)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.Text("Value: $(format_value(props.current_val)) $(props.unit_desc)")

        current = abs_element_get_current(element, derivedmapstate, mna_state)
        if isnothing(current)
            CImGui.Text("Current: Not Connected")
        else
            CImGui.Text("Current: $(format_value(current)) A")
        end

        CImGui.Separator()
        CImGui.PopID()
    end
    return nothing
end

"Inspects a tile coordinate, displaying component values and element details"
function inspect_ui!(tile::TileCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text("Hex Tile at $(coord_description(tile))")
    internalnode = NodeCoord(tile, HexFrame.NODE_INTERNAL)
    if haskey(mna_state.node_voltages, internalnode)
        CImGui.Text("Internal Node Voltage: $(format_value(mna_state.node_voltages[internalnode])) V")
    end

    if has_tile(gamemap, tile)
        tilecomp = get_tile(gamemap, tile)
        CImGui.Text("Type: $(String(nameof(typeof(tilecomp.component))))")

        # Component Values section
        CImGui.Text("\nValues:")
        CImGui.Separator()
        CImGui.Indent()
        tunables = get_tunables(tilecomp)
        display_component_values!(tunables)
        CImGui.Unindent()

        # Element Details section
        CImGui.Text("\nDerived Elements:")
        CImGui.Separator()
        CImGui.Indent()
        elements = produce_abs_elements(tilecomp, tile)
        display_element_details!(collect(elements), derivedmapstate, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No component on this tile.")
    end

    return nothing
end

"Inspects a vertex coordinate, displaying node voltage and fluid tag"
function inspect_ui!(vert::VertexCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text(coord_description(vert))
    node = to_nodecoord(vert)

    # Exit early if node has no voltage defined
    if !haskey(mna_state.node_voltages, node)
        return nothing
    end

    CImGui.Text("Node Voltage: $(format_value(mna_state.node_voltages[node])) V\n")

    fluidtag = get(derivedmapstate.nodeactualfluids, node, nothing)
    fluidstr = String(Symbol(fluidtag))
    CImGui.Text("Fluid Tag: $(fluidstr)")

    # Display contributing fluid tags from adjacent tiles (only for axis nodes)
    if HexFrame.is_axis(node.dir)
        CImGui.Text("\nContributing Fluid Tags:")
        CImGui.Separator()
        CImGui.Indent()

        contributing_tags = FlowEngine.get_node_fluid_tags(node, gamemap)
        adjacent_tiles_info = HexFrame.get_adjacent_tiles_for_node(node)

        for (idx, ((tile, _), tag)) in enumerate(zip(adjacent_tiles_info, contributing_tags))
            tag_str = String(Symbol(tag))
            CImGui.Text("Tile $(coord_description(tile)): $tag_str")
        end

        CImGui.Unindent()
    end

    return nothing
end

"Inspects an edge coordinate, displaying pipe information"
function inspect_ui!(edge::EdgeCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text("Pipe Between:")
    CImGui.Text("$(coord_description(edge.v1)) and $(coord_description(edge.v2))")

    # Check for pipe behaviors
    if has_pipe(gamemap, edge)
        pipe_behav = get_pipe(gamemap, edge)
        CImGui.Text("Type: $(nameof(typeof(pipe_behav)))")

        # Component Values section
        CImGui.Text("\nComponent Values:")
        CImGui.Separator()
        CImGui.Indent()
        tunables = get_pipe_tunables(pipe_behav)
        display_component_values!(tunables)
        CImGui.Unindent()

        # Element Details section
        CImGui.Text("\nElement Details:")
        CImGui.Separator()
        CImGui.Indent()
        elements = produce_abs_elements(pipe_behav, edge)
        display_element_details!(collect(elements), derivedmapstate, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No pipe at this location.")
    end

    return nothing
end

"Inspects nothing, displaying placeholder text"
inspect_ui!(::Nothing, ::GameMap, ::DerivedMapState, ::MNA_State) = CImGui.Text("Nothing.")

"Prints a seconds counter in the top left of the window, and the thrust readout. Must be called within ui_renderwrap"
function ui_timer_render(ticks::Integer, frames::Integer, UPS::Float64, thrust::SVector{2, Float64}, impulse::SVector{2, Float64})
    ui_window("Statistics", (0.0, 0.0), (statistics_box_width, 100.0))
    CImGui.Text("UPS: $(@sprintf("%.3f", UPS))")
    CImGui.Text("Ticks: $ticks")
    CImGui.Text("Frames: $frames")
    CImGui.Text("Thrust: [$(@sprintf("%.2f", thrust[1])), $(@sprintf("%.2f", thrust[2]))] = $(@sprintf("%.2f", norm(thrust))) U")
    CImGui.Text("Impulse: [$(@sprintf("%.2f", impulse[1] / 1000)), $(@sprintf("%.2f", impulse[2] / 1000))] = $(@sprintf("%.2f", norm(impulse) / 1000)) kU-ticks")

    CImGui.End()
    return nothing
end

"""
Renders the toolbar with mode select and terminal on the bottom of the window.
Can mutate inputstate.placementmode based on input from the radio buttons.
Must be called within ui_renderwrap.
"""
function ui_toolbar_render!(
        inputstate::InputState,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
        threadsafe_console_see::Function
    )
    win_float = to_float(winsize)

    ui_window("Toolbar", (0.0, win_float.height - toolbarheight), (win_float.width, toolbarheight))
    CImGui.Columns(2)

    # Mode Select
    CImGui.SetColumnWidth(0, 150.0)
    CImGui.Text("Modes:")
    modes_config = inputstate.editor_mode ? EDITOR_MODE_CONFIG : STANDARD_MODE_CONFIG
    for (mode, label) in modes_config
        if CImGui.RadioButton(label, inputstate.placementmode === mode)
            inputstate.placementmode = mode
        end
    end

    # Terminal
    CImGui.NextColumn()
    CImGui.Text("TERMINAL:")
    CImGui.BeginChild("TerminalLog", (0.0, 0.0), true)
    for message in threadsafe_console_see()
        CImGui.TextUnformatted(message)
    end
    # Auto-scroll to bottom if already at bottom
    if CImGui.GetScrollY() >= (CImGui.GetScrollMaxY() - 1.0)
        CImGui.SetScrollHereY(1.0)
    end
    CImGui.EndChild()

    CImGui.End()
    return nothing
end

"""
Renders the property box on the right side of the window.
Must be called within ui_renderwrap.
"""
function ui_propertybox_render!(
        inputstate::InputState, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}
    )
    pendcomp = inputstate.pendingcomponent
    win_float = to_float(winsize)

    ui_window("Properties", (win_float.width - propertyboxwidth, 0.0), (propertyboxwidth, win_float.height - toolbarheight))

    # Display mode description
    CImGui.Text("PROPERTIES:")
    CImGui.Text(mode_description(inputstate.placementmode))
    CImGui.Separator()
    CImGui.NewLine()

    # TILE mode: edit component tunables
    if inputstate.placementmode == TILE
        CImGui.Text("Tile Tunable Values:")
        CImGui.Separator()
        CImGui.Indent()
        new_tunables = edit_tunables!(get_tunables(pendcomp))
        inputstate.pendingcomponent = set_tunables(pendcomp, new_tunables)
        CImGui.Unindent()
    end

    # PIPE mode: select pipe type and edit tunables
    if inputstate.placementmode == PIPE
        # Show type selection buttons if in editor mode
        if inputstate.editor_mode
            CImGui.Text("Select Pipe Type:")
            for (label, pipe_type) in PIPE_TYPES
                if CImGui.Button(label)
                    inputstate.pendingpipebehavior = pipe_type()
                    println("Set pending pipe to $(nameof(pipe_type))")
                end
                CImGui.SameLine()
            end
            CImGui.NewLine()
            CImGui.NewLine()
        else
            # Can only place scrap pipes outside editor mode
            inputstate.pendingpipebehavior = ScrapPipeBehav()
        end

        # Show tunables for the selected pipe behavior
        CImGui.Text("Pipe Properties:")
        CImGui.Separator()

        CImGui.Indent()
        new_tunables = edit_tunables!(get_pipe_tunables(inputstate.pendingpipebehavior))
        inputstate.pendingpipebehavior = set_pipe_tunables(inputstate.pendingpipebehavior, new_tunables)
        CImGui.Unindent()
    end

    # INSPECT mode: display info about clicked element
    if inputstate.placementmode == INSPECT
        clicked = get_clicked(inputstate)
        inspect_ui!(clicked, gamemap, derivedmapstate, mna_state)
    end

    CImGui.End()
    return nothing
end

function ui_pause_menu_render!(inputstate::InputState, snapshot::FlowCalculatorSnapshot, window::GLFW.Window)
    # Guard clause to check if escape menu is active
    if !inputstate.escape_menu_active
        return nothing
    end

    # Menu box dimensions
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w, box_h = 300.0, 350.0
    pos = ((win_w - box_w) / 2, (win_h - box_h) / 2)

    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((box_w, box_h), CImGui.ImGuiCond_Always)

    flags = CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove |
        CImGui.ImGuiWindowFlags_NoCollapse

    CImGui.Begin("Escape Menu", C_NULL, flags)

    # Title spacing
    CImGui.Dummy((0.0, 20.0))

    # Calculate button width (fill most of window width with padding)
    button_width = box_w - 40.0
    button_height = 50.0

    # Center buttons horizontally
    CImGui.SetCursorPosX((box_w - button_width) / 2)

    # Close menu button
    if CImGui.Button("Close Menu", (button_width, button_height))
        inputstate.escape_menu_active = false
    end
    CImGui.Dummy((0.0, 10.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)

    # Save map button
    if CImGui.Button("Save Map", (button_width, button_height))
        save_path = save_file(absolute(Path(joinpath(dirname(@__FILE__), "..", "maps"))); filterlist = "jld2")
        if !isnothing(save_path)
            savemap(snapshot.gamemap, "$save_path")
        end
    end
    CImGui.Dummy((0.0, 10.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)

    # Exit to menu button
    if CImGui.Button("Exit to Menu", (button_width, button_height))
        inputstate.return_symbol = :exit_to_startmenu
        inputstate.should_exit_gameloop = true
    end
    CImGui.Dummy((0.0, 20.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)

    # Quit button
    if CImGui.Button("Quit", (button_width, button_height))
        @info "Quitting Game..."
        inputstate.return_symbol = :exit_program
        inputstate.should_exit_gameloop = true
        GLFW.SetWindowShouldClose(window, true)
    end

    CImGui.End()
    return nothing
end

function ui_dev_utils_menu_render!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}})
    # Guard clause to check if dev utils menu is active
    if !inputstate.dev_utils_menu_active
        return nothing
    end

    win_float = to_float(winsize)
    ui_window("Developer Utilities", (win_float.width - propertyboxwidth, 0.0), (propertyboxwidth, win_float.height - toolbarheight))

    button_width = propertyboxwidth - 50.0
    button_height = 20.0

    if (CImGui.CollapsingHeader("Tools"))
        if CImGui.Button("Clear Map", (button_width, button_height))
            @info "Clearing map..."
            new_map = GameMap()
            # Create MapOverrideCommand and enqueue it
            cmd = create_map_override_command(flowcalc_ipc.command_queue, deepcopy(new_map))
            try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
        end
    end

    if (CImGui.CollapsingHeader("Proc Gen"))
            # shared config inputs
            seed = gui_input_u32!(inputstate, :proc_gen_seed, "Random Seed", UInt32(999))

        if (CImGui.TreeNode("Random Walk Surface Gen"))

            # local config inputs
            steps = gui_input_s64!(inputstate, :surface_walk_steps, "Walk Steps", Int64(3))
            stacks = gui_input_s64!(inputstate, :surface_walk_stacks, "Walk stacks", Int64(20))

            # surface creation
            CImGui.Separator()
            if CImGui.Button("Create Surface", (button_width, button_height))
                @info "Creating Surface..."
                new_map = GameMap()
                stacked_random_tile_walk!(new_map.ship_surface, TileCoord(0, 0), steps, stacks, seed)

                enqueue_map_override!(flowcalc_ipc, new_map)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Components"))
            tileset_names = getfield.(ship_gen_tilesets, :name)
            tileset_index = gui_listbox_int!(inputstate, :tileset_index, "Tileset", tileset_names, Int32(0))

            if CImGui.Button("Place Tileset")
                tileset_index_oneindexed = tileset_index + 1
                @info "Placing Components from $(tileset_names[tileset_index_oneindexed])..."
                tilesetmap::GameMap = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                place_shipset!(tilesetmap, ship_gen_tilesets[tileset_index_oneindexed], seed)

                enqueue_map_override!(flowcalc_ipc, tilesetmap)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Big Pipes"))
            # local config inputs
            big_pipe_density = gui_input_double!(inputstate, :big_pipe_density, "Pipe Density", 0.05; step_small = 0.01, step_fast = 0.1, fmt = "%.3f")

            if CImGui.Button("Place Big Pipes", (button_width, button_height))
                @info "Placing Big Pipes..."
                bigpipemap::GameMap = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                place_random_pipes!(bigpipemap, :BigPipe_pipe, seed; pipe_density = big_pipe_density)

                enqueue_map_override!(flowcalc_ipc, bigpipemap)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Scrap Pipes"))
            # local config inputs
            scrap_pipe_density = gui_input_double!(inputstate, :scrap_pipe_density, "Pipe Density", 0.05; step_small = 0.01, step_fast = 0.1, fmt = "%.3f")

            if CImGui.Button("Place Scrap Pipes", (button_width, button_height))
                @info "Placing Scrap Pipes..."
                scrappipemap::GameMap = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                place_random_pipes!(scrappipemap, :ScrapPipe_pipe, seed; pipe_density = scrap_pipe_density)

                enqueue_map_override!(flowcalc_ipc, scrappipemap)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Standard Pipe Combo"))
            if CImGui.Button("Place Pipes", (button_width, button_height))
                standard_pipes = [
                    PipeSpawnOptions(:BigPipe_pipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.05),
                    PipeSpawnOptions(:ScrapPipe_pipe, HexFlowProcGen.RANDOM_PIPES, 0.05),
                ]

                @info "Placing Pipe Combo..."
                combopipemap::GameMap = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                place_pipeset!(combopipemap, standard_pipes, seed)

                enqueue_map_override!(flowcalc_ipc, combopipemap)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Generate Ship"))
            shipconfig_names::Vector{String} = getfield.(ship_gen_configs, :name)

            shipconfig_index = gui_listbox_int!(inputstate, :shipconfig_index, "shipconfig", shipconfig_names, Int32(0))

            if CImGui.Button("Create New Ship", (button_width, button_height))
                shipmap = generate_ship(ship_gen_configs[shipconfig_index + 1], seed)

                enqueue_map_override!(flowcalc_ipc, shipmap)
            end
            CImGui.TreePop()
        end

    end

    CImGui.End()
    return nothing
end

"""
Renders the hint/tutorial popup window.
Displays hints with navigation buttons and completion tracking.
Must be called within ui_renderwrap.
"""
function ui_hintbox_render!(
        hint_data::HintData,
        inputstate::InputState,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}
    )
    # Calculate position (top right, immediately left of property box)
    win_float = to_float(winsize)
    pos_x = win_float.width - propertyboxwidth - hintboxwidth
    pos_y = 0.0

    # Window flags: allow resize and move
    flags = CImGui.ImGuiWindowFlags_None

    # Setup window
    ui_window_setup("Hint: $(hint_data.title)", (pos_x, pos_y), (hintboxwidth, hintboxheight), flags)

    # Get current hint text
    current_hint = hint_data.hints[hint_data.current_hint_index]

    # Scrollable text area (takes remaining space minus button area)
    button_area_height = 80.0  # Space for two rows of buttons plus padding
    text_area_height = hintboxheight - button_area_height - 60.0  # 60 for title bar and padding

    CImGui.BeginChild("HintTextArea", (0.0, text_area_height), true)
    CImGui.PushTextWrapPos(0.0)  # Wrap at window edge
    CImGui.TextUnformatted(current_hint)
    CImGui.PopTextWrapPos()
    CImGui.EndChild()

    CImGui.Spacing()

    # Navigation buttons (Previous and Next, side by side)
    button_width = (hintboxwidth - 30.0) / 2.0  # Account for padding and spacing

    # Previous button
    at_first_hint = hint_data.current_hint_index == 1
    if at_first_hint
        CImGui.BeginDisabled()
    end
    if CImGui.Button("< Previous", (button_width, 30.0))
        hint_data.current_hint_index = max(1, hint_data.current_hint_index - 1)
    end
    if at_first_hint
        CImGui.EndDisabled()
    end

    CImGui.SameLine()

    # Next button
    at_last_hint = hint_data.current_hint_index == length(hint_data.hints)
    if at_last_hint
        CImGui.BeginDisabled()
    end
    if CImGui.Button("Next >", (button_width, 30.0))
        hint_data.current_hint_index = min(length(hint_data.hints), hint_data.current_hint_index + 1)
    end
    if at_last_hint
        CImGui.EndDisabled()
    end

    CImGui.Spacing()

    # Mark Complete button (full width, only enabled at last hint)
    if !at_last_hint
        CImGui.BeginDisabled()
    end
    if CImGui.Button("Mark Complete", (hintboxwidth - 20.0, 30.0))
        @info "Hint Marked completed"
        inputstate.return_symbol = :hint_completed
        inputstate.should_exit_gameloop = true
    end
    if !at_last_hint
        CImGui.EndDisabled()
    end

    CImGui.End()
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
