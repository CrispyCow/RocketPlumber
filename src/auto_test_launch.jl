#=
    NON-INTERACTIVE SMOKE-TEST ENTRY POINT

    This script boots the full game stack (window, OpenGL, CImGui,
    FlowCalculator background thread, rendering pipeline), loads the teaser
    showcase map, injects a scripted sequence of `MapEditCommand`s during the
    run, and exits cleanly via the engine's normal shutdown path once that
    script is exhausted.

    Used by automated agents and CI hooks to verify that the project compiles,
    boots, ticks, accepts cross-thread command enqueueing, and re-solves after
    edits without unhandled exceptions.

    Do not confuse this with:
      • repl_launch.jl  — interactive development entry point (with Revise)
      • julia_main.jl   — production entry point (no Revise, for JuliaC)

    To run from shell:
        julia --project=. --threads=2,1 --gcthreads=1,1 src/auto_test_launch.jl

    Extend the fixture below to exercise more command paths. The harness exits
    cleanly after the final exit-marker step is consumed.

    The harness opens a real OS window — it is not headless.
=#

# ===============================================================
# Project Dependencies
# ===============================================================

# Start Revise.jl First
using Revise
# Packages
using LinearAlgebra, StaticArrays, GeometryBasics
using ModernGL, GLFW, JLD2, CSyntax.CRef
using TimerOutputs, Accessors, Printf, CSyntax
using FilePathsBase, NativeFileDialog, FFMPEG
import CImGui, CImGui.lib
using ImPlot
# Custom Packages (working title: HexFlow; project: Rocket Plumber)
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise
using HexFlowLearningSystem

# ===============================================================
# Startup Sequence
# ===============================================================

# minimal load to get a window + ImGui context up quickly
includet(joinpath(dirname(@__FILE__), "initial_window_setup.jl"))
configure_threads() # needs minimum of 2 threads to run properly
window = start_window()
ui_loadingscreen_render(window, "Initialising")

# load the rest of the game code, showing a loading screen at each step.
include_with_loadingscreen(window, "recording.jl")
include_with_loadingscreen(window, "interactions.jl")
include_with_loadingscreen(window, "components.jl")
include_with_loadingscreen(window, "map_loading.jl")
include_with_loadingscreen(window, "gameloop.jl")
include_with_loadingscreen(window, "ui_common.jl")
include_with_loadingscreen(window, "ui_game.jl")
include_with_loadingscreen(window, "ui_menus.jl")
include_with_loadingscreen(window, "ui_learning.jl")
include_with_loadingscreen(window, "tutorials.jl")
include_with_loadingscreen(window, "startmenu.jl")
include_with_loadingscreen(window, "test_harness.jl")

# ===============================================================
# Smoke-Test Launch
# ===============================================================

teaser_map = mapgen_teasership()
set_learning_system!(
    teaser_map,
    SandboxLearningState(tutorial_id = :teaser, level_index = 1),
)

# =====================================================================
# Test fixture for the teaser map.
#
# Each entry is a `TestCommandStep` built with `make_test_step(...)`.
# The schedule is sorted descending inside `enter_gameloop`, so authoring
# order does not matter for tick-key correctness - but we author roughly
# in ascending tick order for readability.
#
# Cadences (60 UPS):
#   30 ticks ≈ 0.5 s   - placement / delete / move
#   60 ticks ≈ 1.0 s   - actions (circuit recompute per action)
#   90 ticks ≈ 1.5 s   - pipe lifecycle
#  200 ticks ≈ 3.3 s   - redock (covers redock animation duration)
# =====================================================================

# Pre-define off-ship pipe edges for Phase E. Defined once so the same
# edge can be referenced for place + delete reliably.
const EDGE_EXISTING_PRIMARY = EdgeCoord(
    VertexCoord(TileCoord(3, -8), HexFrame.Q_NEG),
    VertexCoord(TileCoord(2, -7), HexFrame.Q_POS),
)
const EDGE_MOVE_DESTINATION = EdgeCoord(
    VertexCoord(TileCoord(3, -9), HexFrame.Q_POS),
    VertexCoord(TileCoord(3, -8), HexFrame.Q_NEG),
)
const EDGE_OFFSHIP_A = EdgeCoord(
    VertexCoord(TileCoord(2, -5), HexFrame.Q_NEG),
    VertexCoord(TileCoord(1, -4), HexFrame.Q_POS),
)
const EDGE_OFFSHIP_B = EdgeCoord(
    VertexCoord(TileCoord(1, -4), HexFrame.Q_POS),
    VertexCoord(TileCoord(0, -3), HexFrame.Q_NEG),
)
const EDGE_ORPHAN = EdgeCoord(
    VertexCoord(TileCoord(99, 99), HexFrame.Q_NEG),
    VertexCoord(TileCoord(98, 100), HexFrame.Q_POS),
)
const EDGE_OCCUPIED_TARGET = EdgeCoord(
    VertexCoord(TileCoord(4, -9), HexFrame.Q_NEG),
    VertexCoord(TileCoord(3, -8), HexFrame.Q_POS),
)
const SHIP_AV551 = Symbol("##Ship AV-551#655")

reset_test_harness_stats!()

test_commands::TestCommandSchedule = [

    # ----- Phase A: Component placement / removal --------------------
    # Valid placements on empty primary surface tiles, plus targeted
    # invalid placement guards for occupied, off-map, and nozzle rules.
    make_test_step(100, make_test_set_tile(TileCoord(3, -9), deepcopy(TinyOnOffValve), HexFrame.Q_POS);
        expected_status = APPLIED,
        description = "Place TinyOnOffValve at (3,-9)"),
    make_test_step(130, make_test_set_tile(TileCoord(3, -6), deepcopy(TinyOnOffValve), HexFrame.Q_POS, true);
        expected_status = APPLIED,
        description = "Place mirrored TinyOnOffValve at (3,-6)"),
    make_test_step(160, make_test_set_tile(TileCoord(1, -7), deepcopy(TinyOnOffValve), HexFrame.Q_POS, true);
        expected_status = APPLIED,
        description = "Place mirrored TinyOnOffValve at (1,-7)"),
    make_test_step(200, make_test_set_tile(TileCoord(4, -6), deepcopy(TinyOnOffValve), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt placement on occupied pump tile (4,-6)"),
    make_test_step(230, make_test_set_tile(TileCoord(99, 99), deepcopy(TinyOnOffValve), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt placement at off-map tile (99,99)"),
    make_test_step(260, make_test_set_tile(TileCoord(3, -9), deepcopy(TinyNozzle), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt TinyNozzle placement on surface tile (3,-9) - nozzle must hang off the hull"),
    make_test_step(290, make_test_action(TileCoord(3, -9), :open_valve);
        expected_status = APPLIED,
        description = "Open valve at (3,-9)"),
    make_test_step(320, make_test_action(TileCoord(3, -9), :close_valve);
        expected_status = APPLIED,
        description = "Close valve at (3,-9)"),
    make_test_step(360, make_test_delete(TileCoord(3, -9));
        expected_status = APPLIED,
        description = "Delete component at (3,-9)"),
    make_test_step(400, make_test_delete(TileCoord(2, -5));
        expected_status = INVALID,
        description = "Delete empty tile (2,-5)"),
    make_test_step(430, make_test_delete(TileCoord(99, 99));
        expected_status = INVALID,
        description = "Delete off-map tile (99,99)"),

    # ----- Phase B: Component movement -------------------------------
    # Cover rotate-in-place success, cross-tile success, and targeted
    # invalid guards for empty source, occupied destination, immovable
    # components, and off-map destinations.
    make_test_step(700, make_test_move(TileCoord(3, -6), TileCoord(3, -6), HexFrame.R_NEG);
        expected_status = APPLIED,
        description = "Rotate mirrored valve in place at (3,-6)"),
    make_test_step(730, make_test_move(TileCoord(3, -6), TileCoord(5, -9), HexFrame.Q_POS);
        expected_status = APPLIED,
        description = "Move mirrored valve from (3,-6) to (5,-9)"),
    make_test_step(770, make_test_move(TileCoord(3, -6), TileCoord(2, -8), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move from empty source (3,-6)"),
    make_test_step(800, make_test_move(TileCoord(1, -7), TileCoord(4, -6), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move from (1,-7) into occupied pump tile (4,-6)"),
    make_test_step(830, make_test_move(TileCoord(5, -8), TileCoord(3, -9), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move charged liquid tank at (5,-8) to (3,-9)"),
    make_test_step(860, make_test_move(TileCoord(1, -7), TileCoord(99, 99), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move from (1,-7) to off-map tile (99,99)"),

    # ----- Phase C-1: Liquid tank actions ----------------------------
    # Cycle through vent / seal / unseal on a primary liquid tank.
    make_test_step(1100, make_test_action(TileCoord(5, -8), :vent_and_seal);
        expected_status = APPLIED,
        description = "Vent and seal liquid tank at (5,-8)"),
    make_test_step(1160, make_test_action(TileCoord(5, -8), :unseal_tank);
        expected_status = APPLIED,
        description = "Unseal liquid tank at (5,-8)"),
    make_test_step(1220, make_test_action(TileCoord(5, -8), :seal_tank);
        expected_status = APPLIED,
        description = "Seal liquid tank at (5,-8)"),
    make_test_step(1280, make_test_action(TileCoord(5, -8), :unseal_tank);
        expected_status = APPLIED,
        description = "Unseal liquid tank again at (5,-8)"),

    # ----- Phase C-2: Electric pump + post-toggle move ---------------
    # Turn pump off, move it to an empty tile, then turn back on at new coord.
    make_test_step(1340, make_test_action(TileCoord(4, -6), :pump_off);
        expected_status = APPLIED,
        description = "Turn pump off at (4,-6)"),
    make_test_step(1400, make_test_move(TileCoord(4, -6), TileCoord(2, -5), HexFrame.Q_POS);
        expected_status = APPLIED,
        description = "Move pump from (4,-6) to (2,-5)"),
    make_test_step(1460, make_test_action(TileCoord(2, -5), :pump_on);
        expected_status = APPLIED,
        description = "Turn pump on at (2,-5)"),

    # ----- Phase C-3: Gas tank actions (AV-551) ----------------------
    make_test_step(1520, make_test_action(TileCoord(2, -12), :vent_and_seal);
        expected_status = APPLIED,
        description = "Vent and seal AV-551 tank at (2,-12)"),
    make_test_step(1580, make_test_action(TileCoord(2, -12), :unseal_tank);
        expected_status = APPLIED,
        description = "Unseal AV-551 tank at (2,-12)"),
    make_test_step(1640, make_test_action(TileCoord(2, -12), :seal_tank);
        expected_status = APPLIED,
        description = "Seal AV-551 tank at (2,-12)"),
    make_test_step(1700, make_test_action(TileCoord(2, -12), :unseal_tank);
        expected_status = APPLIED,
        description = "Unseal AV-551 tank again at (2,-12)"),

    # ----- Phase C-4: Pressure-fed tank actions (Platform) -----------
    # PressureFedTankCompBehav has dual-chamber actions; exercise all five.
    make_test_step(1760, make_test_action(TileCoord(-4, -5), :vent_and_seal_gas);
        expected_status = APPLIED,
        description = "Vent and seal gas chamber at (-4,-5)"),
    make_test_step(1820, make_test_action(TileCoord(-4, -5), :unseal_gas);
        expected_status = APPLIED,
        description = "Unseal gas chamber at (-4,-5)"),
    make_test_step(1880, make_test_action(TileCoord(-4, -5), :vent_and_seal_liquid);
        expected_status = APPLIED,
        description = "Vent and seal liquid chamber at (-4,-5)"),
    make_test_step(1940, make_test_action(TileCoord(-4, -5), :unseal_liquid);
        expected_status = APPLIED,
        description = "Unseal liquid chamber at (-4,-5)"),
    make_test_step(2000, make_test_action(TileCoord(-4, -5), :seal_both);
        expected_status = APPLIED,
        description = "Seal both chambers at (-4,-5)"),
    make_test_step(2060, make_test_action(TileCoord(-4, -5), :unseal_gas);
        expected_status = APPLIED,
        description = "Unseal gas chamber again at (-4,-5)"),
    make_test_step(2120, make_test_action(TileCoord(-4, -5), :unseal_liquid);
        expected_status = APPLIED,
        description = "Unseal liquid chamber again at (-4,-5)"),

    # ----- Phase C-5: BoolSwitch valve (initially closed, old_primary)
    make_test_step(2180, make_test_action(TileCoord(-4, -1), :open_valve);
        expected_status = APPLIED,
        description = "Open old_primary valve at (-4,-1)"),
    make_test_step(2240, make_test_action(TileCoord(-4, -1), :close_valve);
        expected_status = APPLIED,
        description = "Close old_primary valve at (-4,-1)"),
    make_test_step(2300, make_test_action(TileCoord(-4, -1), :open_valve);
        expected_status = APPLIED,
        description = "Re-open old_primary valve at (-4,-1)"),

    # ----- Phase C-6: BoolSwitch valve (initially OPEN, Platform) ----
    make_test_step(2360, make_test_action(TileCoord(-3, -7), :close_valve);
        expected_status = APPLIED,
        description = "Close Platform valve at (-3,-7)"),
    make_test_step(2420, make_test_action(TileCoord(-3, -7), :open_valve);
        expected_status = APPLIED,
        description = "Open Platform valve at (-3,-7)"),

    # ----- Phase C-7: SteppedSwitch valve (old_primary, ~7%) ---------
    # Four opens then two closes. Distinct ticks per step so authoring
    # order survives the stable descending sort.
    make_test_step(2480, make_test_action(TileCoord(-3, 2), :step_valve_open);
        expected_status = APPLIED,
        description = "Step old_primary valve open at (-3,2) [1]"),
    make_test_step(2510, make_test_action(TileCoord(-3, 2), :step_valve_open);
        expected_status = APPLIED,
        description = "Step old_primary valve open at (-3,2) [2]"),
    make_test_step(2540, make_test_action(TileCoord(-3, 2), :step_valve_open);
        expected_status = APPLIED,
        description = "Step old_primary valve open at (-3,2) [3]"),
    make_test_step(2570, make_test_action(TileCoord(-3, 2), :step_valve_open);
        expected_status = APPLIED,
        description = "Step old_primary valve open at (-3,2) [4]"),
    make_test_step(2600, make_test_action(TileCoord(-3, 2), :step_valve_close);
        expected_status = APPLIED,
        description = "Step old_primary valve closed at (-3,2) [1]"),
    make_test_step(2630, make_test_action(TileCoord(-3, 2), :step_valve_close);
        expected_status = APPLIED,
        description = "Step old_primary valve closed at (-3,2) [2]"),

    # ----- Phase C-8: SteppedSwitch valve (Platform, starts at 0%) ---
    make_test_step(2670, make_test_action(TileCoord(-5, -7), :step_valve_open);
        expected_status = APPLIED,
        description = "Step Platform valve open at (-5,-7) [1]"),
    make_test_step(2690, make_test_action(TileCoord(-5, -7), :step_valve_open);
        expected_status = APPLIED,
        description = "Step Platform valve open at (-5,-7) [2]"),
    make_test_step(2710, make_test_action(TileCoord(-5, -7), :step_valve_close);
        expected_status = APPLIED,
        description = "Step Platform valve closed at (-5,-7)"),

    # ----- Phase C-9: Switched nozzle (initially closed) -------------
    make_test_step(2750, make_test_action(TileCoord(0, -12), :open_valve);
        expected_status = APPLIED,
        description = "Open switched nozzle at (0,-12)"),
    make_test_step(2810, make_test_action(TileCoord(0, -12), :close_valve);
        expected_status = APPLIED,
        description = "Close switched nozzle at (0,-12)"),
    make_test_step(2870, make_test_action(TileCoord(0, -12), :repair_component);
        expected_status = INVALID,
        description = "Attempt repair on undamaged switched nozzle at (0,-12)"),

    # ----- Phase C-10: Switched nozzle (armed, with overheat) --------
    make_test_step(2930, make_test_action(TileCoord(1, -14), :repair_component);
        expected_status = INVALID,
        description = "Attempt repair on undamaged armed nozzle at (1,-14) - armed state alone does not damage"),
    make_test_step(2990, make_test_action(TileCoord(1, -14), :close_valve);
        expected_status = APPLIED,
        description = "Close armed switched nozzle at (1,-14)"),
    make_test_step(3050, make_test_action(TileCoord(1, -14), :open_valve);
        expected_status = APPLIED,
        description = "Open armed switched nozzle at (1,-14)"),
    make_test_step(3070, make_test_action(TileCoord(-3, 0), :repair_component);
        expected_status = INVALID,
        description = "Attempt repair on undamaged turbopump at (-3,0)"),

    # ----- Phase C-11: Negative action tests -------------------------
    # `:flip` is not recognised by tanks; the command logs the failure but still
    # resolves as INVALID because the action refuses to apply without throwing.
    make_test_step(3110, make_test_action(TileCoord(5, -8), :flip);
        expected_status = INVALID,
        description = "Attempt unsupported :flip action on liquid tank (5,-8)"),
    make_test_step(3140, make_test_action(TileCoord(5, -8), :repair_component);
        expected_status = INVALID,
        description = "Attempt repair on liquid tank at (5,-8)"),
    # Action on a tile that has no component.
    make_test_step(3170, make_test_action(TileCoord(99, 99), :open_valve);
        expected_status = INVALID,
        description = "Attempt action on empty tile (99,99)"),

    # ----- Phase D: ClickTileCommand smoke ---------------------------
    # `on_click!` dispatch through the click command path.
    make_test_step(3300, make_test_click(TileCoord(-3, -7));
        expected_status = APPLIED,
        description = "Click tile (-3,-7)"),
    make_test_step(3360, make_test_click(TileCoord(-5, -6), CartesianCoord(0.3, 0.0));
        expected_status = APPLIED,
        description = "Click tile (-5,-6) with offset"),
    make_test_step(3420, make_test_click(TileCoord(2, -5));
        expected_status = APPLIED,
        description = "Click tile (2,-5)"),
    make_test_step(3480, make_test_click(TileCoord(0, -11));
        expected_status = APPLIED,
        description = "Click tile (0,-11)"),
    make_test_step(3540, make_test_click(TileCoord(99, 99));
        expected_status = INVALID,
        description = "Attempt click on empty tile (99,99)"),

    # ----- Phase E: Pipe lifecycle -----------------------------------
    # Delete + re-place an existing teaser pipe on primary, then build a
    # verified off-ship chain to exercise orphan protection and pipe moves.
    make_test_step(3600, make_test_delete(EDGE_EXISTING_PRIMARY);
        expected_status = APPLIED,
        description = "Delete existing primary pipe edge"),
    make_test_step(3690, make_test_set_pipe(EDGE_EXISTING_PRIMARY, deepcopy(ScrapPipe));
        expected_status = APPLIED,
        description = "Re-place primary pipe edge"),
    make_test_step(3780, make_test_set_pipe(EDGE_OFFSHIP_A, deepcopy(ScrapPipe));
        expected_status = APPLIED,
        description = "Place off-ship pipe A"),
    make_test_step(3870, make_test_set_pipe(EDGE_OFFSHIP_B, deepcopy(ScrapPipe));
        expected_status = APPLIED,
        description = "Place off-ship pipe B chained from A"),
    make_test_step(3930, make_test_delete(EDGE_OFFSHIP_A);
        expected_status = APPLIED,
        description = "Delete off-ship pipe A while pipe B remains surface-connected"),
    make_test_step(3990, make_test_set_pipe(EDGE_OFFSHIP_A, deepcopy(ScrapPipe));
        expected_status = APPLIED,
        description = "Re-place off-ship pipe A"),
    make_test_step(4020, make_test_set_pipe(EDGE_OFFSHIP_A, deepcopy(ScrapPipe));
        expected_status = INVALID,
        description = "Attempt re-place occupied off-ship pipe A"),
    make_test_step(4050, make_test_set_pipe(EDGE_ORPHAN, deepcopy(ScrapPipe));
        expected_status = INVALID,
        description = "Attempt orphan deep-space pipe placement"),
    make_test_step(4140, make_test_delete(EDGE_OFFSHIP_B);
        expected_status = APPLIED,
        description = "Delete off-ship pipe B"),
    make_test_step(4200, make_test_delete(EDGE_OFFSHIP_A);
        expected_status = APPLIED,
        description = "Delete off-ship pipe A"),
    make_test_step(4260, make_test_delete(EDGE_OFFSHIP_A);
        expected_status = INVALID,
        description = "Attempt delete already-removed off-ship pipe A"),
    make_test_step(4320, make_test_move(EDGE_EXISTING_PRIMARY, EDGE_MOVE_DESTINATION, HexFrame.Q_POS);
        expected_status = APPLIED,
        description = "Move primary pipe to empty surface edge"),
    make_test_step(4380, make_test_move(EDGE_EXISTING_PRIMARY, EDGE_OCCUPIED_TARGET, HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move from empty primary pipe source edge"),
    make_test_step(4440, make_test_move(EDGE_MOVE_DESTINATION, EDGE_OCCUPIED_TARGET, HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt move of primary pipe into occupied destination edge"),

    # ----- Phase F: Ship surface management --------------------------
    # (0,-7) is adjacent only to primary via (1,-7); Platform's (-2,-7) is two hexes away.
    make_test_step(4600, make_test_add_ship_surface(TileCoord(0, -7));
        expected_status = APPLIED,
        description = "Add primary-adjacent surface tile at (0,-7)"),
    # Already a surface tile.
    make_test_step(4660, make_test_add_ship_surface(TileCoord(5, -7));
        expected_status = INVALID,
        description = "Attempt adding existing surface tile (5,-7)"),
    # Far from any ship - no adjacency.
    make_test_step(4720, make_test_add_ship_surface(TileCoord(99, 99));
        expected_status = INVALID,
        description = "Attempt adding distant surface tile (99,99)"),
    # Remove the surface tile we just added.
    make_test_step(4780, make_test_remove_ship_surface(TileCoord(0, -7));
        expected_status = APPLIED,
        description = "Remove temporary surface tile at (0,-7)"),
    # Tank still on this tile, so the command should soft-fail without throwing.
    make_test_step(4840, make_test_remove_ship_surface(TileCoord(4, -7));
        expected_status = INVALID,
        description = "Attempt removing occupied surface tile (4,-7)"),

    # ----- Phase G: Ship docking (RedockShipCommand) -----------------
    # Move AV-551 away from primary, then probe two follow-up offsets against
    # the redock exclusion rules.
    make_test_step(5000, make_test_redock_ship(SHIP_AV551, TileCoord(0, -3));
        expected_status = APPLIED,
        description = "Redock AV-551 away from primary by (0,-3)"),
    make_test_step(5200, make_test_redock_ship(SHIP_AV551, TileCoord(0, 3));
        expected_status = INVALID,
        description = "Attempt redock AV-551 back toward primary by (0,3)"),
    # Primary redock is forbidden by command validation.
    make_test_step(5300, make_test_redock_ship(:primary, TileCoord(1, 0));
        expected_status = INVALID,
        description = "Attempt redock of :primary"),
    # After the blocked return above, this shorter follow-up offset is still valid.
    make_test_step(5380, make_test_redock_ship(SHIP_AV551, TileCoord(0, 2));
        expected_status = APPLIED,
        description = "Redock AV-551 by (0,2) from offset position"),

    # ----- Phase H: Encounter ship spawning --------------------------
    # Reuse an existing ship's blueprint via `get_ship_blueprint` so the
    # encounter command receives a known-good payload. `target_encounter_index`
    # is nothing -> dev mode, no space_map mutation, repeatable.
    make_test_step(5600, make_test_add_encounter_ship(
        get_ship_blueprint(teaser_map, SHIP_AV551),
        "##TestEncounter_AV551",
        UInt32(0xA0A0A0A0),
    );
        expected_status = APPLIED,
        description = "Spawn encounter ship from AV-551 blueprint"),
    make_test_step(5800, make_test_add_encounter_ship(
        get_ship_blueprint(teaser_map, :primary),
        "##TestEncounter_Primary",
        UInt32(0xB0B0B0B0);
        dir = HexFrame.Q_NEG,
    );
        expected_status = APPLIED,
        description = "Spawn encounter ship from primary blueprint"),
    make_test_step(6000, make_test_add_encounter_ship(
        get_ship_blueprint(teaser_map, :primary),
        "##TestEncounter_Primary",
        UInt32(0xB0B0B0B0);
        dir = HexFrame.Q_NEG,
    );
        expected_status = APPLIED,
        description = "Spawn repeated primary encounter ship"),

    # ----- Phase I: Tile-pipe commands -------------------------------
    make_test_step(6100, make_test_modify_tile_pipe(TileCoord(-3, -1), HexFrame.S_POS, ScrapTilePipeBehavFrag());
        expected_status = APPLIED,
        description = "Modify tile pipe at (-3,-1) on S_POS"),
    make_test_step(6130, make_test_modify_tile_pipe(TileCoord(99, 99), HexFrame.S_POS, ScrapTilePipeBehavFrag());
        expected_status = INVALID,
        description = "Attempt tile-pipe modify at off-map tile (99,99)"),
    make_test_step(6160, make_test_modify_tile_pipe(TileCoord(5, -8), HexFrame.S_POS, ScrapTilePipeBehavFrag());
        expected_status = INVALID,
        description = "Attempt tile-pipe modify on non-pipe component at (5,-8)"),
    make_test_step(6190, make_test_move_tile_pipe(TileCoord(-3, -1), HexFrame.S_POS, TileCoord(-3, -1), HexFrame.Q_POS);
        expected_status = APPLIED,
        description = "Move tile pipe on (-3,-1) from S_POS to Q_POS"),
    make_test_step(6220, make_test_move_tile_pipe(TileCoord(-3, -1), HexFrame.S_POS, TileCoord(-3, -1), HexFrame.R_POS);
        expected_status = INVALID,
        description = "Attempt tile-pipe move from empty S_POS axis at (-3,-1)"),
    make_test_step(6250, make_test_move_tile_pipe(TileCoord(-3, -1), HexFrame.Q_POS, TileCoord(5, -8), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt tile-pipe move into non-pipe destination at (5,-8)"),
    make_test_step(6280, make_test_move_tile_pipe(TileCoord(-3, -1), HexFrame.Q_POS, TileCoord(99, 99), HexFrame.Q_POS);
        expected_status = INVALID,
        description = "Attempt tile-pipe move to off-map tile (99,99)"),

    # ----- Phase J: Map override -------------------------------------
    # Replaces the entire GameMap. MUST be the last functional command
    # because every prior coordinate reference becomes meaningless.
    # Smoke test only - verifies the override path applies without crashing.
    make_test_step(6400, make_test_map_override(mapgen_teasership());
        expected_status = APPLIED,
        description = "Replace current map with a fresh teaser map"),

    # ----- Phase K: Exit ---------------------------------------------
    make_test_step(6600; description = "Exit marker"),
]

@info "Test harness running with $(length(test_commands)) scheduled entries"
result = enter_gameloop(window; map_source = teaser_map, test_commands = test_commands)
@info "Test harness exited cleanly (reason = $(result.exit_reason))"
wait_for_test_harness_resolution()
print_test_harness_summary()

# Mirror the canonical shutdown from `enter_start_menu` so the OS window is
# actually destroyed and CImGui/ImPlot release their contexts. Without this the
# window lingers as "not responding" after `enter_gameloop` returns because
# nothing is polling GLFW events any more.
@info "Tearing down ImGui and destroying GLFW window"
ui_teardown()
GLFW.DestroyWindow(window)
@info "Test harness shutdown complete"

test_harness_failed() && exit(1)
