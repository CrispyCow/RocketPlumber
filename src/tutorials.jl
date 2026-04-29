# src/tutorials.jl

const _demo_map_include = isdefined(Main, :Revise) ? includet : include

function _include_demo_map_generator(file_name::String, function_name::Symbol)
    isdefined(Main, function_name) || _demo_map_include(joinpath(dirname(@__FILE__), "demo_maps", file_name))
    return nothing
end

_include_demo_map_generator("mapgen_basicplumbing.jl", :mapgen_basicplumbing)
_include_demo_map_generator("mapgen_bigpipeplumbing.jl", :mapgen_bigpipeplumbing)
_include_demo_map_generator("mapgen_flowdemo.jl", :mapgen_flowdemo)
_include_demo_map_generator("mapgen_controllingcoldgas.jl", :mapgen_controllingcoldgas)
_include_demo_map_generator("mapgen_pressurefedintro.jl", :mapgen_pressurefedintro)
_include_demo_map_generator("mapgen_turbopumpintro2.jl", :mapgen_turbopumpintro2)
_include_demo_map_generator("mapgen_liquidtransfer.jl", :mapgen_liquidtransfer)
_include_demo_map_generator("mapgen_teasership.jl", :mapgen_teasership)


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


# ===============================================================
# Tutorial Helper Functions
# ===============================================================

function has_component_on_tile_matching(gamemap::GameMap, predicate::Function)::Bool
    for ship_name in get_all_ship_names(gamemap)
        for component_on_tile in values(get_all_components(gamemap; ship_name = ship_name))
            predicate(component_on_tile) && return true
        end
    end
    return false
end

function has_component_matching(gamemap::GameMap, predicate::Function)::Bool
    for ship_name in get_all_ship_names(gamemap)
        for component_on_tile in values(get_all_components(gamemap; ship_name = ship_name))
            predicate(component_on_tile.component) && return true
        end
    end
    return false
end

has_component_type(gamemap::GameMap, ::Type{T}) where {T} = has_component_matching(gamemap, component -> component isa T)

function get_components_of_type(gamemap::GameMap, ::Type{T}) where {T}
    matches = Pair{TileCoord, ComponentOnTile}[]

    for ship_name in get_all_ship_names(gamemap)
        for (coord, component_on_tile) in get_all_components(gamemap; ship_name = ship_name)
            component_on_tile.component isa T || continue
            push!(matches, coord => component_on_tile)
        end
    end

    return matches
end

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
                    map_generator = mapgen_teasership,
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
                                "This project is currently in very early development. \
                                The core simulation is implemented, along with a minimal set of components and rocket types (I have ideas for way more!). \
                                The basics of the gameplay loop are also there, where you have to perform manoeuvres to salvage parts and fuel from randomly generated ships.\n
                                However there is still a long way to go, with many features and components yet to be implemented. \
                                There are currently no victory or loss conditions (unless you run out of fuel), and there are no threats or goals driving you to explore and improve.
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
                        This is explorer mode, where your goal is to repair your ship, manoeuvre to other vessels to salvage parts and fuel, and increase your velocity each step of the way.\n
                        The learning system will guide you on how to play, look out for new tips and tutorials as you explore and interact with the game!"
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
                - Press 1 to enter INSPECT mode where you can click on components to see their details and interact with them.\n
                - Press 2 to enter MOVE mode where you can click on components to move them around.\n
                - Press 3 to enter PIPE PLACEMENT mode where you can click to add or delete scrap pipes.\n
                - RIGHT-CLICK on components to access their actions, including an action to delete them."
            ),
            levels = [
                SandboxTutorialLevel(
                    map_generator = mapgen_basicplumbing,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "INTRODUCTION",
                            text = tutorial_dedent(
                                "Welcome to Rocket Plumber! \
                                This tutorial introduces basic controls and plumbing concepts using a cold gas system."
                            ),
                        ),
                        TutorialStep(
                            heading = "BASIC CONTROLS",
                            text = tutorial_dedent(
                                "Use WASD or MIDDLE MOUSE CLICK and drag to pan the view.
                                Use Q/E or SCROLL WHEEL to zoom in and out.
                                Press ESC to open the pause menu.
                                Press number keys 1-3 or click the buttons in the bottom left panel to switch between placement modes."
                            ),
                        ),
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "This map features the most basic rocket engine possible, a cold gas thruster! \
                                It's just a pressurised tank of gas connected directly to a nozzle. The gas flying out the nozzle produces thrust. \
                                This one is not connected yet though, let's fix that!"
                            ),
                        ),
                        TutorialStep(
                            heading = "HOW TO PLACE PIPES AND CONNECT THE NOZZLE",
                            text = tutorial_dedent(
                                "To connect the nozzle you'll need some pipes! Pipes can be placed on the edges between hex tiles, or on the tiles themselves.\n
                                Press 3 to enter Pipe Editing mode. This places 'scrap' pipes. There's always plenty of scrap lying around to make these! \
                                You can press R to rotate the tile-placed pipes. No need to rotate edge-placed ones, there's only one way they can go!\n
                                To actually place the pipes just click. If you misplace an edge pipe, just click on it again to delete it. \
                                If you need to remove a tile pipe, right-click on it to access the actions menu.\n
                                Try to place pipes connecting the tank to the nozzle!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Connect the tank to the nozzle with pipes to produce thrust."
                            end,
                        ),
                    ],
                ),
                SandboxTutorialLevel(
                    map_generator = mapgen_bigpipeplumbing,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Here is another ship with the parts for a cold gas thruster strewn around. Time to plumb it up and get the ship moving!\n
                                With the exception of the 'scrap' pipes, you can't actually create new components for a ship out of thin air. \
                                Instead you have to move around ones you already have. Let's see how to do that!"
                            ),
                        ),
                        TutorialStep(
                            heading = "HOW TO MOVE THE NOZZLE",
                            text = tutorial_dedent(
                                "To move parts (both pipes and tile components) press 2 to enter Move mode.\n
                                Select the part you want to move by clicking on it. \
                                You can now move the part with your mouse, and rotate it by pressing R. \
                                If you have changed your mind you can deselect the part by pressing ESC. \
                                If you are happy with your placement, click and the part will move.\n
                                Start by moving the nozzle so it is in a better spot and pointing towards the left!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                has_left_facing_nozzle = has_component_on_tile_matching(inputs.gamemap, function(component_on_tile)
                                    return component_on_tile.component isa BasicNozzleCompBehav && component_on_tile.rotation == HexFrame.Q_POS
                                end)

                                has_left_facing_nozzle && return nothing
                                return "Move the nozzle to the left and rotate it to point left."
                            end,
                        ),
                        TutorialStep(
                            heading = "PLUMB THE NOZZLE",
                            text = tutorial_dedent(
                                "Once the nozzle is in place, it's time to plumb it to the tanks. \
                                You could do this with 'scrap' pipes like last time, but there are some nicer looking pipes lying around. \
                                Try moving them to make the connection. These pipes are bigger so they have a lower resistance to flow. \
                                If you use them you will get more flow through your nozzle at a higher pressure, so you will be generating more thrust more efficiently!\n
                                Move the pipes to connect the nozzle to the tanks!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Plumb the nozzle to produce thrust."
                            end,
                        ),
                        TutorialStep(
                            heading = "TRY TO MOVE A GAS TANK",
                            text = tutorial_dedent(
                                "While you are here, try moving one of the gas tanks, you might notice this doesn't work! \
                                This is because you can't move a tank that's still got fluid in it, and gas tanks can be quite stubborn to get the last bit out of."
                            ),
                        ),
                        TutorialStep(
                            heading = "VENT THEN MOVE A GAS TANK",
                            text = tutorial_dedent(
                                "You should try and use as much of the fuel as you can, but if you do need a tank empty you can always vent it to space! \
                                If you right-click on the tank you can see the 'actions' panel, and one of those actions is 'vent', which empties its contents and allows it to be moved.\n
                                Try that now, and you'll see you can now move the tank around (and I'll explain what the 'stalled' state means later). \
                                Now you know how to move your ship parts around!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                stalled = has_component_matching(inputs.gamemap, function(comp)
                                    comp isa ThevininTankCompBehav && is_stalled(comp)
                                end)
                                stalled && return nothing
                                return "Right-click a gas tank and use the vent action to empty it."
                            end,
                        ),
                    ],
                ),
                SandboxTutorialLevel(
                    map_generator = mapgen_flowdemo,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "NODE PRESSURE INDICATORS",
                            text = tutorial_dedent(
                                "You might have noticed that the connection nodes at the vertices of the hex tiles are coloured, and wondered what's going on there?\n
                                The colours indicate the fluid pressure at that node, the brighter the colour the higher the pressure! \
                                Black nodes indicate no pressure, or that the node is unused so it has been disconnected to avoid leaks."
                            ),
                        ),
                        TutorialStep(
                            heading = "CONNECT THE NOZZLES",
                            text = tutorial_dedent(
                                "This map is intended to highlight this effect. \
                                There's already a rather chaotic pipe network almost all the way between the tanks and the nozzle so there is not actually that much for you to do. \
                                Just place a few pipes to make the final connection, and enjoy the view! Feel free to try adding or deleting a few of the pipes to see what happens!\n
                                You can hover over nodes to see their pressure, or hover over pipes and nozzles to see their flow rates. \
                                The units might not be what you expect, but that will be explained shortly."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                return "Connect the pipes to produce thrust from a nozzle."
                            end,
                        ),
                        TutorialStep(
                            heading = "FLUID FLOW",
                            text = tutorial_dedent(
                                "It was hinted at in the demo introducing the big pipes, but the modelling of fluid flow is rather detailed in this game. \
                                Fluids will flow from higher pressure nodes to lower pressure nodes. Pipes and other elements pose a resistance to this flow, some more than others. \
                                The drop in pressure from this resistance is proportional to the amount of flow in the pipes, so using good quality pipes is most important for high-flow connections (like the connection to a nozzle)."
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

function get_entry_cold_gas_thrusters()::LearningEntry
    return LearningEntry(
        id = :cold_gas_thrusters,
        trigger = inputs -> has_component_type(inputs.gamemap, SwitchedNozzleCompBehav),
        priority = 300,
        definition = SandboxTutorialDef(
            title = "Controlling cold-gas thrusters",
            description = "Practise placing and controlling switched cold-gas nozzles.",
            body_text = tutorial_dedent(
                "Play this interactive sandbox tutorial to learn how to use and control cold-gas thrusters to provide precise manoeuvring for your ship.\n
                Alternatively, if you just need a refresher on how to use these, just click on a switched nozzle in inspect mode to toggle it on and off, or right-click it for more options!"
            ),
            levels = [
                SandboxTutorialLevel(
                    map_generator = mapgen_controllingcoldgas,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "INTRO TO SWITCHED NOZZLES",
                            text = tutorial_dedent(
                                "This ship is equipped with cold gas tanks, and switched nozzles. \
                                This type of system is not very powerful or efficient, but it is very easy to control and can be useful for fine manoeuvring. \
                                It's also what your starter ship uses, so it's worth learning how to use it!"
                            )
                        ),
                        TutorialStep(
                            heading = "CONTROL THE NOZZLES",
                            text = tutorial_dedent(
                                "To control switched nozzles, you can right-click on them to see their actions, or simply click the nozzle in inspect mode (press 1). \
                                This toggles it between on and off. It does take a small amount of time for the valve to actuate, but this is the fastest-to-control rocket engine you'll ever get! \n
                                Try switching the nozzle on and off (don't leave it on for too long though, you'll need that fuel for the next step!)."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # if velocity has changed from zero but thrust is back to zero, then they have successfully toggled the nozzle on and off at least once
                                norm(get_velocity(inputs.gamemap)) != 0 && norm(inputs.gamestate.thrust) == 0.0 && return nothing
                                return "Toggle a nozzle on and then off by clicking it in inspect mode."
                            end,
                        ),
                        TutorialStep(
                            heading = "HIT A TARGET VELOCITY",
                            text = tutorial_dedent(
                                "Now let's try to leverage the precise control these nozzles are good for to hit a target velocity! \
                                Your current velocity is displayed on the panel in the top left. Try firing your thrusters to get your velocity to 42u/s.\n
                                You can use one nozzle for the best control, or use multiple to speed things up. \
                                It can be helpful to pulse a nozzle in short bursts once you are close to the goal to avoid overshooting. \
                                If you do overshoot, don't stress. You can just fire the nozzles that face the opposite direction!\n
                                Get your velocity to exactly 42u/s and then you are good to go!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # if velocity is close enough to the target, and thrust is zero, then they have achieved the goal
                                isapprox(norm(get_velocity(inputs.gamemap)), 42.0, atol=0.05) && norm(inputs.gamestate.thrust) == 0.0 && return nothing
                                return "Achieve the goal velocity of 42u/s exactly with your nozzles"
                            end,
                        ),
                    ],
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
        trigger = inputs -> !isnothing(get_space_map_seed(inputs.gamemap)),
        priority = 500,
        definition = InGameTutorialDef(
            title = "Space Map",
            description = "Learn how to navigate the space map.",
            steps = [
                TutorialStep(
                    heading = "OPENING THE SPACE MAP",
                    text = tutorial_dedent(
                        "The 'Space Map' is how you choose where to navigate to with your ship. It shows your current location in space, and any nearby objects.\n
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
                        The distances between objects in space are vast, and it often takes years to reach anything. Unless you are very patient, you won't get very far waiting in real time. \
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
                        "The pane on the right that you just saw things move in is your map. Your ship's current position is represented by the yellow diamond in the centre. \
                        All of the other points are other objects in space that you can manoeuvre to and interact with. \
                        Each object has a velocity vector so you can see where it's moving while stationary, and as you step through time you can see them moving relative to you. \
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
                        "Once you have an object selected, you will see some lines coming out of it and your ship. \
                        This is the manoeuvre planner plotting an intercept trajectory (the intercept point might be off screen).\n
                        You will also notice some more information and buttons appearing on the left pane. The most critical of these is the 'Delta V' slider. \
                        Delta V is a measure of how much you will need to change your velocity to follow the plotted trajectory. Higher Delta V manoeuvres require more, and eventually better fuel. \
                        The initial Delta V planned for the manoeuvre is the minimum to complete the intercept, but using the slider you have the option to expend more Delta V to reach the target faster.\n
                        Under the 'Position & Velocity' section on the left pane, there is a 'Ship delta-V' number. This is an estimate of your ship's delta V based on its mass and fuel stores. \
                        You can use this as a reference to see if you have enough fuel to complete the manoeuvre (and if you plan to use most of it, ensure you will be able to find fuel at your destination!)."
                    ),
                ),
                TutorialStep(
                    heading = "PLANNING A MANOEUVRE",
                    text = tutorial_dedent(
                        "Now let's plan your first real manoeuvre! Select an object from the map with a relatively small velocity vector. Adjust the delta V slider as you please. \
                        Ensure you have enough delta V to complete the manoeuvre, and then press the 'Plan Manoeuvre' button to proceed!\n
                        Now you know how to plan your movements in the space map. Look for the 'Manoeuvre Execution' tutorial to learn how to actually complete it!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        has_active_manoeuvre(inputs.gamemap) && return nothing
                        return "Plan a manoeuvre by selecting a target and pressing 'Plan Manoeuvre'."
                    end,
                ),
            ],
        ),
    )
end

function get_entry_manoeuvre_execution()::LearningEntry
    return LearningEntry(
        id = :manoeuvre_execution,
        trigger = inputs -> has_active_manoeuvre(inputs.gamemap),
        priority = 550,
        definition = InGameTutorialDef(
            title = "Manoeuvre Execution",
            description = "An in-game walkthrough of how to execute a manoeuvre planned in the space map.",
            steps = [
                TutorialStep(
                    heading = "MANOEUVRE PHASES",
                    text = tutorial_dedent(
                        "Let's execute your planned manoeuvre! \
                        Manoeuvres are completed by performing two burns of your engines to follow the planned trajectory in the space map. \
                        The first burn is the 'approach burn' where you will do most of the work to put your ship on an intercept course. \
                        The second burn is the 'capture burn' where you will do a smaller burn to remove your intercept velocity.\n
                        The timing of these burns is critical, but the space map has tools to help you!"
                    ),
                ),
                TutorialStep(
                    heading = "APPROACH BURN TIMING",
                    text = tutorial_dedent(
                        "The 'approach burn' is now planned to start immediately.\n
                        As soon as you commit to the manoeuvre, the ship is considered to be in the approach-burn phase and the space map will stop any active time-warp for you.\n
                        If you are still in the space map, close it and go straight to the next step to begin flying the burn."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        isnothing(manoeuvre) && return "No active manoeuvre found."

                        current_time = get_time_years(inputs.gamemap)
                        isnothing(current_time) && return "Unable to determine current time."

                        current_time >= manoeuvre.approach_burn_time && return nothing
                        return "Wait for the manoeuvre to enter its immediate approach-burn phase."
                    end,
                ),
                TutorialStep(
                    heading = "BURN DIRECTION",
                    text = tutorial_dedent(
                        "Now you are ready to perform your first burn! At this point you will need to have repaired your ship, and know how to operate your thrusters. \
                        If you need help with that, look for the 'Repairing your ship' and 'Controlling cold-gas thrusters' tutorials!\n
                        If you are in the burn phase of a manoeuvre, you will see an orange arrow on the compass at the top left of your screen indicating the direction of your burn. \
                        There is also a numerical readout showing the vector components of your remaining burn. \
                        The burn direction should always be directly to the right, as your ship has 'rotated' to align with the burn direction."
                    ),
                ),
                TutorialStep(
                    heading = "COMPLETING THE APPROACH BURN",
                    text = tutorial_dedent(
                        "Now fire your thrusters in the right direction to follow the burn vector. \
                        When you are under thrust a green direction indicator will appear on the compass to show you the acceleration direction. \
                        Keep this aligned with the burn direction until the remaining burn delta-v is zero, and the burn will complete automatically.\n
                        You need to get the burn exactly right, so it helps to pulse your thrusters a bit when you get close to the end. \
                        If you do overshoot, you can just thrust in the opposite direction to cancel it out. \
                        Once the burn is complete, the orange burn direction indicator will disappear, the Manoeuvre Info will update, and you can move on to the next step!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        manoeuvre = get_active_manoeuvre(inputs.gamemap)
                        isnothing(manoeuvre) && return "No active manoeuvre found."

                        manoeuvre.phase in (PHASE_COAST, PHASE_CAPTURE_BURN, PHASE_ENCOUNTER_READY) && return nothing
                        return "Complete the approach burn by firing your engines."
                    end,
                ),
                TutorialStep(
                    heading = "WAIT FOR INTERCEPT",
                    text = tutorial_dedent(
                        "Now you have completed the approach burn, you are on an intercept course with your target! \
                        Now you have to wait until you reach the target to perform the capture burn. \
                        The space map will provide a 'Wait for Capture Burn' button to help you advance time to the correct point, try clicking that now! \
                        You should see the target moving directly towards you on the space map, that's your intercept trajectory at work! \n
                        Once you are at the intercept point, you will need to perform another burn to cancel out your intercept velocity and capture the target. \
                        Proceed to the next step for that!"
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
                    heading = "CAPTURE BURN",
                    text = tutorial_dedent(
                        "Completing the capture burn is pretty much the same as the approach burn, but usually it will require less Delta V. \
                        Your ship will have rotated again so the burn direction is still to the right. \
                        You just need to fire your thrusters in that direction until the burn is complete!\n
                        Once you have completed the burn, you will see your tractor beam activate and pull you in to dock with the target. \
                        Look for the docking tutorial to guide you through interactions with a docked ship!"
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
        priority = 600,
        definition = InGameTutorialDef(
            title = "Docking",
            description = "Learn about docking with other ships.",
            steps = [
                TutorialStep(
                    heading = "DOCKING INTRODUCTION",
                    text = tutorial_dedent("
                        Now you have manoeuvred to and docked with another ship, you should be able to see the green tractor beam connecting you to the other ship. \
                        Let's learn how you can interact with docked ships!\n
                        You can place pipes between the ships when they are docked, but you can't place floating pipes in space! \
                        You must maintain a connection back to a ship at all times, so you need to place pipes one by one extending out from a ship surface.\n
                        There are also some specific interactions you can do to manage docked ships, let's go through those now!"
                    ),
                ),
                TutorialStep(
                    heading = "PRIMARY SHIP",
                    text = tutorial_dedent(
                        "Your current main ship is referred to as your 'primary' ship. \
                        Its surface will always have the default grey colour, and it will be the starting point for all your tractor beams if you have multiple ships docked together.\n
                        Try right-clicking on some empty surface on your primary ship to see the interactions menu. \
                        You'll see the ship name is 'primary' but all the action buttons are disabled. \
                        That's because you can't actually perform any of those actions on your primary ship, you can only perform them on docked ships. \
                        You can close the menu for now, and in the next step we will try with the docked ship!"
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
                        "Sometimes you will want to leave your old primary ship behind and take the new ship you have encountered instead. \
                        You can do this by switching your primary ship through the docking actions menu.\n
                        Try right-clicking on the surface of the docked ship to open the actions menu, and then click 'Make Primary' to make it your new primary ship! \
                        You should see the ship surface change to grey, and your tractor beam now comes out of that ship instead!\n
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
                        You can do this using the 'Redock' action in the ship actions menu.\n
                        Try right-clicking on the surface of your docked ship to open the actions menu, and then click 'Redock' to enter redock mode! \
                        A ghost of your ship's surface will now appear and follow your mouse. \
                        The ghost colour will indicate whether the current location is valid. \
                        You can place the ship anywhere that is more than 2 tiles away from any other ships!\n
                        If you click again while in a valid location, the ship will move there. \
                        If you don't actually want to move the ship right now, you can press ESC to exit redock mode and then proceed to the next step."
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        # Finish once the player has entered redock placement mode for a docked ship.
                        inputstate = inputs.inputstate
                        (inputstate.placementmode == REDOCK && inputstate.redock_state isa RedockModeState) && return nothing
                        return "Right-click the docked ship and select 'Redock' to enter redock mode."
                    end,
                ),
                TutorialStep(
                    heading = "UNDOCKING",
                    text = tutorial_dedent(
                        "Sometimes you will want to separate from a docked ship, say after you have already taken all the fuel and parts you need from it. \
                        You can do this using the 'Undock' action in the ship actions menu. \
                        Note that you can't undo this action, so make sure you are really ready to undock.\n
                        To undock you can right-click on the surface of your docked ship to open the actions menu, and then click 'Undock' to send it away. \
                        You should see the tractor beam turn red and push the ship away. \
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
                    map_generator = mapgen_liquidtransfer,
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
                                They are also electrically powered with an internal battery, so you don't need an external energy source to run them. You do have to keep an eye on their charge though!"
                            ),
                        ),
                        TutorialStep(
                            heading = "MOVE THE PUMP",
                            text = tutorial_dedent(
                                "Now let's start setting up for the fuel transfer! \
                                Start by moving the pump that's on the left ship over to the fuel tanker. \
                                The pump is directional, so ensure the tapered end of the pump is facing towards where you want the fuel to go, which is to the left in this case."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # The transfer pump must be moved from the debris hulk onto the tanker, with its output facing left toward the primary ship.
                                pump_in_place = any(get_components_of_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump})) do entry
                                    coord, component_on_tile = entry
                                    ship_name = find_ship_with_component(inputs.gamemap, coord)
                                    isnothing(ship_name) && return false

                                    is_on_tanker = ship_name != :primary && any(values(get_all_components(inputs.gamemap; ship_name = ship_name))) do ship_component
                                        ship_component.component isa ThevininTankCompBehav && ship_component.component.fluid == HexFluids.MONOPROP_LIQUID
                                    end
                                    faces_left = component_on_tile.rotation in (HexFrame.S_NEG, HexFrame.Q_POS, HexFrame.R_NEG)
                                    return is_on_tanker && faces_left
                                end

                                pump_in_place && return nothing
                                return "Move the pump to the fuel tanker and orient it so the tapered end is facing left towards your ship."
                            end,
                        ),
                        TutorialStep(
                            heading = "PLUMB THE PUMP",
                            text = tutorial_dedent(
                                "Now the pump is in place, we can connect it up! \
                                Place pipes to connect its input on the right to the full tanks on the tanker (if it's not already connected), and connect the output on the left to the empty tanks on your primary ship. \
                                When placing pipes off the ship surfaces to make the inter-ship connection you can't place floating pipes in space! \
                                You must maintain a connection back to a ship at all times, so you need to place the pipes going out one-by-one."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # The plumbing is complete once both transfer-pump ports are connected into the monoprop liquid network.
                                pump_is_plumbed = any(get_components_of_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump})) do entry
                                    coord, component_on_tile = entry
                                    pump_input_node = map_element(HexFrame.NODE_Q_NEG, coord, component_on_tile.rotation)
                                    pump_output_node = map_element(HexFrame.NODE_Q_POS, coord, component_on_tile.rotation)
                                    input_fluid = get(inputs.derivedmapstate.nodeactualfluids, pump_input_node, nothing)
                                    output_fluid = get(inputs.derivedmapstate.nodeactualfluids, pump_output_node, nothing)
                                    return input_fluid == HexFluids.MONOPROP_LIQUID && output_fluid == HexFluids.MONOPROP_LIQUID
                                end

                                pump_is_plumbed && return nothing
                                return "Place pipes to connect the pump between the full tanks on the tanker and the empty tanks on your primary ship."
                            end,
                        ),
                        TutorialStep(
                            heading = "USE THE PUMP",
                            text = tutorial_dedent(
                                "The final step is to turn on the pump and start transferring fuel! \
                                You can left-click the pump in INSPECT mode to toggle it on and off, or right-click for more options. \
                                When the pump is on, the battery indicator will turn yellow and you will see fuel start to move! \
                                The pump isn't always fast, so remember you can control the simulation speed with the ] and [ keys or the menu in the top left!\n
                                Wait for your tanks to fill up, turn off the pump, and then you are done!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # Finish only when the primary ship's liquid tanks are effectively full and the transfer pump has been switched back off.
                                primary_tanks_full = all(values(get_all_components(inputs.gamemap; ship_name = :primary))) do component_on_tile
                                    component = component_on_tile.component
                                    component isa ThevininTankCompBehav || return true
                                    component.fluid == HexFluids.MONOPROP_LIQUID || return true
                                    # Liquid tanks store their charge inside ThevininTankCompBehav -> LiquidTankBehavFrag -> TankBehavFrag.
                                    return component.tank.tank.state.charge >= 0.99 * component.tank.tank.max_charge
                                end

                                pump_is_off = any(get_components_of_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump})) do entry
                                    _, component_on_tile = entry
                                    return get_target_percentage(component_on_tile.component.switch) ≈ 0.0
                                end

                                primary_tanks_full && pump_is_off && return nothing
                                return "Turn on the pump and wait for your tanks to be full, then turn off the pump."
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
                    map_generator = mapgen_pressurefedintro,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Like all liquid fuels, mono-propellant doesn't pressurise itself in the tank like a gas does. \
                                Often you will already have pressurised gas available on your ship, so why not use that to push the liquid fuel out at pressure? \
                                This is the idea behind pressure-fed engines!\n
                                You can't just do this with any liquid tank though, they aren't built to handle pressure. \
                                This ship includes special pressure-fed tanks built exactly for this purpose. Let's see how to use them!"
                            ),
                        ),
                        TutorialStep(
                            heading = "MOVE DECOMP CHAMBER",
                            text = tutorial_dedent(
                                "Firstly, even if you had pressure you can't pipe the liquid fuel directly to a nozzle. \
                                You need a 'decomposition chamber' to convert the liquid into a gas, releasing its stored energy.\n
                                There is a decomposition chamber on the top left of the ship. \
                                Move it down one tile into the gap between the nozzle and the switch. \
                                For decomposition chambers, the wider end is the output, so make sure that is facing towards the nozzle!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                decomp_in_position = any(get_components_of_type(inputs.gamemap, typeof(BasicDecompChamber))) do entry
                                    coord, component_on_tile = entry
                                    return coord == TileCoord(-4, 1) && component_on_tile.rotation == HexFrame.Q_POS
                                end

                                decomp_in_position && return nothing
                                return "Move the decomposition chamber into position (-4, 1) with the wider end facing the nozzle."
                            end,
                        ),
                        TutorialStep(
                            heading = "OPEN VALVE",
                            text = tutorial_dedent(
                                "Now the decomposition chamber is in place, let's open the valve connecting it to the pressure-fed tanks. \
                                You can right-click the valve to access its action menu, or just click its green button in INSPECT mode to turn it on.\n
                                You will notice that only a tiny amount of fuel is trickling out, and that's because we haven't pressurised the tanks yet!"
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
                                "Now let's start working with the pressure-fed tanks themselves. \
                                They have two sides. The liquid side is on the left and the gas side is on the right. \
                                This is visually indicated with the tank shape, each side matches the shape of the corresponding tank type.\n
                                The liquid side is already connected in this case, but the gas side is not. \
                                Complete the piping between the cold gas tanks and the gas side of the pressure-fed tanks. \
                                You should see gas flow in to pressurise the tanks, and the pressure on the output increase as a result!\n
                                Open your valve again if it's not already there, and you should see the thrust increase dramatically as the tanks are at working pressure now!"
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
                                To do that, first let's empty them. Just leave the valve open and wait till the fuel runs out and the tanks stall.
                                Remember you can increase the simulation speed with the ] and [ keys to speed this up if you want!\n
                                The tanks will 'stall' when they run out of fuel. This is just a protective state to stop the gas leaking out when empty. \
                                You can unstall it easily as we will see in the next step."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                pressure_fed_tanks = Dict(get_components_of_type(inputs.gamemap, PressureFedTankCompBehav))
                                tanks_empty = all((TileCoord(0, -1), TileCoord(0, 0))) do coord
                                    component_on_tile = get(pressure_fed_tanks, coord, nothing)
                                    !isnothing(component_on_tile) || return false
                                    return component_on_tile.component.tank.liquid_state.charge <= 0.0
                                end

                                tanks_empty && return nothing
                                return "Allow the ship to run until fuel runs out in the pressure-fed tanks"
                            end,
                        ),
                        TutorialStep(
                            heading = "RE-FILLING THE TANKS",
                            text = tutorial_dedent(
                                "There are some unpressurised liquid tanks at the bottom of the ship. Try piping those to the liquid side of the pressure-fed tanks to re-fill them. \
                                Nothing will happen until you un-stall the tanks by clicking on them in inspect mode, or at least try to.\n
                                You will notice the tank won't unstall, and that's because the tank is still full of pressurised gas. \
                                It's at a higher pressure than the liquid tanks, so it's not going to refill. We need to remove that gas first.\n
                                First disconnect the pressure-fed tanks from the cold gas supply by removing some pipes. \
                                This will stop new gas flowing in, but there is still some in there. \
                                Right-click on the tank to access its action menu and select the 'vent pressurising gas' action to vent the remaining gas to space.
                                Now if you try and unstall the tank it should work, and you can see the liquid start to flow in to refill it! \
                                Allow the tanks to refill completely."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                pressure_fed_tanks = Dict(get_components_of_type(inputs.gamemap, PressureFedTankCompBehav))
                                tanks_refilled = all((TileCoord(0, -1), TileCoord(0, 0))) do coord
                                    component_on_tile = get(pressure_fed_tanks, coord, nothing)
                                    !isnothing(component_on_tile) || return false

                                    tank = component_on_tile.component.tank
                                    return tank.liquid_state.charge >= 0.98 * tank.max_liquid_charge
                                end

                                tanks_refilled && return nothing
                                return "Follow the instructions to depressurise and refill the tanks"
                            end,
                        ),
                        TutorialStep(
                            heading = "UNSTALLING FULL TANKS",
                            text = tutorial_dedent(
                                "Now the tanks are full, you will see that they have stalled again. \
                                Again, this is a safety feature to prevent liquid from leaking out the gas side. \
                                If you simply disconnect them from the unpressurised liquid tanks, and click to unstall them again, they will be ready to go!\n
                                Now you can reconnect the gas supply to the pressure-fed tanks, open the valve, and your ship should be generating thrust again!"
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
                    map_generator = mapgen_turbopumpintro2,
                    steps = TutorialStep[
                        TutorialStep(
                            heading = "MAP GOAL",
                            text = tutorial_dedent(
                                "Like all liquid fuels, mono-propellant doesn't pressurise itself in the tank like a gas does. \
                                Turbo-pumps can be used to pressurise the fuel and feed it into the engine. This ship includes one of these pumps!\n
                                Right now only a little bit of fuel is leaking out, and that's because the pump isn't running yet. Let's see how to start it up!"
                            ),
                        ),
                        TutorialStep(
                            heading = "TAP-OFF CYCLE",
                            text = tutorial_dedent(
                                "It takes a lot of power to move the amount of fuel needed for a rocket engine. \
                                In a conventional turbo-pump like this, that power is provided by burning some of the fuel and running the produced high energy gas over a turbine. \
                                For this rocket, the most convenient source of that gas is the decomposition reaction itself!\n
                                This is called a 'tap-off' cycle, where we route some of the gas that would have gone to the nozzle to the turbine instead. \
                                This type of cycle doesn't work for all fuels as proper combustion produces gases so hot they would melt the turbine, but for mono-propellant decomposition it works great!"
                            ),
                        ),
                        TutorialStep(
                            heading = "PLUMB THE TAP-OFF CYCLE",
                            text = tutorial_dedent(
                                "Let's get this engine running! \
                                There is already a controllable valve connected to the pumps turbine input. \
                                Run some pipes between the output of the decomposition chamber, and the input of that valve."
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # if the valve has monoprop gas in its input, then the tap-off cycle is plumbed up correctly
                                valve_input_has_monoprop_gas = any(get_components_of_type(inputs.gamemap, StandardValveCompBehav)) do entry
                                    coord, component_on_tile = entry
                                    component_on_tile.component isa StandardValveCompBehav{SteppedSwitchBehavFrag} || return false

                                    valve_input_node = map_element(HexFrame.NODE_Q_NEG, coord, component_on_tile.rotation)
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
                                "Now we are plumbed up we just need to open the valve! \
                                Adjustable valves can be opened in INSPECT mode by clicking the green arrow, and closed by clicking the red arrow (or through the right-click menu). \
                                These valves open in steps, so you have to click a few times to get them fully open.\n
                                Try slowly stepping the valve open. Once the valve is open enough the turbine will start to spin up, and the thrust will increase dramatically! \
                                Note that the turbo-pump has a lot of inertia, so it takes a little while to speed up and slow down. \
                                Try experimenting with different valve positions to get some control over the thrust produced by the engine!"
                            ),
                            step_blocker = function(inputs::LearningInputs)
                                # ship acceleration will be over 5 if the pump is correctly plumbed and the valve is open enough to get the pump running
                                norm(inputs.gamestate.acceleration_ship_frame) >= 5.0 && return nothing
                                return "Step the valve open to power up the turbo-pump and generate more thrust!"
                            end,
                        ),
                        TutorialStep(
                            heading = "OPEN CYCLE TURBO-PUMPS",
                            text = tutorial_dedent(
                                "You might also have noticed that the turbo-pump appears to exhaust the gas it used to power its turbine! \
                                This is called an 'open-cycle' and it's the simplest way to build a turbo-pump, but it does mean you lose some of your propellant mass. \
                                Keep this in mind when considering how much delta-V your ship has, the remaining delta-V estimate won't account for this!"
                            ),
                        ),
                        TutorialStep(
                            heading = "FINAL SUMMARY",
                            text = tutorial_dedent(
                                "Now you know how to use a turbo-pump engine!
                                This type of engine can produce a lot of thrust, and you don't need to worry about keeping a separate supply of pressurising gas around. \
                                Their main drawback is that they are harder to perform fine manoeuvres with due to their inertia. \
                                They work well as your prime mover engines for bulk acceleration, and you can keep your pressure-fed or cold-gas thrusters for fine adjustments!"
                            ),
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
        trigger = inputs -> true,
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
                    heading = "EDITOR MODE",
                    text = tutorial_dedent(
                        "The intended way to 'play' the game is to use explorer mode and build your ships from salvaged parts as you go. \
                        However, this being a blank map, there is definitely no way to do that. Instead you can use editor mode! \
                        Editor mode is a special mode that allows you to place components and ship surface freely to build your own ships and test out the simulation. \
                        You can think of it like 'creative mode' in other games. \
                        It allows you to experiment and build without limits, but also removes gameplay constraints and progression.\n
                        Press the grave key (`/~ key next to the 1 on your keyboard) at any time to enter 'editor' mode. \
                        Let's see how to use editor mode and then you can experiment with building your own ship from scratch!"
                    ),
                    step_blocker = function(inputs::LearningInputs)
                        inputs.inputstate.editor_mode && return nothing
                        return "Press the grave key (`/~ key next to the 1 on your keyboard) to enter editor mode."
                    end,
                ),
                TutorialStep(
                    heading = "USING EDITOR MODE",
                    text = tutorial_dedent(
                        "Once you've entered editor mode you should see a few new mode options in the bottom left.\n
                        Press 4 to enter 'Delete' mode where you can quickly remove components and pipes by clicking on them.\n
                        Press 5 to enter 'create tile' mode, which lets you place the different tiles to build a ship. You can cycle through the options with the Z and C keys, and tune their parameters in the 'properties' panel on the right of the screen.\n
                        Press 6 to enter 'edit surface' mode that lets you click to add or remove ship surface to build on.\n
                        If you enter 'pipe' mode, you will also notice an option in the properties panel to switch to the big pipes.\n
                        Try using these new abilities to expand the ships surface and do whatever you like to create a ship!"
                    ),
                ),
                TutorialStep(
                    heading = "DEV UTILS MENU",
                    text = tutorial_dedent(
                        "There is also another hidden option, the 'Developer Utilities' menu. \
                        This includes a bunch of tools and options that I use for testing and debugging. \
                        It is a pretty random assortment and I make no promises about the UI being good or even the tools working, so use at your own risk!
                        You should also consider this like the editor mode in that it bypasses gameplay constraints and is best used only for creative play.\n
                        To toggle the developer utilities menu, press the \\ key!"
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
                        Under 'Proc Gen' -> 'Generate Encounter' you can create random encounters like you get in the space map, with the ability to tune the type and size."
                    ),
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
        get_entry_cold_gas_fuel(),
        get_entry_cold_gas_thrusters(),
        get_entry_sim_speed(),
        get_entry_space_map_intro(),
        get_entry_manoeuvre_execution(),
        get_entry_docking_intro(),
        get_entry_mono_propellant_fuel(),
        get_entry_fluid_transfer(),
        get_entry_pressure_fed_intro(),
        get_entry_turbo_pump_intro(),
        get_entry_screenshots_and_recordings(),
        get_entry_editor_intro(),
    ]
end

"Tutorial IDs active in explorer mode."
function get_explorer_learning_entry_ids()::Vector{Symbol}
    return Symbol[
        :welcome_explorer,
        :basic_controls,
        :cold_gas_fuel,
        :cold_gas_thrusters,
        :sim_speed,
        :space_map_intro,
        :manoeuvre_execution,
        :docking_intro,
        :mono_propellant_fuel,
        :fluid_transfer,
        :pressure_fed_intro,
        :turbo_pump_intro,
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
        get_entry_cold_gas_thrusters(),
        get_entry_fluid_transfer(),
        get_entry_pressure_fed_intro(),
        get_entry_turbo_pump_intro(),
    ]
end
