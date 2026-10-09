# src/tutorials.jl

# ===============================================================
# Tutorial Mapgen Registry
# ===============================================================

"A labelled map generator available from the developer utilities."
struct TutorialMapgen{F <: Function}
    label::String
    generator::F
end

const _tutorial_mapgen_teaser = TutorialMapgen("Teaser Showcase — mapgen_teasership()", mapgen_teasership)
const _tutorial_mapgen_basic_plumbing = TutorialMapgen("Basic Controls: Cold Gas — mapgen_basicplumbing()", mapgen_basicplumbing)
const _tutorial_mapgen_big_pipe_plumbing = TutorialMapgen("Basic Controls: Larger Pipes — mapgen_bigpipeplumbing()", mapgen_bigpipeplumbing)
const _tutorial_mapgen_flow_demo = TutorialMapgen("Basic Controls: Flow Demo — mapgen_flowdemo()", mapgen_flowdemo)
const _tutorial_mapgen_biprop_demo = TutorialMapgen("BiProp Demo — mapgen_bipropdemo()", mapgen_bipropdemo)
const _tutorial_mapgen_liquid_transfer = TutorialMapgen("Moving Liquid with Transfer Pumps — mapgen_liquidtransfer()", mapgen_liquidtransfer)
const _tutorial_mapgen_pressure_fed = TutorialMapgen("Pressure-Fed Tanks — mapgen_pressurefedintro()", mapgen_pressurefedintro)
const _tutorial_mapgen_turbo_pump = TutorialMapgen("Turbo-Pumps and Tap-Off Cycle — mapgen_turbopumpintro2()", mapgen_turbopumpintro2)

const TUTORIAL_MAPGENS = (
    _tutorial_mapgen_teaser,
    _tutorial_mapgen_basic_plumbing,
    _tutorial_mapgen_big_pipe_plumbing,
    _tutorial_mapgen_flow_demo,
    _tutorial_mapgen_biprop_demo,
    _tutorial_mapgen_liquid_transfer,
    _tutorial_mapgen_pressure_fed,
    _tutorial_mapgen_turbo_pump,
)
const TUTORIAL_MAPGEN_LABELS = [mapgen.label for mapgen in TUTORIAL_MAPGENS]

# ===============================================================
# Tutorial Helper Functions
# ===============================================================

"Remove leading indentation from each non-empty line of tutorial text."
function tutorial_dedent(s::AbstractString)
    lines = split(s, '\n'; keepempty=true)
    out = IOBuffer()

    for (i, line) in enumerate(lines)
        if isempty(strip(line))
            # whitespace-only or empty line → keep exactly as-is
            write(out, line)
        else
            # non-empty line → strip leading indentation
            write(out, replace(line, r"^\s+" => ""))
        end
        if i < length(lines)
            write(out, '\n')
        end
    end

    return String(take!(out))
end

"True if any component on the gamemap satisfies `predicate(placed_component)`."
has_placed_component_matching(gamemap::GameMap, predicate::Function)::Bool =
    any(predicate, values(get_components(gamemap)))

"True if any component on the gamemap has a component behaviour satisfying `predicate(behaviour)`."
has_component_matching(gamemap::GameMap, predicate::Function)::Bool =
    any(c -> predicate(c.component), values(get_components(gamemap)))

"True if any component on the gamemap has a component behaviour of type `T`."
has_component_type(gamemap::GameMap, ::Type{T}) where {T} =
    has_component_matching(gamemap, component -> component isa T)

# ===============================================================
# Learning Entry Definitions
# ===============================================================

function get_entry_teaser()::LearningEntry
    return LearningEntry(
        id = :teaser,
        trigger = _ -> true,
        priority = 0,
        definition = SandboxTutorialDef(
            title = "Teaser Showcase Map",
            description = "A showcase map demonstrating some of what you can build in Rocket Plumber.",
            body_text = "An optional showcase map demonstrating some of what you can build in Rocket Plumber",
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_teaser.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "WELCOME",
                            text = tutorial_dedent(
                                "Welcome to Rocket Plumber, a spacecraft simulation game with a focus on fluid systems and plumbing!\n
                                This is a teaser map intended to show off some of the things you can build in the game, and to get you excited to jump in and start playing! \
                                The controls you will need to look around are:\n
                                 - MIDDLE MOUSE CLICK and drag to pan the view, or press the WASD keys.\n
                                 - SCROLL WHEEL or Q/E keys to zoom in and out.\n
                                Feel free to look around as much as you want, but you aren't expected to understand how anything works just yet!\n"
                            ),
                        ),
                        TutorialStep(
                            heading = "WHAT TO PLAY",
                            text = tutorial_dedent(
                                "Once you have finished here, start a new game in explorer mode! This is the main mode of the game where you build up your ship by manoeuvring to and salvaging from other vessels in space. \
                                You don't need to start with any tutorials, explorer mode includes a learning system that will unlock appropriate tutorials as you play to guide you through learning the game!"
                            ),
                        ),
                        TutorialStep(
                            heading = "GAME STATUS",
                            text = tutorial_dedent(
                                "This project is currently in early development. \
                                The core simulation is implemented, along with a minimal set of components and rocket types (I have ideas for way more!). \
                                The basics of the gameplay loop are also there in explorer mode, where you have to perform manoeuvres to salvage parts and fuel from randomly generated ships. \
                                You will build up the capabilities of your ship as you go, and eventually you can perform one massive burn to escape the galaxy and win the game!\n
                                However there is still a long way to go, with many features and components yet to be implemented. \
                                There is no real way to lose (unless you run out of fuel), and there are no threats forcing you to explore and improve.
                                The UI is also still a work in progress, with a lot of internal debug info still being displayed.\n
                                These are all things I want to work on in the future, but hopefully what's already here is enough to be interesting and give you an idea of where this game could go!"
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )
end

function get_entry_welcome_explorer()::LearningEntry
    return LearningEntry(
        id = :welcome_explorer,
        trigger = _ -> true,
        priority = 50,
        definition = InGameTutorialDef(
            title = "Welcome to Rocket Plumber",
            description = "A brief welcome to the game's Explorer mode.",
            steps = [
                TutorialStep(
                    heading = "WELCOME",
                    text = tutorial_dedent(
                        "Welcome to Rocket Plumber, a spacecraft simulation game with a focus on fluid systems and plumbing! \
                        This is explorer mode, where your goal is to repair your ship, manoeuvre to other vessels to salvage parts and fuel, and increase your velocity each step of the way. \
                        Eventually when your ship is powerful enough, you can perform a massive burn to escape the galaxy and win the game!\n
                        The learning system will guide you on how to play, look out for new tips and tutorials as you explore and interact with the game."
                    ),
                ),
            ],
        ),
    )
end

function get_entry_basic_controls()::LearningEntry
    return LearningEntry(
        id = :basic_controls,
        trigger = _ -> true,
        priority = 100,
        definition = SandboxTutorialDef(
            title = "Basic Controls and Plumbing",
            description = "Learn camera controls, placement modes, and how to plumb pipes.",
            body_text = tutorial_dedent(
                "If this is your first time playing, you can complete this interactive sandbox tutorial which will guide you through the basics! \
                Alternatively, here's a quick controls refresher.\n
                Basic Controls:\n
                - MIDDLE MOUSE CLICK and drag to pan the view, or press the WASD keys.\n
                - SCROLL WHEEL or Q/E keys to zoom in and out.\n
                - CLICK, HOLD and DRAG to move components and pipes.\n
                - CLICK A NODE to start placing or deleting scrap pipes.\n
                - ESC to open the pause menu, or to exit modes like pipe placement.\n
                - RIGHT-CLICK on components to access their actions, including an action to delete them.\n
                - SHIFT + CLICK to select multiple components at once."
            ),
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_basic_plumbing.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "INTRODUCTION",
                            text = tutorial_dedent(
                                "Welcome to Rocket Plumber! \
                                This tutorial introduces basic controls and plumbing concepts using a cold gas system."
                            ),
                        ),
                        TutorialStep(
                            heading = "USE VIEW CONTROLS",
                            text = tutorial_dedent(
                                "Use WASD or MIDDLE MOUSE CLICK and drag to pan the view.
                                Use Q/E or SCROLL WHEEL to zoom in and out.
                                Press ESC to open the pause menu. \n
                                Try this out now!"
                            ),
                            step_blocker = let initial_view = Ref{Union{Nothing, NTuple{3, Float32}}}(nothing)
                                function(inputs::LearningInputs)
                                    current_view = (inputs.viewstate.view_x, inputs.viewstate.view_y, inputs.viewstate.view_zoom)
                                    if isnothing(initial_view[])
                                        initial_view[] = current_view
                                    elseif current_view != initial_view[] || inputs.inputstate.escape_menu_active
                                        return nothing
                                    end

                                    return "Pan or zoom the view, or press ESC to open the pause menu."
                                end
                            end,
                        ),
                        TutorialStep(
                            heading = "PLACE PIPES AND CONNECT THE NOZZLE",
                            text = tutorial_dedent(
                                "You need to connect the tank to the nozzle with pipes to start producing thrust!\n
                                CLICK A NODE to start placing scrap pipes. There's always plenty of scrap lying around to make these. \
                                Move the cursor in the desired direction, then click to place it.\n
                                You can press ESC to cancel pipe placement."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Connect the tank to the nozzle with pipes to produce thrust."
                            end,
                        ),
                        TutorialStep(
                            heading = "DELETE PIPES TO DISCONNECT THE NOZZLE",
                            text = tutorial_dedent(
                                "Now delete the pipes to disconnect the nozzle and stop the thrust!\n
                                CLICK A NODE of the pipe you want to delete the same way you did to place pipes. \
                                Move the cursor in the direction of the pipe you want to remove, then click to delete it."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) <= 0.0 && return nothing
                                return "Delete the pipes to disconnect the nozzle and stop the thrust."
                            end,
                        ),
                    ],
                ),
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_big_pipe_plumbing.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MOVE THE NOZZLE SO IT FACES LEFT",
                            text = tutorial_dedent(
                                "This ship's nozzle is pointing the wrong way at the moment, let's move it so the ship's exhaust and thrust will come out the left side!\n
                                CLICK AND DRAG the nozzle to move it around. \
                                Its direction will change based on which part of the hex tile your cursor is in. \
                                If you have changed your mind you can cancel the move by pressing ESC."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                has_left_facing_nozzle = has_placed_component_matching(inputs.gamemap, function(placed_component)
                                    return placed_component.component isa BasicNozzleCompBehav && placed_component.rotation == HexFrame.Q_POS
                                end)

                                has_left_facing_nozzle && return nothing
                                return "Move the nozzle to the left and rotate it to point left."
                            end,
                        ),
                        TutorialStep(
                            heading = "PLUMB THE NOZZLE BY MOVING PIPES",
                            text = tutorial_dedent(
                                "This ship has some better pipes lying around you can use to plumb the nozzle to the tanks. \
                                If you use them you will get more flow through your nozzle at a higher pressure, so you will be generating more thrust more efficiently. \
                                These pipes can't be created from scrap, you will have to move the existing ones.\n
                                CLICK AND DRAG the pipes to move them into place, just like you did with the nozzle."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                tank_pressure = maximum((
                                    first(produce_rel_elements(placed_component.component)).value
                                    for placed_component in values(get_components(inputs.gamemap))
                                    if placed_component.component isa ThevininTankCompBehav{GasTankBehavFrag}
                                ); init = 0.0)

                                # An unrestricted nozzle produces about 45 thrust per unit of tank pressure.
                                normalised_thrust = tank_pressure > 0.0 ? norm(inputs.gamestate.thrust) / tank_pressure : 0.0
                                normalised_thrust >= 42.0 && return nothing
                                return "Plumb the nozzle to produce thrust with big pipes."
                            end,
                        ),
                        TutorialStep(
                            heading = "VENT THEN MOVE A GAS TANK",
                            text = tutorial_dedent(
                                "Try moving one of the gas tanks while you are here, you will notice it doesn't work if it still contains gas. \
                                You should try and use as much of the fuel as you can, but if you do need a tank empty you can always vent it to space! \n
                                RIGHT CLICK on the tank to open the 'actions' panel, and select 'vent and seal' to empty its contents and allow it to be moved. \n
                                The tank is now empty and can be moved, but it is also 'sealed' and so it won't accept more fluid. \
                                Open the actions panel again and select 'unseal' to let the tanks accept fluid again."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                has_vented_tank = has_component_matching(inputs.gamemap, function(component)
                                    component isa ThevininTankCompBehav{GasTankBehavFrag} || return false
                                    tank = component.tank.tank
                                    return is_sealed(tank) && tank.state.charge <= 0.0
                                end)
                                has_vented_tank && return nothing
                                return "Right-click a gas tank and use the vent action to empty it."
                            end,
                        ),
                    ],
                ),
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_flow_demo.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "NODE PRESSURE INDICATORS",
                            text = tutorial_dedent(
                                "You might have noticed that the connection nodes at the vertices of the hex tiles are coloured. \
                                This indicates the fluid pressure at that node, the brighter the colour the higher the pressure! \
                                Black nodes indicate no pressure, or that the node is unused so it has been disconnected to avoid leaks."
                            ),
                        ),
                        TutorialStep(
                            heading = "CONNECT THE NOZZLES",
                            text = tutorial_dedent(
                                "This map is built to show this off! \n
                                Complete the already rather chaotic pipe network between the tanks and the nozzle with a few more pipes, then take a look at the colours! \n
                                You can hover over nodes to see their pressure, or hover over pipes and nozzles to see their flow rates. \
                                The units might not be what you expect, but that will be explained shortly."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Connect the pipes to produce thrust from a nozzle."
                            end,
                        ),
                        TutorialStep(
                            heading = "PRESSURE AND FLUID FLOW",
                            text = tutorial_dedent(
                                "It was hinted at in the demo introducing the big pipes, but the modelling of fluid flow is rather detailed in this game. \
                                Fluids will flow from higher pressure nodes to lower pressure nodes. Pipes and other elements pose a resistance to this flow, some more than others. \
                                The drop in pressure from this resistance is proportional to the amount of flow in the pipes, so using good quality pipes is important for high-flow connections (like the connection to a nozzle)."
                            ),
                        ),
                        TutorialStep(
                            heading = "PRESSURE AND FLOW CALCULATIONS",
                            text = tutorial_dedent(
                                "An understanding of this is not necessary to play so finish this task at any time, but if you are curious for a peek under the hood:\n
                                This all might seem a bit familiar for anyone with an electronics background (Ohm's law!). \
                                That is not a coincidence. In addition to this being a decent approximation of fluid flow in the real world, this is because the game is actually based around a circuit analogy of fluid flow. \
                                Your pipes and pumps are converted into circuit elements, and the circuit is solved using circuit simulation algorithms that would not be out of place in a SPICE tool to give you your pressures (voltages) and flow rates (current). \
                                You can get a peek at the actual numbers by hovering over the components, and pipes to see what circuit elements they correspond to! (at least until I hide that in a debug menu)"
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )
end

function get_entry_first_burn()::LearningEntry
    return LearningEntry(
        id = :first_burn,
        trigger = _ -> true,
        priority = 150,
        definition = InGameTutorialDef(
            title = "Completing First Burn",
            description = "Guides you through completing the first auto-planned burn manoeuvre at the start of the game.",
            steps = [
                TutorialStep(
                    heading = "INTRO TO WHAT YOU NEED TO DO",
                    text = tutorial_dedent(
                        "You have just been awoken by a proximity alert, another ship! A capture burn has already been planned for you.\n
                        Your ship has some cold gas tanks and switched nozzles scattered around.\n
                        To complete the manoeuvre and dock with the ship, you will have to assemble your ship and use your cold-gas thrusters to execute the planned burn."
                    ),
                ),
                TutorialStep(
                    heading = "ASSEMBLE YOUR SHIP",
                    text = tutorial_dedent(
                        "This manoeuvre requires you to accelerate towards the right (as indicated by the compass in the top left) so you will need at least one nozzle pointing to the left. \n
                        Now make sure your nozzles are piped up to gas. These are switched nozzles so you don't need to worry about them turning on straight away. \n
                        If you aren't sure how to do any of this, make sure you've completed the 'Basic Controls and Plumbing' tutorial first for guidance on that."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        has_left_facing_plumbed_nozzle = any(get_components(inputs.gamemap)) do entry
                            coord, placed_component = entry
                            placed_component.rotation == HexFrame.Q_POS || return false

                            component = placed_component.component
                            input_node_pos =
                                if component isa BasicNozzleCompBehav
                                    component.nozzle.connected_node
                                elseif component isa SwitchedNozzleCompBehav
                                    component.switch.switch.connection.v1
                                else
                                    return false
                                end

                            input_node = map_element(input_node_pos, coord, placed_component.rotation)
                            fluid = get(inputs.derivedmapstate.nodeactualfluids, input_node, nothing)
                            return HexFluids.is_gas(fluid)
                        end

                        has_left_facing_plumbed_nozzle && return nothing
                        return "Move nozzles so you have at least one pointing left and plumb it up"
                    end,
                ),
                TutorialStep(
                    heading = "CONTROL THE NOZZLES",
                    text = tutorial_dedent(
                        "To control the switched nozzles, you can right-click on them to see their actions, or simply click the nozzle which toggles it between on and off. \
                        It does take a small amount of time for the valve to actuate, but this is the fastest-to-control rocket engine you'll ever get! \n
                        Try switching the nozzle on and off."
                    ),
                    step_blocker = let has_seen_nozzle_on = Ref(false)
                        function(inputs::LearningInputs)
                            nozzle_is_on = any(each_component_of_type(inputs.gamemap, SwitchedNozzleCompBehav)) do placed_component
                                return get_target_percentage(placed_component.component.switch) ≈ 1.0
                            end

                            if nozzle_is_on
                                has_seen_nozzle_on[] = true
                            end

                            has_seen_nozzle_on[] && norm(inputs.gamestate.thrust) == 0.0 && return nothing
                            return "Toggle a nozzle on and then off by clicking it in inspect mode."
                        end
                    end,
                ),
                TutorialStep(
                    heading = "EXECUTE THE MANOEUVRE",
                    text = tutorial_dedent(
                        "Now you have everything set up to complete the capture burn.\n
                        In the manoeuvre info on the left you can see the required velocity change remaining, switch your nozzles on until that reaches zero. \
                        It can be helpful to pulse the nozzles in short bursts as you approach the target to avoid overshooting. \
                        If you do overshoot, don't stress. You can just move a nozzle over to the right and fire in the opposite direction!\n
                        Once you have reached the target velocity, you will dock with the new ship automatically!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        get_total_encounter_count(inputs.gamemap) > 0 && return nothing
                        return "Complete your first manoeuvre to reach the target."
                    end,
                ),
            ],
        ),
    )
end

function get_entry_cold_gas_fuel()::LearningEntry
    return LearningEntry(
        id = :cold_gas_fuel,
        trigger = inputs -> get_wet_mass(inputs.gamemap; fluid = HexFluids.COLD_GAS) > 0,
        priority = 200,
        definition = InGameTutorialDef(
            title = "Cold Gas Fuel",
            description = "Learn about cold gas fuel and its characteristics.",
            steps = [
                TutorialStep(
                    heading = "COLD GAS FUEL",
                    text = tutorial_dedent(
                        "Cold gas is the simplest type of rocket fuel, it's just a tank of inert gas. \
                        The gas is stored at high pressure so you don't need a pump to make an engine, just release it through a nozzle!\n
                        Cold gas is not a very efficient fuel. There is only so much energy in a pressurised tank of gas, compared to the chemical energy in a tank of liquid fuel. \
                        Its main advantage is that the gas is, well, cold, so it's not going to melt your valve like the glowing-hot exhaust of a chemical rocket might. \
                        This means you can use simple switched nozzles to control your thrust, which turn on and off really quickly.\n
                        Refilling cold gas tanks is also easy, connect empty tanks to full ones with pipes and the gas will flow to equalise the pressure, but you will always be leaving some behind.\n
                        Overall cold gas is a great choice for fine manoeuvring, but once you find more efficient liquid fuels you will probably want to switch to those for your main engines."
                    ),
                ),
            ],
        ),
    )
end

function get_entry_sim_speed()::LearningEntry
    return LearningEntry(
        id = :sim_speed,
        trigger = _ -> true,
        priority = 400,
        definition = InGameTutorialDef(
            title = "Simulation Speed and Pausing",
            description = "Learn how to control the simulation speed and pause the game.",
            steps = [
                TutorialStep(
                    heading = "PAUSING",
                    text = tutorial_dedent(
                        "You can pause the game simulation using the 'Pause' button in the top-left corner.\n
                        You can also press the SPACEBAR key.\n
                        Try pausing and unpausing the game now!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        (@atomic :monotonic inputs.flowcalc_shared_state.is_paused) && return nothing
                        return "Pause the simulation using the spacebar or pause button."
                    end,
                ),
                TutorialStep(
                    heading = "SIMULATION SPEED",
                    text = tutorial_dedent(
                        "You can control the simulator speed using the buttons in the top-left corner.\n
                        Click 2X, 4X, or MAX to speed up time, or use the square bracket keys [ and ] to step through speeds.\n
                        Try changing the simulation speed now!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        (inputs.inputstate.sim_speed != SIM_1X) && return nothing
                        return "Change the simulation speed using the speed buttons or bracket keys."
                    end,
                ),
            ],
        ),
    )
end

function get_entry_space_map_intro()::LearningEntry
    return LearningEntry(
        id = :space_map_intro,
        trigger = inputs -> !isnothing(get_space_map_seed(inputs.gamemap)) && get_total_encounter_count(inputs.gamemap) > 0,
        priority = 600,
        definition = InGameTutorialDef(
            title = "Space Map",
            description = "Learn how to navigate the space map.",
            steps = [
                TutorialStep(
                    heading = "OPENING THE SPACE MAP",
                    text = tutorial_dedent(
                        "For your first manoeuvre your target was selected automatically, but going forward you will need to plan your own destinations. \
                        The 'Space Map' is how you choose where to navigate to with your ship. \
                        It shows your current location in space, and any nearby objects.\n
                        Press M to open the space map!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        inputs.inputstate.spacemap_active && return nothing
                        return "Open the space map before proceeding."
                    end,
                ),
                TutorialStep(
                    heading = "TIME WARP CONTROLS",
                    text = tutorial_dedent(
                        "The top left of the space map screen includes your time warp controls. \
                        The distances between objects in space are vast, and it often takes years to reach anything. \
                        Unless you are very patient, you won't get very far waiting in real time. \
                        If your ship is stable and not producing thrust, you can use the time warp controls to pass time.\n
                        Try pressing one of the buttons to advance time a bit!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        t = get_time_years(inputs.gamemap)
                        (!isnothing(t) && t > 0.0) && return nothing
                        return "Use the time warp controls to advance time."
                    end,
                ),
                TutorialStep(
                    heading = "OBJECTS IN SPACE",
                    text = tutorial_dedent(
                        "The pane on the right is your map. \
                        Your ship's current position is represented by the yellow diamond in the centre. \
                        All of the other points are other objects in space that you can manoeuvre to and interact with. \
                        Each object has a velocity vector so you can see where and how fast it's moving. \
                        There are currently three classes of object you will encounter on the map:\n
                        JUMBLED SHIPS are indicated with a circle. These have all the parts to get them up and running but you will need to repair them.\n
                        FUEL CACHES are indicated with a square. These have lots of fuel but no engines. Great for refilling your ship from!\n
                        SCRAP CLUMPS are indicated with a cross. These have a random assortment of sometimes valuable parts, but no fuel.\n
                        You can click these objects to select them and see more information and to see an intercept trajectory, try that now!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        selected_idx = get(inputs.inputstate.gui_inputs, :spacemap_selected_idx, 0)
                        (selected_idx isa Integer && selected_idx > 0) && return nothing
                        return "Select an object on the space map by clicking on it."
                    end,
                ),
                TutorialStep(
                    heading = "DELTA V AND INTERCEPT TRAJECTORIES",
                    text = tutorial_dedent(
                        "Once you have an object selected, you will see the manoeuvre planner plotting an intercept trajectory (the intercept point might be off screen).\n
                        You will also notice some more information and buttons appearing on the left pane. \
                        Delta V is a measure of how much you will need to change your velocity to follow the plotted trajectory. \
                        Higher Delta V manoeuvres require more, and eventually better fuel. \
                        The initial Delta V planned for the manoeuvre is the minimum to complete the intercept, but using the Delta V slider you have the option to expend more Delta V to reach the target faster.\n
                        Under the 'Position & Velocity' section on the left pane, there is a 'Ship delta-V' number. This is an estimate of your ship's delta V based on its mass and fuel stores. \
                        You can use this as a reference to see if you have enough fuel to complete the manoeuvre (and if you plan to use most of it, ensure you will be able to find fuel at your destination!)."
                    ),
                ),
                TutorialStep(
                    heading = "PLANNING A MANOEUVRE",
                    text = tutorial_dedent(
                        "Now let's plan your first real manoeuvre! Select a fuel cache from the map with a relatively small velocity vector. Adjust the delta V slider as you please. \
                        Ensure you have enough delta V to complete the manoeuvre, and then press the 'Plan Manoeuvre' button to proceed!\n
                        Now you know how to plan your movements in the space map. Look for the 'Manoeuvre Execution' tutorial to learn how to actually complete it!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        encounter_points = get_encounter_points(inputs.gamemap)
                        target_idx = isnothing(manoeuvre) ? get(inputs.inputstate.gui_inputs, :spacemap_selected_idx, 0) : manoeuvre.target_encounter_index
                        delta_v = isnothing(manoeuvre) ? get(inputs.inputstate.gui_inputs, :spacemap_delta_v, 0.0) :
                            norm(manoeuvre.approach_burn_dv) + norm(manoeuvre.capture_burn_dv)
                        cancel_prompt = isnothing(manoeuvre) ? "" : "Cancel this manoeuvre and plan a new one. "

                        if !(target_idx isa Integer && 1 <= target_idx <= length(encounter_points))
                            return "$(cancel_prompt)Select a fuel cache on the space map before planning a manoeuvre."
                        end
                        if encounter_points[target_idx].encounter_class != ENCOUNTER_FUEL_CACHE
                            return "$(cancel_prompt)Select a fuel cache as your manoeuvre target."
                        end
                        if delta_v > 0.75 * inputs.gamestate.estimated_min_delta_v
                            return "$(cancel_prompt)The manoeuvre must use no more than 75% of your estimated ship delta-V."
                        end

                        return isnothing(manoeuvre) ? "Plan a manoeuvre to the selected fuel cache by pressing 'Plan Manoeuvre'." : nothing
                    end,
                ),
            ],
        ),
    )
end

function get_entry_manoeuvre_execution()::LearningEntry
    return LearningEntry(
        id = :manoeuvre_execution,
        trigger = function(inputs)
            manoeuvre = get_active_manoeuvre(inputs.gamemap)
            isnothing(manoeuvre) && return false
            return manoeuvre.phase == PHASE_APPROACH_BURN
        end,
        priority = 550,
        definition = InGameTutorialDef(
            title = "Manoeuvre Execution",
            description = "An in-game walkthrough of how to execute a manoeuvre planned in the space map.",
            steps = [
                TutorialStep(
                    heading = "COMPLETE THE APPROACH BURN",
                    text = tutorial_dedent(
                        "In your first manoeuvre you intercepted your target by chance, but now you will need to perform an 'Approach Burn' to put yourself on an intercept course. \n
                        Again, the target burn is indicated by compass and the numeric required delta V vector. \
                        The burn direction should usually be directly to the right, as your ship will 'rotate' to align with the burn direction.\n
                        Use your cold-gas thrusters to perform the approach burn."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        isnothing(manoeuvre) && return "No active manoeuvre found."

                        manoeuvre.phase in (PHASE_COAST, PHASE_CAPTURE_BURN, PHASE_ENCOUNTER_READY) && return nothing
                        return "Complete the approach burn by firing your thrusters."
                    end,
                ),
                TutorialStep(
                    heading = "WAIT FOR INTERCEPT",
                    text = tutorial_dedent(
                        "Now you have completed the approach burn, you are on an intercept course with your target! \
                        Now you have to wait until you reach the target to perform the capture burn. \
                        The space map will provide a 'Wait for Capture Burn' button to help you advance time to the correct point, try clicking that now!\n
                        Proceed to the next step once you have reached the intercept point!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        isnothing(manoeuvre) && return "No active manoeuvre found."

                        current_time = get_time_years(inputs.gamemap)
                        isnothing(current_time) && return "Unable to determine current time."

                        current_time >= manoeuvre.intercept_time && return nothing
                        return "Advance time until the capture burn window is reached."
                    end,
                ),
                TutorialStep(
                    heading = "COMPLETE THE CAPTURE BURN",
                    text = tutorial_dedent(
                        "Now you have intercepted the target you need to perform the 'Capture Burn' to match velocity and dock with it. \
                        Fire your thrusters to execute the indicated burn!\n
                        Once you have completed the burn, your tractor beam activates and pulls you in to dock with the target automatically."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        if !has_active_manoeuvre(inputs.gamemap)
                            has_encountered_ship = any(ship_name -> ship_name != :primary, get_all_ship_names(inputs.gamemap))
                            has_encountered_ship && return nothing
                        end

                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        isnothing(manoeuvre) && return "No active manoeuvre found."

                        manoeuvre.phase == PHASE_ENCOUNTER_READY && return nothing
                        return "Complete the capture burn by firing your engines to decelerate."
                    end,
                ),
                TutorialStep(
                    heading = "SUMMARY",
                    text = tutorial_dedent(
                        "You have now completed your first manoeuvre and docked with another ship! \
                        Take the fuel and parts you need, and then you can continue planning and executing manoeuvres to explore the space map and increase your velocity step by step. \
                        Make sure you are watching your fuel as you go!"
                    ),
                ),
            ],
        ),
    )
end

function get_entry_docking_intro()::LearningEntry
    return LearningEntry(
        id = :docking_intro,
        trigger = inputs -> length(inputs.gamemap.ships) > 1,
        priority = 500,
        definition = InGameTutorialDef(
            title = "Docking",
            description = "Learn about docking with other ships.",
            steps = [
                TutorialStep(
                    heading = "DOCKING INTRODUCTION",
                    text = tutorial_dedent("
                        Now you have manoeuvred to and docked with another ship, you should be able to see the green tractor beam connecting you to the other ship. \
                        Let's learn how you can interact with docked ships!\n
                        You can place pipes between the ships when they are docked, but they must maintain a connection back to a ship at all times!\n
                        There are also some specific interactions you can do to manage docked ships, let's go through those now!"
                    ),
                ),
                TutorialStep(
                    heading = "PRIMARY SHIP AND ACTIONS",
                    text = tutorial_dedent(
                        "Your current main ship is referred to as your 'primary' ship, indicated with the default grey colour.\n
                        Ships have actions much like components, right click on some empty surface on your primary ship to see the available actions.\n
                        All the action buttons are disabled because this is your primary ship. \
                        You can only perform them on other docked ships, which you will see in the next step."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        # Finish once the player has opened a ship action popup targeting the primary ship.
                        popup = inputs.inputstate.action_popup
                        (!isnothing(popup) && popup.target isa ShipPopupTarget && popup.target.ship_name === :primary) && return nothing
                        return "Right-click the surface of your primary ship to open the actions menu."
                    end,
                ),
                TutorialStep(
                    heading = "SWITCHING PRIMARY SHIP",
                    text = tutorial_dedent(
                        "Sometimes you will want to leave your old primary ship behind and switch the new ship you have encountered to your primary. \
                        To do this, select the 'Make Primary' action from the docked ship's actions menu! \
                        You should see the ship surface change to grey, and your tractor beam will originate from that ship instead!\n
                        Now you can switch this whenever you want, so if you don't actually want to switch primary ships right now, you can just switch back to the original one and then proceed to the next step."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        # Finish once a previous primary ship has been retired under the generated old_primary name.
                        has_swapped_primary = any(get_all_ship_names(inputs.gamemap)) do ship_name
                            return startswith(String(ship_name), "##old_primary#")
                        end

                        has_swapped_primary && return nothing
                        return "Right-click the surface of the docked ship, and select 'Make Primary'."
                    end,
                ),
                TutorialStep(
                    heading = "REDOCKING",
                    text = tutorial_dedent(
                        "Sometimes you will want to move your docked ships around relative to each other, for example to make piping them together easier. \
                        You can do this using the 'Redock' action in the ship actions menu to enter redock mode.\n
                        A ghost of your ship's surface will now appear and follow your mouse. \
                        You can place the ship anywhere that is more than 2 tiles away from any other ships!\n
                        If you click again while in a valid location, the ship will move there. \
                        If you don't actually want to move the ship right now, you can press ESC to exit redock mode and then proceed to the next step."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        # Finish once the player has entered redock placement mode for a docked ship.
                        inputstate = inputs.inputstate
                        (placement_state(inputstate) isa PlacementRedockState) && return nothing
                        return "Right-click the docked ship and select 'Redock' to enter redock mode."
                    end,
                ),
                TutorialStep(
                    heading = "UNDOCKING",
                    text = tutorial_dedent(
                        "Sometimes you will want to separate from a docked ship so you aren't dragging dead weight around. \
                        You can do this using the 'Undock' action in the docked ship actions menu. \
                        Note that you can't undo this action, so make sure you are really ready to undock.\n
                        You don't actually need to undock now to finish the tutorial, so just remember how to do it when you are ready!"
                    ),
                )
            ],
        ),
    )
end

function get_entry_mono_propellant_fuel()::LearningEntry
    return LearningEntry(
        id = :mono_propellant_fuel,
        trigger = inputs -> get_wet_mass(inputs.gamemap; fluid = HexFluids.MONOPROP_LIQUID) > 0,
        priority = 700,
        definition = InGameTutorialDef(
            title = "Mono-Propellant Fuel",
            description = "Learn about mono-propellant fuel and its characteristics.",
            steps = [
                TutorialStep(
                    heading = "MONO-PROPELLANT FUEL",
                    text = tutorial_dedent(
                        "Mono-propellant fuel is the first liquid fuel you will encounter. \
                        It is made up of an unstable molecule. It doesn't 'burn' in the traditional sense, but can decompose directly into hot gases, with no oxygen required!\n
                        Mono-propellant can't be used directly in a nozzle in its liquid form, it must first be passed through a 'decomposition chamber' where a catalyst causes it to break down into hot gases.\n
                        Like all liquid fuels, mono-propellant will be most often found in unpressurised tanks, so you will need a pump or to pressurise it to get it flowing.\n
                        Due to its higher temperature exhaust and its higher storage density, mono-propellant is a much more efficient fuel than cold gas. \
                        It is still not as efficient as more complex bipropellant fuels, but it is a good starting point before you encounter those! (and until I implement those!)."),
                ),
            ],
        ),
    )
end

function get_entry_galaxy_escape()::LearningEntry
    return LearningEntry(
        id = :galaxy_escape,
        trigger = inputs -> is_galaxy_escape_unlocked(get_peak_estimated_delta_v(inputs.gamemap)),
        priority = 300,
        definition = InGameTutorialDef(
            title = "Escaping the Galaxy",
            description = "Learn how to prepare for the final burn to escape the galaxy and win the game.",
            steps = [
                TutorialStep(
                    heading = "ESCAPING THE GALAXY",
                    text = tutorial_dedent(
                        "Your goal in RocketPlumber is to escape the galaxy by performing a final, massive burn.\n
                        Press M to open the space map, where you will find the escape button has unlocked at the bottom of the left pane. \
                        You can press it to review what capabilities your ship will require, but you are unlikely to be ready yet!"
                    ),
                ),
            ],
        ),
    )
end

function get_entry_fluid_transfer()::LearningEntry
    return LearningEntry(
        id = :fluid_transfer,
        trigger = inputs -> has_component_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump}),
        priority = 800,
        definition = SandboxTutorialDef(
            title = "Moving liquid with transfer pumps",
            description = "Practise using transfer pumps to refuel a ship.",
            body_text = "Play this interactive sandbox tutorial to learn how to move liquid fuel between ships using electric transfer pumps.",
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_liquid_transfer.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Your primary ship is a fuel hauler but it's currently empty! \
                                Nearby there is another ship with some fuel in it, and a transfer pump. \
                                Let's learn how to use that pump to move fuel and refill your ship!"
                            ),
                        ),
                        TutorialStep(
                            heading = "TRANSFER PUMPS",
                            text = tutorial_dedent(
                                "Unlike gases which are stored under high pressure, liquids can be moved around effectively using transfer pumps. \
                                These pumps cannot support the pressures or flows needed for a rocket engine, but they are perfect for moving liquids around. \
                                They are also electrically powered with an internal battery, so you don't need an external energy source to run them. \
                                You do have to keep an eye on their charge though!"
                            ),
                        ),
                        TutorialStep(
                            heading = "MOVE THE PUMP",
                            text = tutorial_dedent(
                                "Start by moving the pump that's on the top left ship over to the fuel tanker.\n
                                The pump is directional, so ensure the tapered end of the pump is facing towards where you want the fuel to go, which is to the left in this case."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # The transfer pump must be moved from the debris hulk onto the tanker, with its output facing left toward the primary ship.
                                pump_in_place = any(each_component_of_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump})) do placed_component
                                    ship_name = placed_component.ship
                                    ship_name === :primary && return false

                                    is_on_tanker = any(each_component_of_ship(inputs.gamemap, ship_name)) do ship_component
                                        ship_component.component isa ThevininTankCompBehav{LiquidTankBehavFrag}
                                    end
                                    faces_left = placed_component.rotation in (HexFrame.S_NEG, HexFrame.Q_POS, HexFrame.R_NEG)
                                    return is_on_tanker && faces_left
                                end

                                pump_in_place && return nothing
                                return "Move the pump to the fuel tanker and orient it so the tapered end is facing left towards your ship."
                            end,
                        ),
                        TutorialStep(
                            heading = "CONNECT AND USE THE PUMP",
                            text = tutorial_dedent(
                                "Place pipes so the pump is inline between the full tanks on the tanker and the empty tanks on your primary ship.\n                                
                                Now turn on the pump and start transferring fuel! \
                                You can interact with the pump through its right-click actions menu, or you can just left-click it to toggle it on and off.\n
                                The pump isn't always fast, so remember you can control the simulation speed with the ] and [ keys or the menu in the top left! \
                                Wait for your tanks to fill up and then you are done!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # Finish when the primary ship's liquid tanks are effectively full.
                                primary_liquid_tanks = [
                                    placed.component for placed in each_component_of_ship(inputs.gamemap, :primary)
                                    if placed.component isa ThevininTankCompBehav{LiquidTankBehavFrag}
                                ]
                                primary_tanks_full = !isempty(primary_liquid_tanks) && all(primary_liquid_tanks) do tank
                                    return tank.tank.tank.state.charge >= 0.99 * tank.tank.tank.max_charge
                                end

                                primary_tanks_full && return nothing
                                return "Turn on the pump and wait for your tanks to be full."
                            end,
                        ),
                    ],
                ),
            ],
        ),
    )
end

function get_entry_pressure_fed_intro()::LearningEntry
    return LearningEntry(
        id = :pressure_fed_intro,
        trigger = inputs -> has_component_type(inputs.gamemap, PressureFedTankCompBehav),
        priority = 1000,
        definition = SandboxTutorialDef(
            title = "Intro to pressure-fed tanks",
            description = "Learn how to build engines with pressure-fed tanks.",
            body_text = "Play this interactive sandbox tutorial to learn how to use pressure-fed mono-propellant engines.",
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_pressure_fed.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Liquid fuels like mono-propellant don't pressurise themselves in the tank like a gas does. \
                                But often you will already have pressurised gas available on your ship, so why not use that to push the liquid fuel out at pressure? \
                                This is the idea behind pressure-fed engines!\n
                                You can't just do this with any liquid tank though, they aren't built to handle pressure. \
                                This ship includes special pressure-fed tanks built exactly for this purpose. Let's see how to use them!"
                            ),
                        ),
                        TutorialStep(
                            heading = "MOVE DECOMP CHAMBER",
                            text = tutorial_dedent(
                                "Liquid mono-propellant can't be piped directly to a nozzle. \
                                You need a 'decomposition chamber' to convert the liquid into a gas, releasing its stored energy.\n
                                There is a decomposition chamber on the top left of the ship. \
                                Move it down one tile into the gap between the nozzle and the switch. \
                                For decomposition chambers, the wider end is the output, so make sure that is facing towards the nozzle!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                target_coord = TileCoord(-4, 1)
                                placed_component = get_component(inputs.gamemap, target_coord)
                                decomp_in_position = !isnothing(placed_component) &&
                                    placed_component.component isa typeof(BasicDecompChamber) &&
                                    placed_component.rotation == HexFrame.Q_POS

                                decomp_in_position && return nothing
                                return "Move the decomposition chamber into position (-4, 1) with the wider end facing the nozzle."
                            end,
                        ),
                        TutorialStep(
                            heading = "OPEN VALVE",
                            text = tutorial_dedent(
                                "Now the decomposition chamber is in place, let's open the valve connecting it to the pressure-fed tanks. \
                                You can control valves through their action menu, or just by clicking the green button to turn it on!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # small amount of thrust will be generated when the valve is opened
                                norm(inputs.gamestate.thrust) != 0.0 && return nothing
                                return "Open the valve between the pressure-fed tanks and the decomposition chamber"
                            end,
                        ),
                        TutorialStep(
                            heading = "PRESSURISE THE TANKS",
                            text = tutorial_dedent(
                                "Only a tiny amount of fuel is trickling out at this stage, because the tanks haven't been pressurised yet. \
                                Pressure-fed tanks have two sides. The liquid side is on the left and the gas side is on the right.\n
                                The liquid side is already connected in this case, but the gas side is not. \
                                Complete the piping between the cold gas tanks and the gas side of the pressure-fed tanks. \
                                You should see gas flow in to pressurise the tanks, and the output pressure and thrust will increase dramatically as a result!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # ship acceleration will be over 2 if the pressure fed tanks are correctly pressurised
                                norm(inputs.gamestate.acceleration_ship_frame) >= 2.0 && return nothing
                                return "Pressurise the tanks by connecting them to the cold gas tanks, and then open the valve to see the increase in thrust!"
                            end,
                        ),
                        TutorialStep(
                            heading = "EMPTYING THE TANKS",
                            text = tutorial_dedent(
                                "Now you can create thrust with a pressure-fed tank, but another key skill is being able to re-fill them. \
                                First let's wait for the tanks' fuel to run out! \n
                                Remember you can increase the simulation speed with the ] and [ keys to speed this up if you want!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                tanks_empty = all((TileCoord(0, -1), TileCoord(0, 0))) do coord
                                    placed_component = get(get_components(inputs.gamemap), coord, nothing)
                                    !isnothing(placed_component) || return false
                                    placed_component.component isa PressureFedTankCompBehav || return false
                                    return placed_component.component.tank.liquid_state.charge <= 0.0
                                end

                                tanks_empty && return nothing
                                return "Allow the ship to run until fuel runs out in the pressure-fed tanks"
                            end,
                        ),
                        TutorialStep(
                            heading = "RE-FILLING THE TANKS",
                            text = tutorial_dedent(
                                "There are some unpressurised liquid tanks at the bottom of the ship. Pipe those to the liquid side of the pressure-fed tanks to re-fill them. \
                                Nothing will happen yet as the residual gas in the tank is at a higher pressure than the liquid tanks we are trying to fill from. We need to remove that gas first.\n
                                Select 'Vent and seal gas' from the pressure-fed tanks' action menu to vent the remaining gas to space.
                                Now liquid will start to flow in to refill it, allow the tank to refill completely!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                tanks_refilled = all((TileCoord(0, -1), TileCoord(0, 0))) do coord
                                    placed_component = get(get_components(inputs.gamemap), coord, nothing)
                                    !isnothing(placed_component) || return false
                                    placed_component.component isa PressureFedTankCompBehav || return false

                                    tank = placed_component.component.tank
                                    return tank.liquid_state.charge >= 0.98 * tank.max_liquid_charge
                                end

                                tanks_refilled && return nothing
                                return "Follow the instructions to depressurise and refill the tanks"
                            end,
                        ),
                        TutorialStep(
                            heading = "RE-PRESSURISING FULL TANKS",
                            text = tutorial_dedent(
                                "Once the tanks are full you can repressurise them with gas. \
                                Currently the gas port is sealed from your 'Vent and Seal Gas' action, which prevents new gas from flowing in. \
                                First disconnect the liquid side from the unpressurised liquid tanks so you don't push fuel back into them when you repressurise.\n
                                Now use the 'Unseal gas' action to allow the tank to pressurise again. You will see gas flow in and your ship should be generating thrust again!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # ship acceleration will be over 2 if the pressure fed tanks are correctly pressurised
                                norm(inputs.gamestate.acceleration_ship_frame) >= 2.0 && return nothing
                                return "Pressurise the tanks by connecting them to the cold gas tanks, and then open the valve to see the increase in thrust!"
                            end,
                        ),
                    ],
                ),
            ],
        ),
    )
end

function get_entry_turbo_pump_intro()::LearningEntry
    return LearningEntry(
        id = :turbo_pump_intro,
        trigger = inputs -> has_component_type(inputs.gamemap, TurboPumpCompBehav),
        priority = 1200,
        definition = SandboxTutorialDef(
            title = "Intro to turbo-pumps and the tap-off cycle ",
            description = "Learn how to build engines with tap-off cycle turbo-pumps.",
            body_text = "Play this interactive sandbox tutorial to learn how to use turbo-pumped mono-propellant engines.",
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_turbo_pump.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Liquid fuels like mono-propellant don't pressurise themselves in the tank like a gas does. \
                                Turbo-pumps can be used to pressurise the fuel and feed it into the engine, without requiring a pressurising gas like pressure-fed systems.\n
                                It takes a lot of power to move the amount of fuel needed for a rocket engine. \
                                In this turbo-pump, that power is provided by running hot and high energy gas through a turbine on the same shaft as the pump impeller."
                            ),
                        ),
                        TutorialStep(
                            heading = "PLUMB A TAP-OFF CYCLE",
                            text = tutorial_dedent(
                                "For a mono-propellant engine like we are building, a convenient source of hot gas to drive the turbine is the decomposition chamber itself. \
                                This is called a 'tap-off' cycle, where we tap some of the gas that would have gone to the nozzle and send it to the pump's turbine instead.\n
                                There is already a controllable valve connected to the pump's turbine input. \
                                Run some pipes between the output of the decomposition chamber, and the input of that valve."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # if the valve has monoprop gas in its input, then the tap-off cycle is plumbed up correctly
                                valve_input_has_monoprop_gas = any(get_components(inputs.gamemap)) do entry
                                    coord, placed_component = entry
                                    placed_component.component isa StandardValveCompBehav{SteppedSwitchBehavFrag} || return false

                                    valve_input_node = map_element(HexFrame.NODE_Q_NEG, coord, placed_component.rotation)
                                    fluid = get(inputs.derivedmapstate.nodeactualfluids, valve_input_node, nothing)
                                    return fluid == HexFluids.MONOPROP_GAS
                                end

                                valve_input_has_monoprop_gas && return nothing
                                return "Connect the decomposition chamber output to the valve"
                            end,
                        ),
                        TutorialStep(
                            heading = "OPEN THE ADJUSTABLE VALVE",
                            text = tutorial_dedent(
                                "Adjustable valves can be opened by clicking the green arrow, and closed by clicking the red arrow (or through the actions menu). \
                                These valves open in steps, so you have to click a few times to get them fully open.\n
                                Try slowly stepping the valve open. Once the valve is open enough the turbine will start to spin up, as indicated by the green bar! \
                                Note that the turbo-pump has a lot of inertia, so it takes a little while to speed up and slow down.\n
                                Don't open it too far too fast. If that speed indicator bar maxes out, you might damage the turbo-pump!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # ship acceleration will be over 5 if the pump is correctly plumbed and the valve is open enough to get the pump running
                                norm(inputs.gamestate.acceleration_ship_frame) >= 5.0 && return nothing
                                return "Step the valve open to power up the turbo-pump and generate more thrust!"
                            end,
                        ),
                        TutorialStep(
                            heading = "FINAL SUMMARY",
                            text = tutorial_dedent(
                                "This type of engine can produce a lot of thrust, and you don't need to worry about keeping a separate supply of pressurising gas around. \
                                Their main drawbacks are:\n
                                - They are harder to perform fine manoeuvres with due to their inertia\n\
                                - They consume some of the propellant for power in this 'open-cycle' configuration\n
                                They work well as your prime mover engines for bulk acceleration, but you can keep your pressure-fed or cold-gas thrusters for fine adjustments!"
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )
end

"True if the map contains stored bipropellant fuel or oxidiser."
function has_bipropellant_fuel(gamemap::GameMap)::Bool
    has_fuel = get_wet_mass(gamemap; fluid = HexFluids.FUEL_LIQUID) > 0.0
    has_oxidiser = get_wet_mass(gamemap; fluid = HexFluids.OXIDISER_LIQUID) > 0.0
    return has_fuel || has_oxidiser
end

function get_entry_bi_propellant_fuel()::LearningEntry
    return LearningEntry(
        id = :bi_propellant_fuel,
        trigger = inputs -> has_bipropellant_fuel(inputs.gamemap),
        priority = 1250,
        definition = InGameTutorialDef(
            title = "Bi-Propellant Fuel",
            description = "Learn about fuel and oxidiser, and how they work as a bi-propellant.",
            steps = [
                TutorialStep(
                    heading = "BI-PROPELLANT FUEL",
                    text = tutorial_dedent(
                        "Now that you have progressed you will start to encounter fuel and oxidiser intended to be used together as a bi-propellant, by burning them in a combustion chamber. \
                        This releases much more energy than mono-propellant decomposition reactions, which results in hotter exhaust gases and a more efficient engine. \
                        That efficiency comes at the cost of having to carefully manage both propellants, mixing them at the exact ratio required for optimal performance.\n
                        Like mono-propellant, bi-propellants are liquid fuels and need pumps or pressure-fed systems to deliver them to the combustion chamber. \n
                        The hot exhaust gases of well mixed bi-propellant combustions can cause damage to things like turbopump turbines. \
                        Tap-off cycles like we used with mono-propellant engines aren't really feasible. \
                        You'll have to get more creative in sourcing some less hot gases to drive your turbopumps. Google 'Gas Generator Cycle' if you need a hint!"
                    ),
                ),
            ],
        ),
    )
end

function get_entry_bi_propellant_intro()::LearningEntry
    return LearningEntry(
        id = :bi_propellant_intro,
        trigger = inputs -> has_bipropellant_fuel(inputs.gamemap),
        priority = 1260,
        definition = SandboxTutorialDef(
            title = "Bi-Propellant Engines",
            description = "Practise firing a bi-propellant engine and adjusting its mix ratio.",
            body_text = "Use the bi-propellant demo map to experiment with fuel, oxidiser, and adjusting the mix ratio.",
            levels = [
                SandboxTutorialLevel(
                    map_generator = _tutorial_mapgen_biprop_demo.generator,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "START THE OXIDISER FLOW",
                            text = tutorial_dedent(
                                "This ship includes a pressure-fed bi-propellant engine with separate fuel and oxidiser control. \
                                We are going to use it to experiment with how the mixture ratio affects the engine's performance.\n
                                Let's start the flow of oxidiser by opening the oxidiser valve on the bottom."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Open the oxidiser valve by clicking on it!"
                            end,
                        ),
                        TutorialStep(
                            heading = "TUNE THE FUEL FLOW FOR OPTIMAL MIXTURE",
                            text = tutorial_dedent(
                                "The exhaust will currently look black and sooty as the exhaust colour is determined by temperature. \
                                Currently only oxygen is flowing so we are way off an ideal mix!\n
                                Start opening the adjustable valve on the fuel line, and you should see the exhaust get hotter. \
                                Keep adjusting till you find the optimal ratio, noting it is possible to overshoot and end up fuel rich.\n
                                You should aim for the hottest exhaust possible for the best efficiency, unless you deliberately need cooler exhaust for something..."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                hot_exhaust = any(get_components(inputs.gamemap)) do (coord, placed_component)
                                    placed_component.component isa BipropChamberCompBehav || return false
                                    output_node = map_element(HexFrame.NODE_Q_NEG, coord, placed_component.rotation, placed_component.mirrored)
                                    return get(inputs.derivedmapstate.node_temperatures, output_node, 0.0) > 2000.0
                                end
                                hot_exhaust && return nothing
                                return "Adjust the flow of fuel to achieve an exhaust temperature above 2000 K."
                            end,
                        ),
                    ],
                ),
            ],
        ),
    )
end

function get_entry_screenshots_and_recordings()::LearningEntry
    return LearningEntry(
        id = :screenshots_and_recordings,
        trigger = inputs -> get_total_encounter_count(inputs.gamemap) >= 2,
        priority = 1300,
        definition = InGameTutorialDef(
            title = "Screenshots and Recordings",
            description = "Learn how to capture screenshots and recordings in the game.",
            steps = [
                TutorialStep(
                    heading = "CAPTURING SCREENSHOTS AND CLIPS",
                    text = tutorial_dedent(
                        "Rocket Plumber includes a built-in screenshot and recording feature! \
                        It's a great way to share your gameplay moments or capture any bugs you run into.\n
                         - Press F12 to capture a screenshot.\n
                         - Press SHIFT + F12 to start recording a clip, and F12 again to stop.\n
                        "
                    ),
                ),
            ],
        ),
    )
end

function get_entry_editor_intro()::LearningEntry
    return LearningEntry(
        id = :editor_intro,
        trigger = _ -> true,
        priority = 10000,
        definition = InGameTutorialDef(
            title = "What's Possible in Editor Mode",
            description = "Learn how to use editor mode and the developer utilities, which allow you to build and modify ships freely.",
            steps = [
                TutorialStep(
                    heading = "DEV UTILS MENU",
                    text = tutorial_dedent(
                        "The intended way to 'play' the game is to use explorer mode and build your ships from salvaged parts as you go. \
                        However, this being a blank map, there is definitely no way to do that. Instead you can use editor mode and the developer utilities menu! \
                        Editor mode is a special mode that allows you to place components and ship surface freely to build your own ships and test out the simulation. \
                        You can think of it like 'creative mode' in other games. \
                        It allows you to experiment and build without limits, but also removes gameplay constraints and progression.\n
                        Press the '\\' key to open the developer utilities menu.
                        This includes a bunch of tools and options that I use for testing and debugging. \
                        It is a pretty random assortment and I make no promises about the UI being good or even the tools working, so use at your own risk!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        inputs.inputstate.dev_utils_menu_active && return nothing
                        return "Press the \\ key to open the developer utilities menu."
                    end,
                ),
                TutorialStep(
                    heading = "DEV UTILS",
                    text = tutorial_dedent(
                        "I'm not going to explain everything in this menu, but I'll call out some highlights.\n
                        The menu includes an 'Updates Per Second' counter you can use to monitor performance. \
                        It will normally be targeting 60 UPS, but you can see this change if you adjust the simulation speed.\n
                        Under 'Tools' -> 'Modify Space Map' you can initialise a space map on a blank map like this, useful if you want to try and fly around a ship you created in editor mode.\n
                        Under 'Proc Gen' -> 'Generate Encounter' you can create random encounters like you get in the space map, with the ability to tune the type and size. \n
                        And the most important tool in the developer utilities menu is editor mode which will be explained next."
                    ),
                ),
                TutorialStep(
                    heading = "USING EDITOR MODE",
                    text = tutorial_dedent(
                        "Enter editor mode by clicking the checkbox under 'Editor' -> 'Enable Editor Mode'.\n
                        You should see there a few special placement modes you can access by clicking them or pressing the indicated keys:\n
                        - Press 4 to enter 'Delete' mode where you can quickly remove components and pipes by clicking on them.\n
                        - Press 5 to enter 'create tile' mode, which lets you place the different tiles to build a ship. You can cycle through the options with the Z and C keys, and tune their parameters in the 'properties' panel on the right of the screen.\n
                        - Press 6 to enter 'edit surface' mode that lets you click to add or remove ship surface to build on.\n
                        - If you place a pipe, you will also notice an option in the properties panel to switch to the big pipes.\n
                        Try using these new abilities to expand the ship's surface and do whatever you like to create a ship!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        inputs.inputstate.editor_mode && return nothing
                        return "Enter editor mode by opening the developer utilities menu with the '\\' key and enabling editor mode from the editor dropdown."
                    end,
                ),
                TutorialStep(
                    heading = "CONCLUSION",
                    text = tutorial_dedent(
                        "Now you are aware of all the tools at your disposal, even the ones that aren't part of the main gameplay! \
                        These tools shouldn't be required in normal explorer mode play, but they are available in all modes so there are situations where you might end up thinking about it. \
                        For example, right now there's no way to recover from running out of fuel. \
                        This is probably going to be part of a loss condition eventually, but if you want to keep your run going you can always just jump into editor mode and add some fuel tanks to your ship. \
                        And of course, if you are starting with a blank map you can use these tools freely to build and experiment as much as you like!"
                    ),
                ),
            ],
        ),
    )
end

# ===============================================================
# Tutorial Registry
# ===============================================================

"Build and return all learning entries. Filtering to a specific mode is handled by the `LearningProgress` dict."
function get_learning_entries()::Vector{LearningEntry}
    return LearningEntry[
        get_entry_teaser(),
        get_entry_welcome_explorer(),
        get_entry_basic_controls(),
        get_entry_first_burn(),
        get_entry_cold_gas_fuel(),
        get_entry_sim_speed(),
        get_entry_space_map_intro(),
        get_entry_manoeuvre_execution(),
        get_entry_docking_intro(),
        get_entry_mono_propellant_fuel(),
        get_entry_galaxy_escape(),
        get_entry_fluid_transfer(),
        get_entry_pressure_fed_intro(),
        get_entry_turbo_pump_intro(),
        get_entry_bi_propellant_fuel(),
        get_entry_bi_propellant_intro(),
        get_entry_screenshots_and_recordings(),
        get_entry_editor_intro(),
    ]
end

"Tutorial IDs active in explorer mode."
function get_explorer_learning_entry_ids()::Vector{Symbol}
    return Symbol[
        :welcome_explorer,
        :basic_controls,
        :first_burn,
        :cold_gas_fuel,
        :sim_speed,
        :space_map_intro,
        :manoeuvre_execution,
        :docking_intro,
        :mono_propellant_fuel,
        :galaxy_escape,
        :fluid_transfer,
        :pressure_fed_intro,
        :turbo_pump_intro,
        :bi_propellant_fuel,
        :bi_propellant_intro,
        :screenshots_and_recordings,
    ]
end

"Tutorial IDs active on a blank/editor map."
function get_blank_map_learning_entry_ids()::Vector{Symbol}
    return Symbol[
        :editor_intro,
    ]
end

"Sandbox tutorials available from the start menu and sandbox mode."
function get_sandbox_learning_entries()::Vector{LearningEntry}
    return LearningEntry[
        get_entry_teaser(),
        get_entry_basic_controls(),
        get_entry_fluid_transfer(),
        get_entry_pressure_fed_intro(),
        get_entry_turbo_pump_intro(),
        get_entry_bi_propellant_intro(),
    ]
end
