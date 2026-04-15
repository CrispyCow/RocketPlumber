#!/usr/bin/env julia

"""
Update every local package environment in this repository.

Any new local package should live somewhere under `local_packages/` with its own
`Project.toml` so this script discovers it automatically.
"""
module LocalPackageUpdater

using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const LOCAL_PACKAGES_ROOT = joinpath(REPO_ROOT, "local_packages")

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

"Run repository maintenance steps for one local package environment."
function refresh_package!(pkg_dir::AbstractString)
    label = package_label(pkg_dir)

    println()
    println("=== Refreshing ", label, " ===")
    Pkg.activate(pkg_dir)
    Pkg.update()
    Pkg.resolve()
    Pkg.instantiate()
    Pkg.precompile()
    println("=== Completed ", label, " ===")

    return nothing
end

function main()
    if !isdir(LOCAL_PACKAGES_ROOT)
        error("Could not find local_packages directory at $(LOCAL_PACKAGES_ROOT)")
    end

    package_dirs = find_local_package_dirs()
    isempty(package_dirs) && error("No local package environments were found under $(LOCAL_PACKAGES_ROOT)")

    println("Repository root: ", REPO_ROOT)
    println("Discovered ", length(package_dirs), " local package environments.")

    failures = Pair{String, Exception}[]

    for pkg_dir in package_dirs
        try
            refresh_package!(pkg_dir)
        catch err
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

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module LocalPackageUpdater