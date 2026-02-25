# ===============================================================
# UI Menus (Pause menu, Developer Utilities, Hint Box)
# ===============================================================

# Lightweight usings to help editor intellisense
import CImGui
using FilePathsBase, Printf, StaticArrays
using HexFrame, FlowEngine, FlowMap, HexFlowProcGen
using HexFlowCalculator, HexFlowControl

"renders the pause menu when active, with options to close, save map, exit to menu, or quit"
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

"Helper to enqueue a map-override command on the flow calculator command queue."
function enqueue_map_override!(flowcalc_ipc::FlowCalculatorIPC, gamemap::GameMap)
    cmd = create_map_override_command(flowcalc_ipc.command_queue, deepcopy(gamemap))
    try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
    return nothing
end

function ui_dev_utils_menu_render!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, snapshot::FlowCalculatorSnapshot, viewstate::ViewState, winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}, max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing)
    # Guard clause to check if dev utils menu is active
    if !inputstate.dev_utils_menu_active
        return nothing
    end

    win_float = to_float(winsize)
    ui_window("Developer Utilities", (win_float.width - propertyboxwidth, 0.0), (propertyboxwidth, win_float.height - toolbarheight))

    # Debug counters at top of menu
    CImGui.Text("UPS: $(@sprintf("%.3f", @atomic flowcalc_ipc.shared_state.actual_ups))")
    CImGui.Text("Ticks: $(snapshot.gamestate.ticks)")
    CImGui.Text("Frames: $(viewstate.frame_count)")
    CImGui.Separator()

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

        # Initialise Space Map utility
        if CImGui.TreeNode("Initialise Space Map")
            spacemap_seed = gui_input_u32!(inputstate, :spacemap_init_seed, "Seed", UInt32(42))
            init_vel_x = gui_input_double!(inputstate, :spacemap_init_vel_x, "Velocity X", 10.0)
            init_vel_y = gui_input_double!(inputstate, :spacemap_init_vel_y, "Velocity Y", 0.0)

            if CImGui.Button("Initialise Space Map", (button_width, button_height))
                modified_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                initialise_spacemap!(modified_map, spacemap_seed, SVector{2, Float64}(init_vel_x, init_vel_y))
                if modified_map.space_map isa SpaceMapState
                    initialise_encounter_system!(modified_map.space_map)
                end
                enqueue_map_override!(flowcalc_ipc, modified_map)
                @info "Initialised space map with seed=$spacemap_seed, velocity=($init_vel_x, $init_vel_y)"
            end
            CImGui.TreePop()
        end

        # Delete Ship utility
        if CImGui.TreeNode("Delete Ship")
            # Get current gamemap to list ships
            current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
            all_ship_names = get_all_ship_names(current_gamemap)
            
            # Filter out :primary
            deletable_ships = filter(n -> n != :primary, all_ship_names)
            deletable_ship_strings = safe_ship_display_name.(deletable_ships)
            
            if isempty(deletable_ships)
                CImGui.Text("No deletable ships (only primary exists)")
            else
                # Ship selection dropdown
                delete_ship_index = gui_listbox_int!(inputstate, :delete_ship_index, "Ship", deletable_ship_strings, Int32(0))
                delete_ship_index = clamp(delete_ship_index, Int32(0), Int32(max(0, length(deletable_ships) - 1)))
                inputstate.gui_inputs[:delete_ship_index] = delete_ship_index
                
                selected_delete_ship = deletable_ships[delete_ship_index + 1]
                
                if CImGui.Button("Delete Ship", (button_width, button_height))
                    modified_map = deepcopy(current_gamemap)
                    remove_ship!(modified_map, selected_delete_ship)
                    enqueue_map_override!(flowcalc_ipc, modified_map)
                    @info "Deleted ship $(selected_delete_ship)"
                end
            end
            CImGui.TreePop()
        end

        # Depart Ship utility
        if CImGui.TreeNode("Depart Ship")
            # Get current gamemap to list ships
            current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
            all_ship_names = get_all_ship_names(current_gamemap)
            
            # Filter out :primary
            departable_ships = filter(n -> n != :primary, all_ship_names)
            departable_ship_strings = safe_ship_display_name.(departable_ships)
            
            if isempty(departable_ships)
                CImGui.Text("No departable ships (only primary exists)")
            else
                # Ship selection dropdown
                depart_ship_index = gui_listbox_int!(inputstate, :depart_ship_index, "Ship", departable_ship_strings, Int32(0))
                depart_ship_index = clamp(depart_ship_index, Int32(0), Int32(max(0, length(departable_ships) - 1)))
                inputstate.gui_inputs[:depart_ship_index] = depart_ship_index
                
                selected_depart_ship = departable_ships[depart_ship_index + 1]
                
                if CImGui.Button("Depart Ship", (button_width, button_height))
                    modified_map = deepcopy(current_gamemap)

                    success, reason = depart_ship!(modified_map, selected_depart_ship; max_view_bounds=max_view_bounds)
                    if success
                        enqueue_map_override!(flowcalc_ipc, modified_map)
                        flowcalc_ipc.console_push(reason)
                        @info reason
                    else
                        flowcalc_ipc.console_push(reason)
                    end
                end
            end
            CImGui.TreePop()
        end

        # Swap Primary utility
        if CImGui.TreeNode("Swap Primary")
            current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
            all_ship_names = get_all_ship_names(current_gamemap)

            swappable_ships = filter(n -> n != :primary, all_ship_names)
            swappable_ship_strings = safe_ship_display_name.(swappable_ships)

            if isempty(swappable_ships)
                CImGui.Text("No other ships to swap with")
            else
                swap_ship_index = gui_listbox_int!(inputstate, :swap_primary_index, "Ship", swappable_ship_strings, Int32(0))
                swap_ship_index = clamp(swap_ship_index, Int32(0), Int32(max(0, length(swappable_ships) - 1)))
                inputstate.gui_inputs[:swap_primary_index] = swap_ship_index

                selected_swap_ship = swappable_ships[swap_ship_index + 1]

                if CImGui.Button("Swap Primary", (button_width, button_height))
                    modified_map = deepcopy(current_gamemap)

                    success, reason = swap_primary!(modified_map, selected_swap_ship)
                    if success
                        enqueue_map_override!(flowcalc_ipc, modified_map)
                        flowcalc_ipc.console_push(reason)
                        @info reason
                    else
                        flowcalc_ipc.console_push(reason)
                    end
                end
            end
            CImGui.TreePop()
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
                # Generate tiles into a temporary set and assign to the primary ship
                tiles = Set{TileCoord}()
                stacked_random_tile_walk!(tiles, TileCoord(0, 0), steps, stacks, seed)
                set_surface_tile!(new_map, tiles)

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

            shipconfig_names = getfield.(ship_gen_configs, :name)
            shipconfig_index = gui_listbox_int!(inputstate, :shipconfig_index, "shipconfig", shipconfig_names, Int32(0))

            if CImGui.Button("Create New Ship", (button_width, button_height))
                ship = generate_ship(ship_gen_configs[shipconfig_index + 1], seed)

                enqueue_map_override!(flowcalc_ipc, GameMap(ship))
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Encounter Ship"))

            shipconfig_names = getfield.(ship_gen_configs, :name)
            shipconfig_index = gui_listbox_int!(inputstate, :shipconfig_index, "shipconfig", shipconfig_names, Int32(0))

            hexaxis_names = collect(string.(instances(HexAxis)))
            hexaxis_index = gui_listbox_int!(inputstate, :hexaxis_index, "hexaxis", hexaxis_names, Int32(0))

            if CImGui.Button("Encounter New Ship", (button_width, button_height))
                encounter_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                encounter_ship!(encounter_map, ship_gen_configs[shipconfig_index + 1], seed, instances(HexAxis)[hexaxis_index + 1]; max_view_bounds=max_view_bounds)

                enqueue_map_override!(flowcalc_ipc, encounter_map)
            end
            CImGui.TreePop()
        end

    end

    if CImGui.CollapsingHeader("Rendering")
        button_width = 200.0
        button_height = 30.0

        if CImGui.TreeNode("Docking Status")
            current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap

            for (ship_name, ship) in current_gamemap.ships
                status = get_docking_status(ship)
                offset = get_render_offset(ship)
                status_str = string(typeof(status).name.name)
                axis = get_approach_axis(status)
                axis_str = isnothing(axis) ? "none" : string(axis)
                CImGui.Text("$(safe_ship_display_name(ship_name)): $(status_str) @ ($(round(offset.q, digits=2)), $(round(offset.r, digits=2))) axis=$(axis_str)")
            end

            if CImGui.Button("Clear All to Connected", (button_width, button_height))
                modified_map = deepcopy(current_gamemap)
                clear_all_docking_statuses!(modified_map)
                enqueue_map_override!(flowcalc_ipc, modified_map)
                @info "Cleared all docking statuses to Connected"
            end

            CImGui.TreePop()
        end
    end

    CImGui.End()
    return nothing
end

# ===============================================================
# Confirmation Popup
# ===============================================================

"""
Renders a world-anchored confirmation popup window.
The window tracks its `world_position` through panning and zooming,
has a close (X) button, and a confirm button that executes the stored action.
Must be called within ui_renderwrap.
"""
function ui_confirmation_popup_render!(inputstate::InputState, viewstate::ViewState)
    popup = inputstate.active_popup
    popup === nothing && return nothing

    # Convert world-space anchor to screen-space window coordinates
    screen_x, screen_y = world_to_screen(popup.world_position.x, popup.world_position.y, viewstate)

    popup_width = 220.0
    popup_height = 110.0

    CImGui.SetNextWindowPos((screen_x, screen_y), CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((popup_width, popup_height), CImGui.ImGuiCond_Always)

    flags = CImGui.ImGuiWindowFlags_NoResize |
            CImGui.ImGuiWindowFlags_NoCollapse

    p_open = Ref(true)
    CImGui.Begin("Confirm##popup", p_open, flags)

    CImGui.TextWrapped(popup.message)
    CImGui.Dummy((0.0, 4.0))

    button_width = popup_width - 16.0 # window padding
    CImGui.SetCursorPosX((popup_width - button_width) / 2.0)
    if CImGui.Button("Confirm?", (button_width, 28.0))
        popup.action()
        inputstate.active_popup = nothing
    end

    CImGui.End()

    # Handle close (X) button
    if !p_open[]
        inputstate.active_popup = nothing
    end

    return nothing
end