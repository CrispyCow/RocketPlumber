#=
Scope: Production and JuliaC application entry point
Formatter: Runic
=#

using RocketPlumber

"Run the production application for a JuliaC-compiled executable."
function main(args::Vector{String})::Cint
    try
        RocketPlumber.launch()
        return 0
    catch e
        @error "Application error" exception = (e, catch_backtrace())
        return 1
    end
end

# Compatibility wrapper for PackageCompiler.
function main()::Cint
    return main(String[])
end

@main
