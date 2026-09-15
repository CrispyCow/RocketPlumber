# ===============================================================
# UI Menus (Pause menu, Developer Utilities, Hint Box)
# ===============================================================

# Lightweight usings to help editor intellisense
import CImGui
using FilePathsBase, LinearAlgebra, Printf, StaticArrays
using HexFrame, FlowEngine, FlowMap, HexFlowProcGen
using HexFluids
using HexFlowCalculator, HexFlowControl
using HexComponentsAPI

# Fluid property editor UI state
const _density_editor_state = Dict{Symbol, Any}(
    :selected_index => Int32(0),
    :input_value => 0.0,
    :last_selected_fluid => nothing,
)

const _exhaust_vel_editor_state = Dict{Symbol, Any}(
    :selected_index => Int32(0),
    :input_value => 0.0,
    :last_selected_fluid => nothing,
)

# Mass tunables editor UI state
const _component_mass_editor_state = Dict{Symbol, Any}(:input_value => 0.0)
const _tile_mass_editor_state = Dict{Symbol, Any}(:input_value => 0.0)
const _particle_accel_editor_state = Dict{Symbol, Any}(:input_value => 0.0)

"Render the pause menu when active, including escape recovery when a departure checkpoint exists."
function ui_pause_menu_render!(inputstate::InputState, timelapse_recorder::TimelapseRecorder,
        snapshot::FlowCalculatorSnapshot, window::GLFW.Window,
        learning_state::Union{Nothing, LearningSystemState} = nothing; session_timing::PlaySessionTiming)
    # Menu must be active
    if !inputstate.escape_menu_active
        return nothing
    end

    is_sandbox = !isnothing(learning_state) && is_sandbox_learning(learning_state)
    escape_active = is_galaxy_escape_active(snapshot.gamemap)

    # Centre the menu box
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w, box_h = 300.0, escape_active ? 420.0 : 350.0
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

    # Save map button (hidden in sandbox mode)
    if !is_sandbox
        save_label = escape_active ? "Save Escape Attempt" : "Save Map"
        if CImGui.Button(save_label, (button_width, button_height))
            save_path = save_file(absolute(Path(joinpath(dirname(@__FILE__), "..", "maps"))); filterlist = "jld2")
            if !isnothing(save_path)
                save_current_map(timelapse_recorder, snapshot, session_timing, learning_state, "$save_path")
            end
        end
        CImGui.Dummy((0.0, 10.0))
        CImGui.SetCursorPosX((box_w - button_width) / 2)
    end

    if escape_active
        abort_available = can_abort_galaxy_escape(snapshot.gamemap)
        !abort_available && CImGui.BeginDisabled()
        if CImGui.Button("Abort Escape Attempt and Restore Backup", (button_width, button_height))
            inputstate.exit_reason = EXIT_RESTART
            inputstate.escape_menu_active = false
        end
        !abort_available && CImGui.EndDisabled()
        if CImGui.IsItemHovered(CImGui.ImGuiHoveredFlags_AllowWhenDisabled)
            tooltip = abort_available ?
                "Restore the ship and galaxy to their pre-departure state." :
                "This development save does not contain a recoverable pre-departure map."
            CImGui.SetTooltip(tooltip)
        end
        CImGui.Dummy((0.0, 10.0))
        CImGui.SetCursorPosX((box_w - button_width) / 2)
    end

    # Exit to menu button
    exit_label = is_sandbox ? "Leave Tutorial" : "Exit to Menu"
    if CImGui.Button(exit_label, (button_width, button_height))
        inputstate.exit_reason = EXIT_MENU
    end
    CImGui.Dummy((0.0, 20.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)

    # Quit button
    if CImGui.Button("Quit", (button_width, button_height))
        @info "Quitting Game..."
        inputstate.exit_reason = EXIT_QUIT
        GLFW.SetWindowShouldClose(window, true)
    end

    CImGui.End()
    return nothing
end

"Enqueue a `MapOverrideCommand` on the flow calculator's command queue."
function enqueue_map_override!(flowcalc_ipc::FlowCalculatorIPC, gamemap::GameMap)
    cmd = create_map_override_command(flowcalc_ipc.command_queue, deepcopy(gamemap))
    try_enqueue_command!(flowcalc_ipc.command_queue, cmd)
    return nothing
end

"""
Show a listbox of ships and return `(selected_name, gamemap)`, or
`(nothing, gamemap)` when no ships are available (with a placeholder message).
Set `exclude_primary=false` to include the primary ship in the list.
"""
function _ship_selector_ui!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, key::Symbol, label::String, empty_msg::String = "No other ships (only primary exists)"; exclude_primary::Bool = true)
    current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
    all_ship_names = get_all_ship_names(current_gamemap)
    selectable_ships = exclude_primary ? filter(n -> n != :primary, all_ship_names) : all_ship_names
    display_names = safe_ship_display_name.(selectable_ships)

    if isempty(selectable_ships)
        CImGui.Text(empty_msg)
        return nothing, current_gamemap
    end

    idx = gui_listbox_int!(inputstate, key, label, display_names, Int32(0))
    return selectable_ships[idx + 1], current_gamemap
end

"Return deterministic fuel-tag options for an encounter class."
function _encounter_fuel_options(class_config::EncounterClassConfig)
    source = class_config.component_source
    if source isa DirectEncounterComponents
        return (
            ["No fuel classification"],
            Union{HexFluids.FluidType, Nothing}[nothing],
        )
    end

    fluid_source = source::FluidTaggedEncounterComponents
    sorted_tags = sort!(collect(keys(fluid_source.fuel_configs)))
    return (
        string.(sorted_tags),
        Union{HexFluids.FluidType, Nothing}[sorted_tags...],
    )
end

"Return all encounter-set options for the selected fuel tag, including currently locked ones."
function _encounter_set_options(
        class_config::EncounterClassConfig,
        fuel_tag::Union{HexFluids.FluidType, Nothing},
        richness::Float64,
    )
    raw_pool = resolve_encounter_component_pool(class_config.component_source, fuel_tag)
    return [
        (wcs.component_set, evaluate_scaling(wcs.weight, richness)) for wcs in raw_pool
    ]
end

function ui_dev_utils_menu_render!(
        inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, timelapse_recorder::TimelapseRecorder,
        snapshot::FlowCalculatorSnapshot,
        viewstate::ViewState, winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
        max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing;
        session_timing::PlaySessionTiming)
    # Menu must be active
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

    if CImGui.CollapsingHeader("Playthrough Statistics")
        gamemap = snapshot.gamemap
        game_time = get_time_years(gamemap)
        game_time_text = isnothing(game_time) ? "N/A" : "$(format_value(game_time)) years"
        CImGui.Text("Game time: $game_time_text")
        CImGui.Text("Play time: $(format_value(get_current_play_time_seconds(session_timing) / 60.0)) minutes")
        CImGui.Text("Simulated time: $(format_value(get_simulated_seconds(gamemap))) seconds ($(get_simulated_ticks(gamemap)) ticks)")
        CImGui.Text("Current speed: $(format_value(norm(get_velocity(gamemap))))")
        CImGui.Text("Total delta-V: $(format_value(get_total_delta_v(gamemap)))")
        CImGui.Text("Peak thrust: $(format_value(get_peak_thrust(gamemap)))")
        CImGui.Text("Completed encounters: $(get_total_encounter_count(gamemap))")
        CImGui.Indent()
        for encounter_class in instances(EncounterClass)
            CImGui.Text("$(encounter_class_label(encounter_class)): $(get_encounter_count(gamemap, encounter_class))")
        end
        CImGui.Unindent()
    end

    if CImGui.CollapsingHeader("Time Lapse")
        if is_sandbox_learning(snapshot.gamemap)
            CImGui.TextWrapped("Parent-map time-lapse recording is suspended during tutorials.")
        else
            CImGui.Text("Frames: $(timelapse_frame_count(timelapse_recorder))")
            recording_enabled = timelapse_recorder.enabled
            @cref CImGui.Checkbox("Record Time Lapse", &recording_enabled)
            if recording_enabled != timelapse_recorder.enabled
                set_timelapse_enabled!(timelapse_recorder, recording_enabled)
            end
            recording_enabled && CImGui.TextWrapped("Capturing every $(Int(TIMELAPSE_CAPTURE_INTERVAL_SECONDS)) seconds.")
        end
    end

    button_width = propertyboxwidth - 50.0
    button_height = 20.0

    if CImGui.CollapsingHeader("Editor")
        editor_state = placement_state(inputstate)
        editor_state_label = if editor_state isa PlacementReadyState
            "Standard"
        elseif editor_state isa PlacementPressedState
            "Move Pending"
        elseif editor_state isa PlacementMoveState
            "Move"
        elseif editor_state isa PlacementMovePendingState
            "Applying Move"
        elseif editor_state isa PlacementPipeChainState
            "Pipe Chain"
        elseif editor_state isa PlacementTileState
            "Tile Placement"
        elseif editor_state isa PlacementDeleteState
            "Delete"
        elseif editor_state isa PlacementSurfaceEditState
            "Surface Edit"
        elseif editor_state isa PlacementRedockState
            "Redock"
        else
            "Unknown"
        end
        CImGui.Text("State: $(editor_state_label)")

        editor_enabled = inputstate.editor_mode
        @cref CImGui.Checkbox("Editor Mode", &editor_enabled)
        if editor_enabled != inputstate.editor_mode
            inputstate.editor_mode = editor_enabled
            if !editor_enabled
                state = placement_state(inputstate)
                if state isa AbstractEditorPlacementState
                    enter_ready_placement_state!(inputstate)
                elseif state isa PlacementPipeChainState
                    state.pipe_behavior = ScrapPipeBehav()
                end
            end
        end

        !inputstate.editor_mode && CImGui.BeginDisabled()
        if CImGui.RadioButton("[4] Delete", placement_state(inputstate) isa PlacementDeleteState)
            toggle_editor_placement_state!(inputstate, PlacementDeleteState())
        end
        if CImGui.RadioButton("[5] Tile Placement", placement_state(inputstate) isa PlacementTileState)
            toggle_tile_placement_state!(inputstate)
        end
        if CImGui.RadioButton("[6] Surface Edit", placement_state(inputstate) isa PlacementSurfaceEditState)
            toggle_editor_placement_state!(inputstate, PlacementSurfaceEditState())
        end
        !inputstate.editor_mode && CImGui.EndDisabled()
    end

    if (CImGui.CollapsingHeader("Tools"))
        if CImGui.Button("Clear Map", (button_width, button_height))
            @info "Clearing map..."
            enqueue_map_override!(flowcalc_ipc, GameMap())
        end

        # Modify Space Map
        if CImGui.TreeNode("Modify Space Map")
            current_velocity = get_velocity(snapshot.gamemap)
            CImGui.Text(@sprintf("Current velocity: (%.3f, %.3f)", current_velocity...))

            delta_vel_x = gui_input_double!(inputstate, :spacemap_delta_vel_x, "Velocity Delta X", 2500.0)
            delta_vel_y = gui_input_double!(inputstate, :spacemap_delta_vel_y, "Velocity Delta Y", 0.0)
            velocity_delta = SVector{2, Float64}(delta_vel_x, delta_vel_y)
            new_velocity = current_velocity + velocity_delta
            invalid_velocity = !all(isfinite, velocity_delta) || !all(isfinite, new_velocity)

            if button_with_disable(
                    "Add Velocity", ImVec2(button_width, button_height), invalid_velocity;
                    tooltip = "Velocity and resulting velocity must be finite.",
                )
                modified_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                adjusted_velocity = get_velocity(modified_map) + velocity_delta
                if all(isfinite, adjusted_velocity)
                    set_velocity!(modified_map, adjusted_velocity)
                    enqueue_map_override!(flowcalc_ipc, modified_map)
                    @info "Added velocity ($delta_vel_x, $delta_vel_y); new velocity=($adjusted_velocity)"
                else
                    @warn "Could not add velocity because the resulting velocity is not finite" velocity_delta
                end
            end

            has_encounter_system = snapshot.gamemap.space_map isa SpaceMapState
            if button_with_disable(
                "Apply Loaded Encounter Config", ImVec2(button_width, button_height), !has_encounter_system;
                    tooltip = "Requires an active encounter space map. Existing encounters are preserved.",
                )
                modified_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                space_map = get_spacemap(modified_map)
                if space_map isa SpaceMapState
                    replace_encounter_config!(space_map, encounter_system_config)
                    enqueue_map_override!(flowcalc_ipc, modified_map)
                    @info "Applied encounter system config loaded from components.jl"
                else
                    @info "Encounter config reload skipped because the space map changed"
                end
            end

            CImGui.TreePop()
        end

        # Overwrite Space Map
        if CImGui.TreeNode("Overwrite Space Map")
            spacemap_seed = gui_input_u32!(inputstate, :spacemap_init_seed, "Seed", UInt32(42))
            init_vel_x = gui_input_double!(inputstate, :spacemap_init_vel_x, "Initial Velocity X", 10.0)
            init_vel_y = gui_input_double!(inputstate, :spacemap_init_vel_y, "Initial Velocity Y", 0.0)

            if CImGui.Button("Initialise Space Map", (button_width, button_height))
                modified_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                initialise_spacemap!(modified_map, spacemap_seed, encounter_system_config, SVector{2, Float64}(init_vel_x, init_vel_y))
                if modified_map.space_map isa SpaceMapState
                    initialise_encounter_system!(modified_map.space_map)
                end
                enqueue_map_override!(flowcalc_ipc, modified_map)
                @info "Initialised space map with seed=$spacemap_seed, velocity=($init_vel_x, $init_vel_y)"
            end

            has_space_map = !(snapshot.gamemap.space_map isa SpaceMapEmpty)
            if button_with_disable("Delete Space Map", ImVec2(button_width, button_height), !has_space_map; tooltip = "Loaded map has no space map.")
                modified_map = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                modified_map.space_map = SpaceMapEmpty()
                enqueue_map_override!(flowcalc_ipc, modified_map)
                @info "Deleted space map"
            end

            CImGui.TreePop()
        end

        # Delete Ship
        if CImGui.TreeNode("Delete Ship")
            selected, current_gamemap = _ship_selector_ui!(inputstate, flowcalc_ipc, :delete_ship_index, "Ship", "No deletable ships (only primary exists)")
            if !isnothing(selected) && CImGui.Button("Delete Ship", (button_width, button_height))
                modified_map = deepcopy(current_gamemap)
                remove_ship!(modified_map, selected)
                enqueue_map_override!(flowcalc_ipc, modified_map)
                @info "Deleted ship $(selected)"
            end
            CImGui.TreePop()
        end

        # Depart Ship
        if CImGui.TreeNode("Depart Ship")
            selected, current_gamemap = _ship_selector_ui!(inputstate, flowcalc_ipc, :depart_ship_index, "Ship", "No departable ships (only primary exists)")
            if !isnothing(selected) && CImGui.Button("Depart Ship", (button_width, button_height))
                modified_map = deepcopy(current_gamemap)
                success, reason = depart_ship!(modified_map, selected; max_view_bounds = max_view_bounds)
                if success
                    enqueue_map_override!(flowcalc_ipc, modified_map)
                    @info reason
                else
                    @warn "Developer ship departure failed" ship_name = selected reason = reason
                end
            end
            CImGui.TreePop()
        end

        # Swap Primary
        if CImGui.TreeNode("Swap Primary")
            selected, current_gamemap = _ship_selector_ui!(inputstate, flowcalc_ipc, :swap_primary_index, "Ship", "No other ships to swap with")
            if !isnothing(selected) && CImGui.Button("Swap Primary", (button_width, button_height))
                modified_map = deepcopy(current_gamemap)
                success, reason = swap_primary!(modified_map, selected)
                if success
                    enqueue_map_override!(flowcalc_ipc, modified_map)
                    @info reason
                else
                    @warn "Developer primary swap failed" ship_name = selected reason = reason
                end
            end
            CImGui.TreePop()
        end

        # Export Ship
        if CImGui.TreeNode("Export Ship")
            selected, current_gamemap = _ship_selector_ui!(inputstate, flowcalc_ipc, :export_ship_index, "Ship", "No ships available"; exclude_primary = false)
            if !isnothing(selected) && CImGui.Button("Save Ship...", (button_width, button_height))
                save_path = save_file(absolute(Path(joinpath(dirname(@__FILE__), "..", "maps"))); filterlist = "jld2")
                if !isnothing(save_path)
                    blueprint = get_ship_blueprint(current_gamemap, selected)
                    centroid = get_surface_centroid(current_gamemap, selected)
                    if !isnothing(centroid)
                        offset_ship!(blueprint, TileCoord(-round_to_tile(centroid)))
                    end
                    new_gm = GameMap(blueprint)
                    savemap(new_gm, "$save_path")
                    @info "Exported ship :$(selected) to $(save_path)"
                end
            end
            CImGui.TreePop()
        end
    end


    if CImGui.CollapsingHeader("Parameter Tuning")
        if CImGui.TreeNode("Edit Fluid Densities")
            densities = get_fluid_densities()
            fluid_keys = sort(collect(keys(densities)); by = UInt32)

            if isempty(fluid_keys)
                CImGui.Text("No fluid densities configured")
            else
                labels = [something(fluid_type_label(k), string(k)) for k in fluid_keys]

                selected_idx = gui_listbox_int!(_density_editor_state, :selected_index, "##density_fluid", labels, Int32(0))
                selected_idx = clamp(selected_idx, Int32(0), Int32(length(fluid_keys) - 1))
                _density_editor_state[:selected_index] = selected_idx

                selected_fluid = fluid_keys[Int(selected_idx) + 1]
                current_val = densities[selected_fluid]

                if get(_density_editor_state, :last_selected_fluid, nothing) != selected_fluid
                    _density_editor_state[:input_value] = current_val
                    _density_editor_state[:last_selected_fluid] = selected_fluid
                end

                CImGui.Text("Current: $(format_value(current_val))")
                input_val = gui_input_double!(_density_editor_state, :input_value, "##density_input", current_val; step_small = 0.01, step_fast = 0.1, fmt = "%.3f")

                if CImGui.Button("Apply##density", ImVec2(-1, 0))
                    set_fluid_density!(selected_fluid, input_val)
                end
            end

            CImGui.TreePop()
        end

        if CImGui.TreeNode("Edit Fluid Exhaust Velocities")
            velocities = get_fluid_exhaust_velocities()
            fluid_keys = sort(collect(keys(velocities)); by = UInt32)

            if isempty(fluid_keys)
                CImGui.Text("No fluid exhaust velocities configured")
            else
                labels = [something(fluid_type_label(k), string(k)) for k in fluid_keys]

                selected_idx = gui_listbox_int!(_exhaust_vel_editor_state, :selected_index, "##exhaust_fluid", labels, Int32(0))
                selected_idx = clamp(selected_idx, Int32(0), Int32(length(fluid_keys) - 1))
                _exhaust_vel_editor_state[:selected_index] = selected_idx

                selected_fluid = fluid_keys[Int(selected_idx) + 1]
                current_val = velocities[selected_fluid]

                if get(_exhaust_vel_editor_state, :last_selected_fluid, nothing) != selected_fluid
                    _exhaust_vel_editor_state[:input_value] = current_val
                    _exhaust_vel_editor_state[:last_selected_fluid] = selected_fluid
                end

                CImGui.Text("Current: $(format_value(current_val))")
                input_val = gui_input_double!(_exhaust_vel_editor_state, :input_value, "##exhaust_input", current_val; step_small = 1.0, step_fast = 10.0, fmt = "%.3f")

                if CImGui.Button("Apply##exhaust", ImVec2(-1, 0))
                    set_fluid_exhaust_velocity!(selected_fluid, input_val)
                end
            end

            CImGui.TreePop()
        end

        if CImGui.TreeNode("Default Component Mass")
            current_val = get_default_component_mass()
            CImGui.Text("Current: $(format_value(current_val))")
            input_val = gui_input_double!(_component_mass_editor_state, :input_value, "##comp_mass_input", current_val; step_small = 1.0, step_fast = 10.0, fmt = "%.1f")
            if CImGui.Button("Apply##comp_mass", ImVec2(-1, 0))
                set_default_component_mass!(Float64(input_val))
            end
            CImGui.TreePop()
        end

        if CImGui.TreeNode("Tile Mass")
            current_val = get_tile_mass()
            CImGui.Text("Current: $(format_value(current_val))")
            input_val = gui_input_double!(_tile_mass_editor_state, :input_value, "##tile_mass_input", current_val; step_small = 1.0, step_fast = 10.0, fmt = "%.1f")
            if CImGui.Button("Apply##tile_mass", ImVec2(-1, 0))
                set_tile_mass!(Float64(input_val))
            end
            CImGui.TreePop()
        end

        if CImGui.TreeNode("Particle Acceleration Scale")
            current_val = get_particle_accel_scale()
            CImGui.Text("Current: $(format_value(current_val))")
            input_val = gui_input_double!(_particle_accel_editor_state, :input_value, "##particle_accel_input", current_val; step_small = 0.0001, step_fast = 0.001, fmt = "%.6f")
            if CImGui.Button("Apply##particle_accel", ImVec2(-1, 0))
                set_particle_accel_scale!(Float64(input_val))
            end
            CImGui.TreePop()
        end
    end


    if (CImGui.CollapsingHeader("Proc Gen"))
        seed = gui_input_u32!(inputstate, :proc_gen_seed, "Random Seed", UInt32(999))

        if (CImGui.TreeNode("Random Walk Surface Gen"))

            steps = gui_input_s64!(inputstate, :surface_walk_steps, "Walk Steps", Int64(3))
            stacks = gui_input_s64!(inputstate, :surface_walk_stacks, "Walk stacks", Int64(20))

            CImGui.Separator()
            if CImGui.Button("Create Surface", (button_width, button_height))
                @info "Creating Surface..."
                new_map = GameMap()
                tiles = Set{TileCoord}()
                stacked_random_tile_walk!(tiles, TileCoord(0, 0), steps, stacks, seed)
                set_surface_tile!(new_map, tiles)
                enqueue_map_override!(flowcalc_ipc, new_map)
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Components"))
            all_component_sets = ShipComponentSet[
                shipset_starter,
                shipset_simple_cold_gas,
                shipset_pressure_fed_monoprop,
                compset_gas_cache,
                compset_liquid_cache,
                compset_extra_gas_tanks,
                compset_extra_liquid_tanks,
            ]
            names = [s.name for s in all_component_sets]
            tileset_selection = get!(inputstate.gui_inputs, :tileset_selection, Cint(0))::Cint
            _, tileset_selection = CImGui.ListBox("##tilesets", tileset_selection, names, length(names), 4)
            inputstate.gui_inputs[:tileset_selection] = tileset_selection

            if CImGui.Button("Place Tileset")
                selected_set = all_component_sets[tileset_selection + 1]
                tilesetmap::GameMap = deepcopy((flowcalc_ipc.get_snapshot()).gamemap)
                success, msg = place_shipset!(tilesetmap, selected_set, seed)

                enqueue_map_override!(flowcalc_ipc, tilesetmap)
                @info "Placed tileset" name = selected_set.name success msg
            end
            CImGui.TreePop()
        end

        if (CImGui.TreeNode("Place Big Pipes"))
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

        if (CImGui.TreeNode("Generate Encounter"))
            class_names = ["Jumbled Ship", "Fuel Cache", "Scrap Clump"]
            class_enums = [ENCOUNTER_SHIP, ENCOUNTER_FUEL_CACHE, ENCOUNTER_SCRAP]
            class_sel = gui_listbox_int!(inputstate, :enc_class_sel, "Class", class_names, Cint(0))

            enc_class = class_enums[class_sel + 1]
            class_config = encounter_system_config.encounter_class_configs[enc_class]

            fuel_names, fuel_enums = _encounter_fuel_options(class_config)
            fuel_sel = gui_listbox_int!(inputstate, :enc_fuel_sel, "Fuel Tag", fuel_names, Cint(0))

            richness_val = gui_input_double!(
                inputstate, :enc_richness, "Richness", 1.0;
                step_small = 0.5, step_fast = 1.0, fmt = "%.2f"
            )
            richness_val = max(richness_val, 0.0)
            inputstate.gui_inputs[:enc_richness] = richness_val

            seed_val = gui_input_s64!(inputstate, :enc_seed, "Seed", Int64(42))
            inputstate.gui_inputs[:enc_seed] = seed_val

            dir_names = ["Q+", "R-", "S+", "Q-", "R+", "S-"]
            dir_sel = gui_listbox_int!(inputstate, :enc_dir_sel, "Direction", dir_names, Cint(3))

            enc_fuel = fuel_enums[fuel_sel + 1]
            enc_richness = Float64(richness_val)
            enc_seed = UInt32(abs(seed_val))
            enc_dir = HexFrame.HexAxis(dir_sel)

            steps, stacks = compute_hull_size(class_config.hull_size, enc_richness)
            target = compute_target_components(class_config.target_components, enc_richness)
            CImGui.Text(@sprintf("Hull: %d steps, %d stacks", steps, stacks))
            CImGui.Text(@sprintf("Target components: %d", target))

            encounter_set_options = _encounter_set_options(class_config, enc_fuel, enc_richness)
            CImGui.SeparatorText("Encounter Set Options")
            if isempty(encounter_set_options)
                if class_config.component_source isa DirectEncounterComponents
                    CImGui.TextWrapped("No component sets are registered for this direct encounter class.")
                else
                    CImGui.TextWrapped("No encounter sets are registered for the selected fuel tag.")
                end
            else
                for (shipset, weight) in encounter_set_options
                    if weight > 0.0
                        CImGui.TextWrapped(@sprintf("%s (weight %.2f)", shipset.name, weight))
                    else
                        CImGui.TextWrapped("$(shipset.name) (locked at current richness)")
                    end
                end
            end

            if CImGui.Button("Generate & Dock", ImVec2(-1, 30))
                encounter_blueprint = generate_encounter(
                    enc_class, enc_fuel, enc_richness,
                    enc_seed, class_config
                )
                display_name = generate_encounter_name(enc_seed, enc_class)
                cmd = create_add_encounter_ship_command(
                    flowcalc_ipc.command_queue, encounter_blueprint, display_name, enc_seed;
                    dir = enc_dir, max_view_bounds = max_view_bounds
                )
                try_enqueue_command!(flowcalc_ipc.command_queue, cmd)
                @info "Dev: generated encounter" name = display_name class = enc_class richness = enc_richness
            end

            if CImGui.Button("Generate & Dock (Optimal)", ImVec2(-1, 30))
                encounter_blueprint = generate_encounter(
                    enc_class, enc_fuel, enc_richness,
                    enc_seed, class_config
                )
                display_name = generate_encounter_name(enc_seed, enc_class)
                cmd = create_add_encounter_ship_command(
                    flowcalc_ipc.command_queue, encounter_blueprint, display_name, enc_seed;
                    dir = nothing,
                    target_encounter_index = nothing,
                    max_view_bounds = max_view_bounds
                )
                try_enqueue_command!(flowcalc_ipc.command_queue, cmd)
                @info "Dev: generated encounter (optimal dir)" name = display_name class = enc_class richness = enc_richness
            end

            if CImGui.Button("Generate (No Dock)", ImVec2(-1, 30))
                blueprint = generate_encounter(
                    enc_class, enc_fuel, enc_richness,
                    enc_seed, class_config
                )
                new_gamemap = GameMap(blueprint)
                enqueue_map_override!(flowcalc_ipc, new_gamemap)
                @info "Dev: generated standalone encounter" class = enc_class richness = enc_richness
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
                CImGui.Text("$(safe_ship_display_name(ship_name)): $(status_str) @ ($(round(offset.q, digits = 2)), $(round(offset.r, digits = 2)))")
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
# Action Popup
# ===============================================================

"Render the world-anchored action popup. Handles both action list and confirmation sub-pane."
function ui_action_popup_render!(inputstate::InputState, viewstate::ViewState, flowcalc_ipc::FlowCalculatorIPC)
    popup = inputstate.action_popup
    popup === nothing && return nothing

    screen_x, screen_y = world_to_screen(popup.world_position.x, popup.world_position.y, viewstate)

    popup_width = 240.0
    flags = CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoCollapse |
        CImGui.ImGuiWindowFlags_AlwaysAutoResize

    CImGui.SetNextWindowPos((screen_x, screen_y), CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSizeConstraints((popup_width, 0.0), (popup_width, 400.0))

    p_open = Ref(true)
    CImGui.Begin("$(popup.window_title)##action_popup", p_open, flags)

    if !isnothing(popup.pending_confirmation)
        _render_confirmation_pane!(popup, inputstate, flowcalc_ipc, viewstate, popup_width)
    else
        _render_action_list!(popup, inputstate, flowcalc_ipc, viewstate)
    end

    CImGui.End()

    if !p_open[]
        dismiss_action_popup!(inputstate)
    end
    return nothing
end

"Render the confirmation sub-pane for an action requiring player confirmation."
function _render_confirmation_pane!(popup::ActionPopupState, inputstate, flowcalc_ipc, viewstate, popup_width)
    action = popup.pending_confirmation
    CImGui.TextWrapped(action.confirmation_message)
    CImGui.Dummy((0.0, 4.0))
    button_width = popup_width - 16.0
    CImGui.SetCursorPosX((popup_width - button_width) / 2.0)
    return if CImGui.Button("Confirm", (button_width, 28.0))
        _execute_action!(inputstate, popup, action, flowcalc_ipc, viewstate)
    end
end

"Render the action button list, then any target-specific extras (e.g. component delete)."
function _render_action_list!(popup::ActionPopupState, inputstate, flowcalc_ipc, viewstate)
    for action in popup.actions
        if button_with_disable(action.label, ImVec2(-1, 0), !action.enabled; tooltip = action.tooltip)
            if !isnothing(action.confirmation_message)
                popup.pending_confirmation = action
            else
                _execute_action!(inputstate, popup, action, flowcalc_ipc, viewstate)
            end
        end
    end
    return _render_target_extras!(popup, popup.target, inputstate, flowcalc_ipc, viewstate)
end

"Default: no extra UI elements for this popup target type."
_render_target_extras!(popup, target::AbstractPopupTarget, inputstate, flowcalc_ipc, viewstate) = nothing

"Component popups get a separator and a 'Delete Component' button with confirmation."
function _render_target_extras!(popup, target::ComponentPopupTarget, inputstate, flowcalc_ipc, viewstate)
    isempty(popup.actions) || CImGui.Separator()
    delete_action = ActionInfo(
        id = :delete_component,
        label = "Delete Component",
        enabled = true,
        tooltip = "Remove this component from the ship.",
        confirmation_message = "Delete this component permanently?",
    )
    return if button_with_disable(delete_action.label, ImVec2(-1, 0), false; tooltip = delete_action.tooltip)
        popup.pending_confirmation = delete_action
    end
end

#= ---------- Action Execution Dispatch ----------- =#

"Execute an action, dispatching on popup target type. Closes the popup after success."
function _execute_action!(inputstate, popup::ActionPopupState, action::ActionInfo, flowcalc_ipc, viewstate)
    result = _execute_target_action!(inputstate, popup.target, action, flowcalc_ipc, viewstate)
    result && dismiss_action_popup!(inputstate)
    return nothing
end

"Execute a component action — delete or regular DoActionCommand."
function _execute_target_action!(inputstate, target::ComponentPopupTarget, action::ActionInfo, flowcalc_ipc, viewstate)
    if action.id === :delete_component
        cmd = create_delete_elements_command(flowcalc_ipc.command_queue, target.coord)
    else
        cmd = create_do_action_command(flowcalc_ipc.command_queue, target.coord, action.id)
    end
    return try_enqueue_command!(flowcalc_ipc.command_queue, cmd)
end

"Execute a shared component action as one calculator transaction."
function _execute_target_action!(inputstate, target::ElementGroupPopupTarget, action::ActionInfo, flowcalc_ipc, viewstate)
    if action.id === :delete_component
        command = create_delete_elements_command(
            flowcalc_ipc.command_queue, Set(target.component_coords), Set(target.pipe_coords),
        )
        return try_enqueue_command!(flowcalc_ipc.command_queue, command)
    end
    command = create_do_action_command(flowcalc_ipc.command_queue, target.component_coords, action.id)
    return try_enqueue_command!(flowcalc_ipc.command_queue, command)
end

"Execute a ship action via the ship action dispatch system."
function _execute_target_action!(inputstate, target::ShipPopupTarget, action::ActionInfo, flowcalc_ipc, viewstate)
    return execute_ship_action!(ship_name = target.ship_name, action_id = action.id,
        flowcalc_ipc = flowcalc_ipc, viewstate = viewstate, inputstate = inputstate)
end

"Group component popups expose one atomic deletion action."
function _render_target_extras!(popup, target::ElementGroupPopupTarget, inputstate, flowcalc_ipc, viewstate)
    isempty(popup.actions) || CImGui.Separator()
    count = length(target.component_coords) + length(target.pipe_coords)
    delete_action = ActionInfo(
        id = :delete_component,
        label = "Delete $count Selected Items",
        enabled = true,
        tooltip = "Remove the selected components and pipes.",
        confirmation_message = "Delete all $count selected items permanently?",
    )
    return if button_with_disable(delete_action.label, ImVec2(-1, 0), false; tooltip = delete_action.tooltip)
        popup.pending_confirmation = delete_action
    end
end
