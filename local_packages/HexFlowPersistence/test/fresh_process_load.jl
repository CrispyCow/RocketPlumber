#=
Scope: Verify built-in map behaviours reconstruct with only HexFlowPersistence loaded explicitly
Formatter: Runic
=#

using HexFlowPersistence

length(ARGS) == 1 || error("expected one saved map path")
isdefined(Main, :RocketPlumber) && error("RocketPlumber was loaded in the child process")
isdefined(Main, :HexFlowBasicComponents) && error("a concrete component package was imported into Main")
isdefined(Main, :HexFlowBasicPipes) && error("a concrete pipe package was imported into Main")
isdefined(Main, :GLFW) && error("GLFW was imported into Main")

gamemap = loadmap_strict(only(ARGS))
frame = HexFlowPersistence.HexFrame
flow_map = HexFlowPersistence.FlowMap
component_coord = frame.TileCoord(2, -1)
pipe_coord = first(frame.get_side_pipes(component_coord))

length(gamemap.components) == 1 || error("saved component was not reconstructed")
placed_component = gamemap.components[component_coord]
component = placed_component.component
nameof(typeof(component)) == :BasicCompBehav || error("saved component has type $(typeof(component))")
nameof(parentmodule(typeof(component))) == :HexFlowBasicComponents || error("saved component came from the wrong module")
component.sprite.sprite == :test_persistence || error("saved component state changed")
isempty(component.elems.elements) || error("saved component elements changed")
placed_component.rotation == frame.R_NEG || error("saved component rotation changed")
placed_component.mirrored || error("saved component mirroring changed")
placed_component.ship == :primary || error("saved component ship changed")

length(gamemap.pipe_behaviors) == 1 || error("saved pipe was not reconstructed")
placed_pipe = gamemap.pipe_behaviors[pipe_coord]
pipe = placed_pipe.pipe
nameof(typeof(pipe)) == :ScrapPipeBehav || error("saved pipe has type $(typeof(pipe))")
nameof(parentmodule(typeof(pipe))) == :HexFlowBasicPipes || error("saved pipe came from the wrong module")
pipe.conductance == 7.5 || error("saved pipe conductance changed")
placed_pipe.ship == :primary || error("saved pipe ship changed")
flow_map.get_simulated_ticks(gamemap) == 1 || error("saved map statistics changed")
