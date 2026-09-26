#!/usr/bin/env julia

# Keep help and strict argument errors usable in environments without a display.
const TOOL_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
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

# The tool resolves assets from this entry point, independent of the process working directory.
exit(TimelapseExportTool._run(parsed))
