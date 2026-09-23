#!/usr/bin/env julia

# Keep help and strict argument errors usable in environments without a display.
const TOOL_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
using FlowMap
include(joinpath(TOOL_ROOT, "src", "timelapse.jl"))
include(joinpath(@__DIR__, "src", "TimelapseExportTool.jl"))

parsed = try
    TimelapseExportTool.parse_cli(ARGS; repository_root = TOOL_ROOT)
catch error
    exit(TimelapseExportTool._report_error(error))
end

parsed.help && (TimelapseExportTool.print_help(); exit(0))

try
    TimelapseExportTool.validate_paths!(parsed)
catch error
    exit(TimelapseExportTool._report_error(error))
end

# These packages register every concrete persisted component/pipe type before JLD2 reads the save.
try
    for expression in (
        :(using LinearAlgebra, StaticArrays, JLD2, FFMPEG, GLFW),
        :(using HexFrame, HexElements, HexFluids, HexFlowTelemetry),
        :(using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen),
        :(using HexFlowControl, HexFlowCalculator, HexFlowRendering),
        :(using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents),
        :(using HexFlowNozzleComponents, HexFlowPumpComponents, HexFlowBasicPipes),
    )
        Core.eval(Main, expression)
    end
    include(joinpath(TOOL_ROOT, "src", "map_loading.jl"))
catch error
    error isa InterruptException && exit(TimelapseExportTool._report_error(error))
    println(stderr, "Cannot initialise the exporter game dependencies. A working display server and OpenGL driver are required ($(sprint(showerror, error))).")
    exit(4)
end

# The tool resolves assets from this entry point, independent of the process working directory.
exit(TimelapseExportTool._run(parsed))
