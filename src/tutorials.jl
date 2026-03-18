# src/tutorials.jl

const _demo_map_include = isdefined(Main, :Revise) ? includet : include

function _include_demo_map_generator(file_name::String, function_name::Symbol)
    isdefined(Main, function_name) || _demo_map_include(joinpath(dirname(@__FILE__), "demo_maps", file_name))
    return nothing
end

_include_demo_map_generator("mapgen_basicplumbing.jl", :mapgen_basicplumbing)
_include_demo_map_generator("mapgen_bigpipeplumbing.jl", :mapgen_bigpipeplumbing)
_include_demo_map_generator("mapgen_flowdemo.jl", :mapgen_flowdemo)
_include_demo_map_generator("mapgen_coldgasthrusters.jl", :mapgen_coldgasthrusters)
_include_demo_map_generator("mapgen_electricpumpintro.jl", :mapgen_electricpumpintro)
_include_demo_map_generator("mapgen_turbopumpintro.jl", :mapgen_turbopumpintro)
_include_demo_map_generator("mapgen_fluidtransfer.jl", :mapgen_fluidtransfer)
_include_demo_map_generator("mapgen_bigshipdemo.jl", :mapgen_bigshipdemo)

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

function has_component_matching(gamemap::GameMap, predicate::Function)::Bool
    for ship_name in get_all_ship_names(gamemap)
        for component_on_tile in values(get_all_components(gamemap; ship_name = ship_name))
            predicate(component_on_tile.component) && return true
        end
    end
    return false
end

has_component_type(gamemap::GameMap, ::Type{T}) where {T} = has_component_matching(gamemap, component -> component isa T)

# ===============================================================
# Sandbox Tutorial Definitions
# ===============================================================

function get_sandbox_learning_entries()::Vector{LearningEntry}
    return LearningEntry[
        LearningEntry(
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
                    - RIGHT CLICK on components to access their actions, including an action to delete them."
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
                                    "Press WASD to pan the view and Q/E to zoom in and out.
                                    Press space to pause the simulation and ESC to open the pause menu.
                                    Press number keys 1-3 or click the buttons to switch between placement modes.
                                    There is a panel in the bottom left showing the modes, you can also click these to switch modes."
                                ),
                            ),
                            TutorialStep(
                                heading = "MAP GOAL",
                                text = tutorial_dedent(
                                    "This map features the most basic rocket engine possible, a cold gas thruster! \
                                    All it is is a pressurised tank of gas connected directly to a nozzle. The gas flying out the nozzle produces thrust. \
                                    This one is not connected yet though, let's fix that!"
                                ),
                            ),
                            TutorialStep(
                                heading = "HOW TO PLACE PIPES AND CONNECT THE NOZZLE",
                                text = tutorial_dedent(
                                    "To connect the nozzle you'll need some pipes! Pipes can be placed on the edges between hex tiles, or on the tiles themselves. \
                                    Press 3 to enter Pipe Editing mode. This places 'scrap' pipes. There's always plenty of scrap lying around to make these! \
                                    You can press R to rotate the tile-placed pipes. No need to rotate edge-placed ones, there's only one way they can go! \
                                    To actually place the pipes just click. Try to place pipes connecting the tank to the nozzle. \
                                    If you misplace a pipe, just click on it again to delete it. \
                                    Once you've made the connection and see thrust, you can complete this step!"
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
                                    "Here is another ship with the parts for a cold gas thruster strewn around. Time to plumb it up and get the ship moving! \
                                    With the exception of the 'scrap' pipes, you can't actually create new components for a ship out of thin air. \
                                    Instead you have to move around ones you already have. Let's see how to do that!"
                                ),
                            ),
                            TutorialStep(
                                heading = "HOW TO MOVE PARTS",
                                text = tutorial_dedent(
                                    "To move parts (both pipes and tile components) press 2 to enter Move mode. Select the part you want to move by clicking on it. \
                                    You can now move the part with your mouse, and rotate it by pressing R. \
                                    If you have changed your mind you can deselect the part by clicking on it again, or pressing ESC to leave Move mode. \
                                    If you are happy with your placement simply click and the part will move!"
                                ),
                            ),
                            TutorialStep(
                                heading = "MOVE AND PLUMB THE NOZZLE",
                                text = tutorial_dedent(
                                    "Start by moving the nozzle so it is in a better spot and pointing towards the left. \
                                    Once you have done that it's time to plumb it to the tanks. \
                                    You could do this with 'scrap' pipes like last time, but there are some nicer looking pipes lying around. \
                                    Try moving them to make the connection. These pipes are bigger so they have a lower resistance to flow. \
                                    If you use them you will get more flow through your nozzle at a higher pressure, so you will be generating more thrust more efficiently!\n
                                    Wire up the nozzle and create some thrust before moving on to the next step!"
                                ),
                                step_blocker = function(inputs::LearningInputs)
                                    norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                    return "Move and plumb the nozzle to produce thrust."
                                end,
                            ),
                            TutorialStep(
                                heading = "TRY TO MOVE A GAS TANK",
                                text = tutorial_dedent(
                                    "While you are here try moving one of the gas tanks, you might notice this doesn't work! \
                                    This is because you can't move a tank that's still got fluid in it, let's see if we can empty it. \
                                    It's going to take a while to empty just with the nozzle. Go to the next task to see how to speed that up!"
                                ),
                            ),
                            TutorialStep(
                                heading = "CHANGE THE SIMULATION SPEED",
                                text = tutorial_dedent(
                                    "Sometimes things are going to take a while, but you can save time by temporarily increasing the simulation speed! \
                                    To do this, on the top left of your screen you can press the 2X, 4X or MAX buttons, and then press 1X to return to normal speed. \
                                    You can also access these same controls by pressing the '[' and ']' keys to slow down and speed up the simulation respectively. \
                                    Try speeding up the simulation to empty the tank faster, and then slow it back down once it seems empty! \
                                    If you try and move the tank again, you'll see it still doesn't work, gas tanks can be quite stubborn to get the last bit out of. \
                                    Let's see how we can fix that! "
                                ),
                                step_blocker = function(inputs::LearningInputs)
                                    inputs.inputstate.sim_speed != SIM_1X && return nothing
                                    return "Change the simulation speed using the speed buttons or bracket keys."
                                end,
                            ),
                            TutorialStep(
                                heading = "VENT THEN MOVE A GAS TANK",
                                text = tutorial_dedent(
                                    "If a tank has some fuel you want to get rid of, you can always empty it by venting to space!
                                    If you right click on the tank you can see the 'actions' panel, and one of those actions is 'vent' which empties its contents, and allows it to be moved.
                                    Try that now, and you'll see you can now move the tank around (and I'll explain what the 'stalled' state means later). \
                                    Now you know how to move your ship parts around, you can mark this as complete!"
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
                                    "You might have noticed that the connection nodes at the vertices of the hex tiles are coloured, and wondered what's going on there? \
                                    The colours indicate the fluid pressure at that node, the brighter the colour the higher the pressure! \
                                    Black nodes indicate no pressure, or that the node is unused so it has been disconnected to avoid leaks."
                                ),
                            ),
                            TutorialStep(
                                heading = "CONNECT THE NOZZLES",
                                text = tutorial_dedent(
                                    "This map is intended to highlight this effect. \
                                    There's already a rather chaotic pipe network almost all the way between the tanks and the nozzle so there is not actually that much for you to do. \
                                    Just place a few pipes to make the final connection, and enjoy the view! Feel free to try adding or deleting a few of the pipes to see what happens. \
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
                                    Fluids will flow from higher pressure nodes to lower pressure nodes. Pipes and other circuit elements pose a resistance to this flow, some more than others. \
                                    The drop in pressure from this resistance is proportional to the amount of flow in the pipes, so using good quality pipes is most important for high-flow connections (like the connection to a nozzle)."
                                ),
                            ),
                            TutorialStep(
                                heading = "PRESSURE AND FLOW CALCULATIONS",
                                text = tutorial_dedent(
                                    "An understanding of this is not necessary to play so mark this task complete at any time, but if you are curious for a peek under the hood:
                                    This might seem a bit familiar for anyone with an electronics background (Ohm's law!). \
                                    That is not a coincidence. In addition to this being a decent approximation of fluid flow in the real world, this is because the game is actually based around a circuit analogy of fluid flow. \
                                    Your pipes and pumps are converted into circuit elements, and the circuit is solved using circuit simulation algorithms that would not be out of place in a SPICE tool to give you your pressures (voltages) and flow rates (current). \
                                    You can get a peek at the actual numbers by hovering over the components, and pipes to see what circuit elements they correspond to! (at least until I hide that in a debug menu)"
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        ),
        # NOTE: I think i want to rework this tutorial with a new map to focus on hitting a precise velocity with the switched nozzles
        LearningEntry(
            id = :cold_gas_thrusters,
            trigger = inputs -> has_component_type(inputs.gamemap, SwitchedNozzleCompBehav),
            priority = 200,
            definition = SandboxTutorialDef(
                title = "Controlling cold-gas thrusters",
                description = "Practise placing and controlling switched cold-gas nozzles.",
                body_text = "Play this interactive sandbox tutorial to learn how to use and control cold-gas thrusters, to provide precise maneuvering for your ship.\n
                             Alternativley, if you just need a refresher on how to use these, just click on a switched nozzle in inspect mode to toggle it on and off, or right click it for more options!",
                levels = [
                    SandboxTutorialLevel(
                        map_generator = mapgen_coldgasthrusters,
                        steps = TutorialStep[
                            TutorialStep(
                                heading = "MOVE AND PLUMB THE NOZZLES",
                                text = tutorial_dedent(
                                    "Cold gas thrusters are the simplest type of rocket engine, they just consist of a pressurised tank of gas connected to a nozzle. \
                                    There are 3 nozzles lying on a separate platform. Start by moving them over near the tank so they all face different directions. \
                                    Then plumb them up with 'scrap' pipes. You'll notice now they don't turn on immediately, that's because they are 'switched' nozzles and they default to off. \
                                    These nozzles only work with cold gas, as it doesn't melt the integrated solenoid valve. Let's turn them on!"
                                ),
                            ),
                            TutorialStep(
                                heading = "CONTROL THE NOZZLES",
                                text = tutorial_dedent(
                                    "To control switched valves, you can right click on them to see their actions, or simply click the nozzle in inspect mode (press 1). \
                                    This toggles it between on and off. It does take a small time for the valve to actuate, but this is the fastest-to-control rocket engine you'll ever get. \
                                    Have a play with your nozzles, watch the cool particle effects, and when you are done you can mark this as complete!"
                                ),
                                step_blocker = function(inputs::LearningInputs)
                                    norm(inputs.gamestate.thrust) > 0.0 && return nothing
                                    return "Toggle a nozzle on by clicking it in inspect mode."
                                end,
                            ),
                        ],
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :electric_pump_intro,
            trigger = inputs -> has_component_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTurboPump}),
            priority = 700,
            definition = SandboxTutorialDef(
                title = "Intro to electric turbo-pumps",
                description = "Learn the basics of mono-propellant engines and electric turbo-pumps.",
                body_text = "Play this interactive sandbox tutorial to learn how to use electrically pumped mono-propellant engines.",
                levels = [
                    SandboxTutorialLevel(
                        map_generator = mapgen_electricpumpintro,
                        steps = TutorialStep[
                            TutorialStep(
                                heading = "INTRODUCTION TO MONO-PROPELLANT",
                                text = tutorial_dedent(
                                    "Time to upgrade and start playing with liquid fuels! \
                                    Liquid fuels offer the potential to produce far more thrust from far less fuel compared to cold gas, but come with some added complexity. \
                                    The simplest liquid fuel is a mono-propellant, so let's start with that. \
                                    Mono-propellants are a type of rocket fuel capable of combusting/decomposing without an additional oxidiser. \
                                    This keeps things simple as you only have one liquid to deal with."
                                ),
                            ),
                            TutorialStep(
                                heading = "DECOMPOSITION CHAMBER",
                                text = tutorial_dedent(
                                    "With liquid fuels the first added complexity is you cannot just plumb them up to a nozzle. \
                                    Nozzles need gas to function, not a liquid. \
                                    You must convert the liquid into a gas first! \
                                    For a mono-propellant you do this with a 'decomposition chamber' which contains a special catalyst that triggers the decomposition reaction and releases a lot of highly energetic gas. \
                                    A lot more gas comes out than the liquid went in, so it is extra important your connection between the decomposition chamber and the nozzle is short and low resistance!"
                                ),
                            ),
                            TutorialStep(
                                heading = "MOVE THE DECOMP CHAMBER INTO POSITION",
                                text = tutorial_dedent(
                                    "This ship has everything set up to create the most basic possible mono-propellant engine. \
                                    Just take the decomposition chamber from the top left and move it into the gap. \
                                    Ensure the wider end is facing the nozzle, that's the side the gas comes out! \
                                    You should see the nozzle start producing some thrust, although it's really not a lot. \
                                    Let's see what's going on there..."
                                ),
                            ),
                            TutorialStep(
                                heading = "PUMPS FOR LIQUID FUELS",
                                text = tutorial_dedent(
                                    "The second added complexity of liquid fuels is that they are not stored at high pressure in their tanks. \
                                    Try hovering over the tank and you can verify that. \
                                    To move fuel at the pressures required for a useful rocket engine you need a pump! \
                                    Thankfully there is one lying nearby."
                                ),
                            ),
                            TutorialStep(
                                heading = "ADD THE PUMP",
                                text = tutorial_dedent(
                                    "To add the pump to the engine, move it into the plumbing between the tank and the decomposition chamber. \
                                    You might have to delete an existing pipe for this. You can press 5 to enter DELETE mode, simply click something to delete it. \
                                    This pump is an electrically powered turbo-pump. \
                                    It takes energy from an internal battery and uses it to pump a liquid at high pressure. \
                                    It won't do anything when first installed, but that is just because you have to click on it in inspect mode to turn it on. \
                                    You can do the same to turn it off. \
                                    The limited energy capacity of these types of electric turbo-pumps makes them less useful for producing bulk thrust, but being easy and fast to shut off they work great for coarse manoeuvring. \
                                    You can now mark this as complete!"
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :turbo_pump_intro,
            trigger = inputs -> has_component_type(inputs.gamemap, TurboPumpCompBehav),
            priority = 800,
            definition = SandboxTutorialDef(
                title = "Intro to tap-off cycle turbo-pumps",
                description = "Learn how to build engines with tap-off cycle turbo-pumps.",
                body_text = "Play this interactive sandbox tutorial to learn how to use turbo-pumped mono-propellant engines.",
                levels = [
                    SandboxTutorialLevel(
                        map_generator = mapgen_turbopumpintro,
                        steps = TutorialStep[
                            TutorialStep(
                                heading = "MAP GOAL",
                                text = tutorial_dedent(
                                    "Here's another ship with a new type of pump! \
                                    It is currently producing some thrust but not as much as it could be, as the pump is not on. \
                                    Let's fix that before all the fuel leaks out (remember you can pause the simulation with the SPACE key so you have some time to read the instructions)."
                                ),
                            ),
                            TutorialStep(
                                heading = "PLUMB THE TAP-OFF CYCLE",
                                text = tutorial_dedent(
                                    "This is a conventional turbo-pump. \
                                    Instead of being powered from a battery it leverages the vast energy available in the burning fuel, by using hot gases to spin a turbine and run the pump. \
                                    We are going to make a rocket engine using the tap-off cycle, where we route a little of the hot gas from the output of the decomposition chamber to the input of the turbine. \
                                    Try plumbing that up now!"
                                ),
                            ),
                            TutorialStep(
                                heading = "CONVENTIONAL TURBO-PUMPS",
                                text = tutorial_dedent(
                                    "This type of engine can produce a lot of thrust, and it won't run out of battery (although it will run out of fuel). \
                                    Use conventional turbo-pumps for your prime-mover engines, where you need a lot of thrust but don't need much control over exactly how much. \
                                    You can mark this complete!"
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :fluid_transfer,
            trigger = inputs -> has_component_type(inputs.gamemap, ElectricPumpCompBehav{ElectricTransferPump}),
            priority = 900,
            definition = SandboxTutorialDef(
                title = "Moving fuel with transfer pumps",
                description = "Practise using transfer pumps and valves to refuel a ship.",
                body_text = "Play this interactive sandbox tutorial to learn how to move liquid fuel around using electric transfer pumps.",
                levels = [
                    SandboxTutorialLevel(
                        map_generator = mapgen_fluidtransfer,
                        steps = TutorialStep[
                            TutorialStep(
                                heading = "MAP GOAL",
                                text = tutorial_dedent(
                                    "This ship has a mono-propellant turbopump engine, but it's run out of fuel and been turned off with a valve. \
                                    There's still a lot of fuel around, so let's move it where it needs to be to get this ship moving again!"
                                ),
                            ),
                            TutorialStep(
                                heading = "START FILLING THE EMPTY TANK",
                                text = tutorial_dedent(
                                    "Start by adding the missing pipe to connect the empty tank with the full ones. \
                                    Nothing will happen because the tank is stalled as it ran out of propellant. \
                                    To un-stall it just click on it in inspect mode. \
                                    If the tank is in a condition where it would fill and not empty, it will return to normal operation. \
                                    Once you click it you should see it start to fill. \
                                    Eventually it will fill until it equalises with the other tanks, but it's going to take a while. \
                                    Let's see how we can speed this up!"
                                ),
                            ),
                            TutorialStep(
                                heading = "USE A TRANSFER PUMP",
                                text = tutorial_dedent(
                                    "To speed things up, and to enable us to fill that tank up all the way, we can use one of the transfer pumps scattered around. \
                                    Try moving one inline with the pipes running between the tanks. \
                                    You will see that the fluid flow stops, this is because the pump is off. \
                                    Just click it in inspect mode to toggle it on and off. \
                                    Now the tank should be filling faster, and it will fill all the way. \
                                    Once the pump motor stops spinning you will know the tank is full!"
                                ),
                            ),
                            TutorialStep(
                                heading = "USING VALVES TO CONTROL FLOW",
                                text = tutorial_dedent(
                                    "Now we have moved the fuel we need to learn how the valve works to use it! \
                                    This valve is adjustable, you can press the green button to open it a little, and the red button to close it a little (actually clicking anywhere above or below the center line works for this). \
                                    The little blue arrows indicate the valve setpoint, and there is a bit of delay as the valve actually moves into the commanded position."
                                ),
                            ),
                            TutorialStep(
                                heading = "CONTROL THE VALVE",
                                text = tutorial_dedent(
                                    "Start by opening the valve one click, you'll see even that is enough to get things flowing. \
                                    Now click a bunch of times to open the valve all the way! \
                                    It won't take long for all the fuel in the close-by tank to be used up, and then your thrust will drop as you lose a lot more pressure over the long pipe run to the far away tanks. \
                                    Let's shut the valve so the tank can refill! \
                                    Click the red button a bunch of times. \
                                    You'll notice the setpoint indicators move quickly but the valve itself takes a while to close. \
                                    It is extra noticeable as it tries to pinch off that last bit of flow. \
                                    This is why conventional turbopump engines are a poor choice for fine thrust control, even with a valve!"
                                ),
                            ),
                            TutorialStep(
                                heading = "EXPERIMENT WITH THE SYSTEM",
                                text = tutorial_dedent(
                                    "Have a play filling and draining the tank, opening and closing the valve and when you are happy you can mark this completed!"
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :big_ship_demo,
            trigger = _ -> false,
            priority = 1200,
            definition = SandboxTutorialDef(
                title = "Whats possible and editor mode",
                description = "Explore a large demonstration ship and experiment with editor mode.",
                body_text = "Sandbox tutorial to explore a large demonstration ship and experiment with editor mode.",
                levels = [
                    SandboxTutorialLevel(
                        map_generator = mapgen_bigshipdemo,
                        steps = TutorialStep[
                            TutorialStep(
                                heading = "FINAL DEMO",
                                text = tutorial_dedent(
                                    "Congratulations, you have learned the basics of how to interact with the Rocket Plumber simulation! \
                                    This next map is just to show off the sort of things that are possible in the simulation, putting all these pieces together. \
                                    Have a play around!"
                                ),
                            ),
                            TutorialStep(
                                heading = "ENTER EDITOR MODE",
                                text = tutorial_dedent(
                                    "Actually one more thing to learn, and it's a secret. \
                                    If you press the grave key (`/~ key next to the 1 on your keyboard) at any time you enter 'editor' mode. \
                                    It's kinda like a developer menu or creative mode, it's not how it's intended you would interact with the simulation once there is a bit more of a game implemented, but it's how I build the maps for this demo, and it's the way you can build ships of your own. \
                                    Here's how it works..."
                                ),
                            ),
                            TutorialStep(
                                heading = "USING EDITOR MODE",
                                text = tutorial_dedent(
                                    "Once you've pressed the grave key (`/~ key next to the 1 on your keyboard) you should see a few new mode options. \
                                    Press 6 to enter 'create tile' mode which lets you place the different tiles to build a ship, you can cycle through the options with the scroll wheel, and tune their parameters in the 'properties' panel on the right of the screen. \
                                    Press 7 to enter 'edit surface' mode that lets you click to add or remove ship surface to build on. \
                                    If you enter 'pipe' mode, you will also notice an option in the properties panel to switch to the big pipes. \
                                    Try using these new abilities to modify the ship!"
                                ),
                            ),
                            TutorialStep(
                                heading = "WRAP UP",
                                text = tutorial_dedent(
                                    "Thanks for playing through the demo. \
                                    You might have noticed something missing, an actual gameplay loop! \
                                    That's why I refer to this as a tech demo, or a simulation rather than an actual game. \
                                    When I started this project it was intended more as a coding experiment to try implementing a fluid system using circuit solving algorithms, an opportunity to build a bit of a larger project in Julia, and an excuse to learn some OpenGL. \
                                    That's why I didn't use a game engine, figuring a lot of this out myself was part of the point. \
                                    This project has been in the works for over a year, and it's now at the point that I think even the core simulation is quite interesting. \
                                    I have a lot of ideas for what I might do as the actual game to build on top of this simulation, but rather than chugging along with that on my own for another few years, I decided to clean up the simulation as-is and release that. \
                                    The ergonomics of the UI are still a little lacking but I've also decided not to redo that until I've nailed down my game concept, hopefully it's not so bad it detracts from the sim. \
                                    There's also a lot more rocket components I want to add, but again I think I should nail down the game first. \
                                    Hopefully I have added just enough of the basic components to convey what's possible in the sim!"
                                ),
                            ),
                            TutorialStep(
                                heading = "DEMO COMPLETION",
                                text = tutorial_dedent(
                                    "Once you are done playing around, you can mark this complete to finish the demo and head back to the main menu. \
                                    I encourage you to try building a rocket engine in a new blank map, in editor mode (and if you do send me a screenshot!). \
                                    If you have any feedback or ideas on where I should take this project from here I'd love to hear it!"
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        ),
    ]
end

# ===============================================================
# In-Game Tutorial Definitions
# ===============================================================

function get_in_game_learning_entries()::Vector{LearningEntry}
    return LearningEntry[
        LearningEntry(
            id = :welcome_explorer,
            trigger = _ -> true,
            priority = 0,
            definition = InGameTutorialDef(
                title = "Welcome to Rocket Plumber",
                description = "A brief welcome to the game's Explorer mode.",
                steps = [
                    TutorialStep(
                        heading = "WELCOME",
                        text = tutorial_dedent(
                            "Welcome to Rocket Plumber, a spacecraft simulation game with a focus on fluid systems and plumbing!\
                            This is the explorer mode, where your goal is to repair your ship, maneuver to other vessels to salvage parts and fuel, and increase your velocity each step of the way\n
                            The learning system will guide you on how to play, look out for new tips and tutorials as you explore and interact with the game!"
                        ),
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :space_map_intro,
            trigger = inputs -> !isnothing(get_space_map_seed(inputs.gamemap)),
            priority = 300,
            definition = InGameTutorialDef(
                title = "Space Map",
                description = "Learn how to navigate the space map.",
                steps = [
                    TutorialStep(
                        heading = "OPENING THE SPACE MAP",
                        text = tutorial_dedent(
                            "The 'Space Map' is how you chose where to navigate to with your ship. It shows your current location in space, and any nearby objects.\n
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
                            The distances between objects in space are vast, and it often takes years to reach anything. Unless you are very patient, you wont get very far waiting in real time. \
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
                            "The pane on the right you just saw things move in is your map. Your ship's current position is represented by the yellow diamond in the center. \
                            All of the other points are other objects in space, that you can maneuver to and interact with. \
                            Each object has a velocity vector so you can see where its moving while stationary, and as you step though time you can see them moving relative to you. \
                            There are currently 3 classes of object you will encounter on the map:\n
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
                            This is the maneuver planner plotting an intercept trajectory (the intercept point might be off screen).\n
                            You will also notice some more information and buttons appearing on the left pane. The most critical of these in the 'Delta V' slider. \
                            Delta V is a measure of how much you will need to change your velocity to follow the plotted trajectory. Higher Delta V maneuvers require more, and eventually better fuel.\
                            The initial Delta V planned for the maneuver is the minimum to complete the intercept, but using the slider you have the option to expend more Delta V to reach the target faster.
                            Under the 'Position & Velocity' section on the left pane, there is a 'Ship delta-V' number, this is estimate of your ship's delta V based on its mass and fuel stores. \
                            You can use this as a reference to see if you have enough fuel to complete the maneuver (and if you plan to use most of it, ensure you will be able to find fuel at your destination!)."
                        ),
                    ),
                    TutorialStep(
                        heading = "PLANNING A MANOEUVRE",
                        text = tutorial_dedent(
                            "Now lets plan your first real maneuver! Select an object from the map with a relativley small velocity vector. Adjust the delta V slider as you please. \
                            Ensure you have enough delta V to complete the maneuver, and then press the 'Plan Maneuver' button to proceed!\
                            Now you know how to plan your movements in the space map. Look for the 'Manoeuvre Execution' tutorial to learn how to actually complete it!"
                        ),
                        step_blocker = function(inputs::LearningInputs)
                            has_active_manoeuvre(inputs.gamemap) && return nothing
                            return "Plan a manoeuvre by selecting a target and pressing 'Plan Manoeuvre'."
                        end,
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :manoeuvre_execution,
            trigger = inputs -> has_active_manoeuvre(inputs.gamemap),
            priority = 1100,
            definition = InGameTutorialDef(
                title = "Manoeuvre Execution",
                description = "An in-game walkthrough of how to execute a manoeuvre planned in the space map.",
                steps = [
                    TutorialStep(
                        heading = "MANOEUVRE PHASES",
                        text = tutorial_dedent(
                            "Lets execute your planned manoeuvre! \
                            Manoeuvres are completed by performing 2 burns of your engines, to follow the planned trajectory in the space map. \
                            The first burn is the 'main burn' where you will do most of the work to match the targets velocity and put your ship on an intercept course. \
                            The second burn is the 'capture burn' where you will do a smaller burn remove your intercept velocity.\n
                            The timing of these burns is critical, but the space map has tools to help you!"
                        ),
                    ),
                    TutorialStep(
                        heading = "MAIN BURN TIMING",
                        text = tutorial_dedent(
                            "The 'main burn' is always performed at your closest approach to the target.\n
                            If the target is moving away from you, the closest approach will be right now and you can execute the burn straight away!\n
                            If the target is moving towards you, you will have to wait until until it reaches it closest point. \
                            When you are waiting for this time, the space map will provide a 'Wait for Closest Approach' button that you can click to automatically advance time to the correct point. \
                            Try clicking that button now, or if you are already at closest approach you can go straight to the next step!"
                        ),
                        step_blocker = function(inputs::LearningInputs)
                            manoeuvre = get_active_manoeuvre(inputs.gamemap)
                            isnothing(manoeuvre) && return "No active manoeuvre found."

                            current_time = get_time_years(inputs.gamemap)
                            isnothing(current_time) && return "Unable to determine current time."

                            current_time >= manoeuvre.closest_approach_time && return nothing
                            return "Advance time until the main burn window is reached."
                        end,
                    ),
                    TutorialStep(
                        heading = "BURN DIRECTION",
                        text = tutorial_dedent(
                            "Now you are ready to perform your first burn! At this point you will need to have repaired you ship, and know how to operate your thrusters. \
                            If you need help with that, look for the 'Repairing your ship' and 'Controlling cold-gas thrusters' tutorials!\n
                            If you are in the burn phase of a manoeuvre, you will see an orange arrow on the compass at the top left of your screen indicating the direction of your burn. \
                            There is also a numerical readout showing the vector components of you remaining burn. \
                            The burn direction should always be directly to the right, as your ship has 'rotated' to align with the burn direction."
                        ),
                    ),
                    TutorialStep(
                        heading = "COMPLETING THE MAIN BURN",
                        text = tutorial_dedent(
                            "Now fire you thrusters in the right direction to follow the burn vector. \
                            When you are under thrust a green direction indicator will appear on the compass to show you the acceleration direction. \
                            Keep this aligned with the burn direction until the remaining burn delta-v is zero, and the burn will complete automatically.\n
                            You need to get the burn exactly right, so it helps to pulse your thrusters a bit when you get close to the end. \
                            If you do overshoot, you can just trust in the opposite direction to cancel it out. \
                            Once the burn is complete, the orange burn direction indicator will disappear, the Manoeuvre Info will update, and you can move on to the next step!"
                        ),
                        step_blocker = function(inputs::LearningInputs)
                            manoeuvre = get_active_manoeuvre(inputs.gamemap)
                            isnothing(manoeuvre) && return "No active manoeuvre found."

                            manoeuvre.phase in (PHASE_COAST, PHASE_DECEL_BURN, PHASE_ENCOUNTER_READY) && return nothing
                            return "Complete the main burn by firing your engines."
                        end,
                    ),
                    TutorialStep(
                        heading = "WAIT FOR INTERCEPT",
                        text = tutorial_dedent(
                            "Now you have completed the main burn, you are on an intercept course with your target! \
                            Now you have to wait until you reach the target to perform the capture burn. \
                            Just like with the wait for closest approach, the space map will provide a 'Wait for Intercept' button to help you advance time to the correct point, try clicking that now! \
                            You should see the target moving directly towards you on the space map, thats your intercept trajectory at work! \n
                            Once you are at the intercept point, you will need to perform another burn to cancel out your intercept velocity and capture the target. \
                            Proceed to the next step to for that!"
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
                            "Completing the capture burn is pretty much the same as the main burn, but usually it will require less Delta V. \
                            Your ship will have rotated again so the burn direction is still to the right. \
                            You just need to fire your thrusters in that direction until the burn is complete!\n
                            Once you have completed the burn, you will see your tractor beam activate and pull you in to dock with the target. \
                            Look for the docking tutorial to guide you thorugh interactions with a docked ship.\n
                            You have now completed your first manoeuvre and docked with another ship! \
                            Take the fuel and parts you need, and then you can continue planning and executing manoeuvres to explore the space map and increase your velocity step by step. \
                            Make sure you are watching your fuel as you go!"
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
                ],
            ),
        ),
        LearningEntry(
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
                            You can also use press the SPACEBAR key.\n
                            Try pausing and unpausing the game now now!"
                        ),
                        step_blocker = function(inputs::LearningInputs)
                            (@atomic :monotonic inputs.flowcalc_shared_state.is_paused) && return nothing
                            return "Pause the simulation using the spacebar or pause button."
                        end,
                    ),
                    TutorialStep(
                        heading = "SIMULATION SPEED",
                        text = tutorial_dedent(
                            "You can control simulator speed using the buttons in the top-left corner.\n
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
        ),
        LearningEntry(
            id = :cold_gas_fuel,
            trigger = inputs -> get_wet_mass(inputs.gamemap; fluid = HexFluids.COLD_GAS) > 0,
            priority = 500,
            definition = InGameTutorialDef(
                title = "Cold Gas Fuel",
                description = "Learn about cold gas fuel and its characteristics.",
                steps = [
                    TutorialStep(
                        heading = "TODO_HEADING",
                        text = tutorial_dedent(
                            "Cold gas is the simplest type of rocket fuel, it's just a tank of inert gas.
                            The gas is stored at high pressure, so you don't need a pump to make an engine, just release it though a nozzle!.\n
                            Cold gas is not a very efficient fuel. There is only so much energy in a pressurised tank of gas, compared to the chemical energy in a tank of liquid fuel. \
                            Its main advantage is that the gas is well... cold... so it's not going to melt your valve like the glowing hot exhaust of a chemical rocket might. \
                            This means you can use simple switched nozzles to control you thrust, which turn on and off really quickly.\n
                            Refilling cold gas tanks is also easy, connect empty tanks to full ones with pipes and the gas will flow to equalise the pressure, but you will always be leaving some behind.\n
                            Overall cold gas a great choice for fine manoeuvring, but once you find more efficient liquid fuels you will probably want to switch to those for your main engines."
                        ),
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :docking_intro,
            trigger = inputs -> length(inputs.gamemap.ships) > 1,
            priority = 600,
            definition = InGameTutorialDef(
                title = "Docking",
                description = "Learn about docking with other ships.",
                steps = [
                    TutorialStep(
                        heading = "A Ship Has Docked With Yours",
                        text = tutorial_dedent("[Placeholder: A ship has docked with yours]"),
                    ),
                    TutorialStep(
                        heading = "Interacting With the Docked Ship",
                        text = tutorial_dedent("[Placeholder: Interacting with the docked ship]"),
                    ),
                    TutorialStep(
                        heading = "Undocking and Departure",
                        text = tutorial_dedent("[Placeholder: Undocking and departure]"),
                    ),
                ],
            ),
        ),
        LearningEntry(
            id = :mono_propellant_fuel,
            trigger = inputs -> get_wet_mass(inputs.gamemap; fluid = HexFluids.MONOPROP_LIQUID) > 0,
            priority = 1000,
            definition = InGameTutorialDef(
                title = "Mono-Propellant Fuel",
                description = "Placeholder description for mono-propellant fuel tutorial.",
                steps = [
                    TutorialStep(
                        heading = "Mono-Propellant Fuel",
                        text = tutorial_dedent("[Placeholder: mono-propellant fuel tutorial text]"),
                    ),
                ],
            ),
        ),
    ]
end

# ===============================================================
# Tutorial Registry
# ===============================================================

"Build and return the complete tutorial registry."
function get_learning_entries()::Vector{LearningEntry}
    return vcat(get_sandbox_learning_entries(), get_in_game_learning_entries())
end