#!/usr/bin/env julia

"""
Refresh every local package environment in this repository.

By default this resolves, instantiates, and precompiles each environment without
explicitly requesting registry package upgrades. Pass `--update` to opt into a
full per-environment package update. Pkg resolution may still change manifests.

Any new local package should live somewhere under `local_packages/` with its own
`Project.toml` so this script discovers it automatically.
"""
module LocalPackageUpdater

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const LOCAL_PACKAGES_ROOT = joinpath(REPO_ROOT, "local_packages")

Base.@kwdef struct RefreshOptions
    allow_updates::Bool = false
end

function parse_args(args::Vector{String})
    allow_updates = false

    for arg in args
        if arg == "--update"
            allow_updates = true
        elseif arg in ("-h", "--help")
            println("Usage: julia tools/local_package_updater.jl [--update]")
            println()
            println("Without --update, the script only resolves, instantiates, and precompiles each local package environment.")
            println("With --update, it also runs Pkg.update() inside each environment before resolving.")
            return nothing
        else
            error("Unrecognised argument: $(arg)")
        end
    end

    return RefreshOptions(; allow_updates)
end

"Return all local package directories in a stable order."
function find_local_package_dirs()
    package_dirs = String[]

    for (root, _dirs, files) in walkdir(LOCAL_PACKAGES_ROOT)
        "Project.toml" in files || continue
        push!(package_dirs, normpath(root))
    end

    sort!(package_dirs)
    return package_dirs
end

"Return a repository-relative label for cleaner logging."
function package_label(pkg_dir::AbstractString)
    return relpath(pkg_dir, REPO_ROOT)
end

"Run repository maintenance steps for one local package environment in a child Julia process."
function refresh_package!(pkg_dir::AbstractString, options::RefreshOptions)
    label = package_label(pkg_dir)

    println()
    println("=== Refreshing ", label, " ===")
    update_code = options.allow_updates ? "Pkg.update(); " : ""
    code = "using Pkg; " * update_code * "Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()"
    cmd = `$(Base.julia_cmd()) --project=$(pkg_dir) --startup-file=no -e $(code)`
    run(cmd)
    println("=== Completed ", label, " ===")

    return nothing
end

function main(args::Vector{String}=String[])
    options = parse_args(args)
    options === nothing && return nothing

    if !isdir(LOCAL_PACKAGES_ROOT)
        error("Could not find local_packages directory at $(LOCAL_PACKAGES_ROOT)")
    end

    package_dirs = find_local_package_dirs()
    isempty(package_dirs) && error("No local package environments were found under $(LOCAL_PACKAGES_ROOT)")

    println("Repository root: ", REPO_ROOT)
    println("Discovered ", length(package_dirs), " local package environments.")
    println("Mode: ", options.allow_updates ? "update + resolve + instantiate + precompile" : "resolve + instantiate + precompile")

    failures = Pair{String, Exception}[]

    for pkg_dir in package_dirs
        try
            refresh_package!(pkg_dir, options)
        catch err
            err isa InterruptException && rethrow()
            push!(failures, package_label(pkg_dir) => err)
            println("*** Failed ", package_label(pkg_dir), ": ", sprint(showerror, err))
        end
    end

    println()
    println("Summary: ", length(package_dirs) - length(failures), "/", length(package_dirs), " package environments refreshed successfully.")

    if !isempty(failures)
        println("Failures:")
        for (label, err) in failures
            println(" - ", label, ": ", sprint(showerror, err))
        end
        error("Local package updater failed for $(length(failures)) package environment(s).")
    end

    return nothing
end

end # module LocalPackageUpdater

LocalPackageUpdater.main(abspath(PROGRAM_FILE) == (@__FILE__) ? ARGS : String[])
