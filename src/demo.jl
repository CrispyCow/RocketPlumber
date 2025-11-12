# ===============================================================
# Struct Definitions
# ===============================================================

"holds a demo level map and associated hint data"
@kwdef struct DemoLevel
    map::GameMap
    hint::HintData
end

# ===============================================================
# Demo Levels
# ===============================================================

# Formatting paradigm for hint text:
# - Each paragraph becomes a separate string in the hints vector
# - Within each string, sentences are placed on separate lines
# - Use backslash (\) at the end of lines to escape the newline character
# - Use dedent() to remove leading whitespace from multi-line strings

dedent(s::AbstractString) = replace(s, r"^\s+"m => "")

# Use includet if Revise is loaded (development), otherwise use include (production)
const _demo_include = isdefined(Main, :Revise) ? includet : include

_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_basicplumbing.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_bigpipeplumbing.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_flowdemo.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_coldgasthrusters.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_electricpumpintro.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_turbopumpintro.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_fluidtransfer.jl"))
_demo_include(joinpath(dirname(@__FILE__), "demo_maps", "mapgen_bigshipdemo.jl"))

function get_demo_vector()::Vector{DemoLevel}

    basic_controls_and_plumbing_demo::DemoLevel = DemoLevel(
        map = mapgen_basicplumbing(),
        hint = HintData(
            title = "Basic Controls and Plumbing",
            hints = [
                dedent(
                    "[1/4] INFO: INTRODUCTION
                Welcome to Rocket Plumber! \
                This tutorial introduces basic controls and plumbing concepts using a cold gas system."
                ),

                dedent(
                    "[2/4] INFO: BASIC CONTROLS
                Press WASD to pan the view and Q/E to zoom in and out.
                Press space to pause the simulation and ESC to open the pause menu.
                Press number keys 1-4 or click the buttons to switch between placement modes.
                There is a panel in the bottom left showing the modes, you can also click these to switch modes."
                ),

                dedent(
                    "[3/4] INFO: MAP GOAL
                This map features the most basic rocket engine possible, a cold gas thruster! \
                All it is is a pressurised tank of gas connected directly to a nozzle. The gas flying out the nozzle produces thrust. \
                This one is not connected yet though, let's fix that!"
                ),

                dedent(
                    "[4/4] INFO AND TASK: HOW TO PLACE PIPES AND CONNECT THE NOZZLE
                To connect the nozzle you'll need some pipes! Pipes can be placed on the edges between hex tiles, or on the tiles themselves. \
                Press 3 to enter Pipe Placement mode. This places 'scrap' pipes. There's always plenty of scrap lying around to make these! \
                You can press R to rotate the tile-placed pipes. No need to rotate edge-placed ones, there's only one way they can go! \
                To actually place the pipes just click. Try to place pipes connecting the tank to the nozzle. Once you see thrust, mark this complete!"
                ),
            ]
        )
    )

    big_pipe_plumbing_demo::DemoLevel = DemoLevel(
        map = mapgen_bigpipeplumbing(),
        hint = HintData(
            title = "Getting moving with Big Pipes",
            hints = [
                dedent(
                    "[1/4] INFO: MAP GOAL
                Here is another ship with the parts for a cold gas thruster strewn around. Time to plumb it up and get the ship moving! \
                With the exception of the 'scrap' pipes, you can't actually create new components for a ship out of thin air. \
                Instead you have to move around ones you already have. Let's see how to do that!"
                ),

                dedent(
                    "[2/4] INFO: HOW TO MOVE PARTS
                To move parts (both pipes and tile components) press 2 to enter Move mode. Select the part you want to move by clicking on it. \
                You can now move the part with your mouse, and rotate it by pressing R. \
                If you have changed your mind you can deselect the part by clicking on it again, or pressing ESC to leave Move mode. \
                If you are happy with your placement simply click and the part will move!"
                ),

                dedent(
                    "[3/4] TASK: MOVE AND PLUMB THE NOZZLE
                Start by moving the nozzle so it is in a better spot and pointing towards the left. \
                Once you have done that it's time to plumb it to the tanks. \
                You could do this with 'scrap' pipes like last time, but there are some nicer looking pipes lying around. \
                Try moving them to make the connection. These pipes are bigger so they have a lower resistance to flow. \
                If you use them you will get more flow through your nozzle at a higher pressure, so you will be generating more thrust more efficiently!"
                ),

                dedent(
                    "[4/4] TASK: TRY TO MOVE A GAS TANK
                While you are here try moving one of the gas tanks, you might notice this doesn't work! \
                This is because you can't move a tank that's still got fluid in it. \
                You will have to use the fuel first (or find another way to move it around, stay tuned). \
                If you waited until all the gas has been used up you will see you can now move the tank (although I'd take my word for it, that will take a while). \
                Now you know how to move your ship parts around, you can mark this as complete!"
                ),
            ]
        )
    )

    flow_demo::DemoLevel = DemoLevel(
        map = mapgen_flowdemo(),
        hint = HintData(
            title = "The basics of pressure and flow",
            hints = [
                dedent(
                    "[1/4] INFO: NODE PRESSURE INDICATORS
                You might have noticed that the connection nodes at the vertices of the hex tiles are coloured, and wondered what's going on there? \
                The colours indicate the fluid pressure at that node, the brighter the colour the higher the pressure! \
                Black nodes indicate no pressure, or that the node is unused so it has been disconnected to avoid leaks."
                ),

                dedent(
                    "[2/4] TASK: CONNECT THE NOZZLES
                This map is intended to highlight this effect. \
                There's already a rather chaotic pipe network almost all the way between the tanks and the nozzle so there is not actually that much for you to do. \
                Just place a few pipes to make the final connection, and enjoy the view! Feel free to try adding or deleting a few of the pipes to see what happens. \
                You can enter inspect mode by pressing 1, and hover over nodes to see their pressure, or hover over pipes and nozzles to see their flow rates. \
                The units might not be what you expect, but that will be explained shortly."
                ),

                dedent(
                    "[3/4] INFO: FLUID FLOW
                It was hinted at in the demo introducing the big pipes, but the modelling of fluid flow is rather detailed in this game. \
                Fluids will flow from higher pressure nodes to lower pressure nodes. Pipes and other circuit elements pose a resistance to this flow, some more than others. \
                The drop in pressure from this resistance is proportional to the amount of flow in the pipes, so using good quality pipes is most important for high-flow connections (like the connection to a nozzle)."
                ),

                dedent(
                    "[4/4] INFO: PRESSURE AND FLOW CALCULATIONS
                An understanding of this is not necessary to play so mark this task complete at any time, but if you are curious for a peek under the hood:
                This might seem a bit familiar for anyone with an electronics background (Ohm's law!). \
                That is not a coincidence. In addition to this being a decent approximation of fluid flow in the real world, this is because the game is actually based around a circuit analogy of fluid flow. \
                Your pipes and pumps are converted into circuit elements, and the circuit is solved using circuit simulation algorithms that would not be out of place in a SPICE tool to give you your pressures (voltages) and flow rates (current). \
                You can get a peek at the actual numbers by entering inspect mode (press 1) and hovering over the components, and pipes to see what circuit elements they correspond to!"
                ),
            ]
        )
    )

    cold_gas_thrusters_demo::DemoLevel = DemoLevel(
        map = mapgen_coldgasthrusters(),
        hint = HintData(
            title = "Controlling cold-gas thrusters",
            hints = [
                dedent(
                    "[1/3] INFO: COLD GAS THRUSTERS
                Cold gas thrusters are actually pretty terrible rocket engines. \
                There is only so much energy in a pressurised tank of gas, compared to the chemical energy in a tank of liquid fuel. \
                Their main advantage is that they are easy to switch and control. The gas is already under pressure so you don't need any pumps, just a valve. \
                And the gas is well... cold... so it's not going to melt your valve like the glowing hot exhaust of a chemical rocket. Let's see this in action!"
                ),

                dedent(
                    "[2/3] TASK: MOVE AND PLUMB THE NOZZLES
                There are 3 nozzles lying on a separate platform. Start by moving them over near the tank so they all face different directions. \
                Then plumb them up with 'scrap' pipes. You'll notice now they don't turn on immediately, that's because they are 'switched' nozzles and they default to off. \
                These nozzles only work with cold gas, as it doesn't melt the integrated solenoid valve. Let's turn them on!"
                ),

                dedent(
                    "[3/3] TASK: CONTROL THE NOZZLES
                To control switched valves, press 1 to enter inspect mode and then simply click the nozzle. \
                This toggles it between on and off. It does take a small time for the valve to actuate, but this is the fastest-to-control rocket engine you'll ever get. \
                Have a play with your nozzles, watch the cool particle effects, and when you are done you can mark this as complete!"
                ),
            ]
        )
    )

    electric_pump_intro::DemoLevel = DemoLevel(
        map = mapgen_electricpumpintro(),
        hint = HintData(
            title = "Introduction to mono propellant and electric turbo-pumps",
            hints = [
                dedent(
                    "[1/5] INFO: INTRODUCTION TO MONO-PROPELLANT
                Time to upgrade and start playing with liquid fuels! \
                Liquid fuels offer the potential to produce far more thrust from far less fuel compared to cold gas, but come with some added complexity. \
                The simplest liquid fuel is a mono-propellant, so let's start with that. \
                Mono-propellants are a type of rocket fuel capable of combusting/decomposing without an additional oxidiser. \
                This keeps things simple as you only have one liquid to deal with."
                ),

                dedent(
                    "[2/5] INFO: DECOMPOSITION CHAMBER
                With liquid fuels the first added complexity is you cannot just plumb them up to a nozzle. \
                Nozzles need gas to function, not a liquid. \
                You must convert the liquid into a gas first! \
                For a mono-propellant you do this with a 'decomposition chamber' which contains a special catalyst that triggers the decomposition reaction and releases a lot of highly energetic gas. \
                A lot more gas comes out than the liquid went in, so it is extra important your connection between the decomposition chamber and the nozzle is short and low resistance!"
                ),

                dedent(
                    "[3/5] TASK: MOVE THE DECOMP CHAMBER INTO POSITION
                This ship has everything set up to create the most basic possible mono-propellant engine. \
                Just take the decomposition chamber from the top left and move it into the gap. \
                Ensure the wider end is facing the nozzle, that's the side the gas comes out! \
                You should see the nozzle start producing some thrust, although it's really not a lot. \
                Let's see what's going on there..."
                ),

                dedent(
                    "[4/5] INFO: PUMPS FOR LIQUID FUELS
                The second added complexity of liquid fuels is that they are not stored at high pressure in their tanks. \
                Try hovering over the tank in inspect mode and you can verify that. \
                To move fuel at the pressures required for a useful rocket engine you need a pump! \
                Thankfully there is one lying nearby."
                ),

                dedent(
                    "[5/5] TASK: ADD THE PUMP
                To add the pump to the engine, move it into the plumbing between the tank and the decomposition chamber. \
                You might have to delete an existing pipe for this. You can press 4 to enter DELETE mode, simply click something to delete it. \
                This pump is an electrically powered turbo-pump. \
                It takes energy from an internal battery and uses it to pump a liquid at high pressure. \
                It won't do anything when first installed, but that is just because you have to click on it in inspect mode to turn it on. \
                You can do the same to turn it off. \
                The limited energy capacity of these types of electric turbo-pumps makes them less useful for producing bulk thrust, but being easy and fast to shut off they work great for coarse manoeuvring. \
                You can now mark this as complete!"
                ),
            ]
        )
    )

    conv_turbo_pumps::DemoLevel = DemoLevel(
        map = mapgen_turbopumpintro(),
        hint = HintData(
            title = "Introduction to tap-off cycle turbo-pumps",
            hints = [
                dedent(
                    "[1/3] INFO: MAP GOAL
                Here's another ship with a new type of pump! \
                It is currently producing some thrust but not as much as it could be, as the pump is not on. \
                Let's fix that before all the fuel leaks out (remember you can pause the simulation with the SPACE key so you have some time to read the instructions)."
                ),

                dedent(
                    "[2/3] TASK: PLUMB THE TAP-OFF CYCLE
                This is a conventional turbo-pump. \
                Instead of being powered from a battery it leverages the vast energy available in the burning fuel, by using hot gases to spin a turbine and run the pump. \
                We are going to make a rocket engine using the tap-off cycle, where we route a little of the hot gas from the output of the decomposition chamber to the input of the turbine. \
                Try plumbing that up now!"
                ),

                dedent(
                    "[3/3] INFO: CONVENTIONAL TURBO-PUMPS
                This type of engine can produce a lot of thrust, and it won't run out of battery (although it will run out of fuel). \
                Use conventional turbo-pumps for your prime-mover engines, where you need a lot of thrust but don't need much control over exactly how much. \
                You can mark this complete!"
                ),
            ]
        )
    )

    fluid_transfer::DemoLevel = DemoLevel(
        map = mapgen_fluidtransfer(),
        hint = HintData(
            title = "Moving fuel around with transfer pumps",
            hints = [
                dedent(
                    "[1/6] INFO: MAP GOAL
                This ship has a mono-propellant turbopump engine, but it's run out of fuel and been turned off with a valve. \
                There's still a lot of fuel around, so let's move it where it needs to be to get this ship moving again!"
                ),

                dedent(
                    "[2/6] TASK: START FILLING THE EMPTY TANK
                Start by adding the missing pipe to connect the empty tank with the full ones. \
                Nothing will happen because the tank is stalled as it ran out of propellant. \
                To un-stall it just click on it in inspect mode. \
                If the tank is in a condition where it would fill and not empty, it will return to normal operation. \
                Once you click it you should see it start to fill. \
                Eventually it will fill until it equalises with the other tanks, but it's going to take a while. \
                Let's see how we can speed this up!"
                ),

                dedent(
                    "[3/6] TASK: USE A TRANSFER PUMP
                To speed things up, and to enable us to fill that tank up all the way, we can use one of the transfer pumps scattered around. \
                Try moving one inline with the pipes running between the tanks. \
                You will see that the fluid flow stops, this is because the pump is off. \
                Just click it in inspect mode to toggle it on and off. \
                Now the tank should be filling faster, and it will fill all the way. \
                Once the pump motor stops spinning you will know the tank is full!"
                ),

                dedent(
                    "[4/6] INFO: USING VALVES TO CONTROL FLOW
                Now we have moved the fuel we need to learn how the valve works to use it! \
                This valve is adjustable, you can press the green button to open it a little, and the red button to close it a little (actually clicking anywhere above or below the center line works for this). \
                The little blue arrows indicate the valve setpoint, and there is a bit of delay as the valve actually moves into the commanded position."
                ),

                dedent(
                    "[5/6] TASK: CONTROL THE VALVE
                Start by opening the valve one click, you'll see even that is enough to get things flowing. \
                Now click a bunch of times to open the valve all the way! \
                It won't take long for all the fuel in the close-by tank to be used up, and then your thrust will drop as you lose a lot more pressure over the long pipe run to the far away tanks. \
                Let's shut the valve so the tank can refill! \
                Click the red button a bunch of times. \
                You'll notice the setpoint indicators move quickly but the valve itself takes a while to close. \
                It is extra noticeable as it tries to pinch off that last bit of flow. \
                This is why conventional turbopump engines are a poor choice for fine thrust control, even with a valve!"
                ),

                dedent(
                    "[6/6] TASK: EXPERIMENT WITH THE SYSTEM
                Have a play filling and draining the tank, opening and closing the valve and when you are happy you can mark this completed!"
                ),
            ]
        )
    )

    ship_demo::DemoLevel = DemoLevel(
        map = mapgen_bigshipdemo(),
        hint = HintData(
            title = "Whats possible and editor mode",
            hints = [
                dedent(
                    "[1/5] INFO: FINAL DEMO
                Congratulations, you have learned the basics of how to interact with the Rocket Plumber simulation! \
                This next map is just to show off the sort of things that are possible in the simulation, putting all these pieces together. \
                Have a play around!"
                ),

                dedent(
                    "[2/5] TASK: ENTER EDITOR MODE
                Actually one more thing to learn, and it's a secret. \
                If you press the grave key (`/~ key next to the 1 on your keyboard) at any time you enter 'editor' mode. \
                It's kinda like a developer menu or creative mode, it's not how it's intended you would interact with the simulation once there is a bit more of a game implemented, but it's how I build the maps for this demo, and it's the way you can build ships of your own. \
                Here's how it works..."
                ),

                dedent(
                    "[3/5] TASK: USING EDITOR MODE
                Once you've pressed the grave key (`/~ key next to the 1 on your keyboard) you should see a few new mode options. \
                Press 5 to enter 'create tile' mode which lets you place the different tiles to build a ship, you can cycle through the options with the scroll wheel, and tune their parameters in the 'properties' panel on the right of the screen. \
                Press 6 to enter 'edit surface' mode that lets you click to add or remove ship surface to build on. \
                If you enter 'pipe' mode, you will also notice an option in the properties panel to switch to the big pipes. \
                Try using these new abilities to modify the ship!"
                ),

                dedent(
                    "[4/5] INFO: WRAP UP
                Thanks for playing through the demo. \
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

                dedent(
                    "[5/5] TASK: DEMO COMPLETION
                Once you are done playing around, you can mark this complete to finish the demo and head back to the main menu. \
                I encourage you to try building a rocket engine in a new blank map, in editor mode (and if you do send me a screenshot!). \
                If you have any feedback or ideas on where I should take this project from here I'd love to hear it!"
                ),
            ]
        )
    )

    return [
        basic_controls_and_plumbing_demo,
        big_pipe_plumbing_demo,
        flow_demo,
        cold_gas_thrusters_demo,
        electric_pump_intro,
        conv_turbo_pumps,
        fluid_transfer,
        ship_demo,
    ]
end

# ===============================================================
# Demo Control Flow
# ===============================================================

"Control loop to run through the demo levels in sequence"
function enter_demo(levels::Vector{DemoLevel}, window::GLFW.Window)
    for level in levels
        ret_symbol = enter_gameloop(window; map_source = level.map, tutorial_hint = level.hint)

        if ret_symbol != :hint_completed
            break # exit demo unless hint was completed
        end
    end
    return @info "Demo completed"
end
