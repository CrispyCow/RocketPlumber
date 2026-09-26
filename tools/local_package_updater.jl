#!/usr/bin/env julia

"""
Refresh every local package environment in this repository.

By default this resolves, instantiates, and precompiles each package workspace
without explicitly requesting registry package upgrades. Pass `--update` to
opt into a full per-workspace package update. Pkg resolution may still change
manifests.

Any new local package should live somewhere under `local_packages/` with its own
`Project.toml` and matching source entry point so this script discovers it.
"""
module LocalPackageUpdater

using TOML

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const LOCAL_PACKAGES_ROOT = joinpath(REPO_ROOT, "local_packages")

Base.@kwdef struct RefreshOptions
    allow_updates::Bool = false
    list_only::Bool = false
end

Base.@kwdef struct PackageWorkspace
    root::String
    members::Vector{String} = String[]
end

function usage_text()
    return join([
        "Usage: julia tools/local_package_updater.jl [--update] [--list]",
        "",
        "Options:",
        "      --update    Update packages in each workspace before resolving.",
        "      --list      Print discovered package workspaces and exit.",
        "  -h, --help      Show this help text.",
    ], '\n')
end

function parse_args(args::Vector{String})
    allow_updates = false
    list_only = false

    for arg in args
        if arg == "--update"
            allow_updates = true
        elseif arg == "--list"
            list_only = true
        elseif arg in ("-h", "--help")
            println(usage_text())
            return nothing
        else
            error("Unrecognised argument: $(arg)")
        end
    end

    return RefreshOptions(; allow_updates, list_only)
end

"Return whether a project directory contains a package source entry point."
function is_package_root(project_dir::AbstractString, project::AbstractDict)
    name = get(project, "name", nothing)
    uuid = get(project, "uuid", nothing)
    isnothing(name) && return false
    isnothing(uuid) && return false
    return isfile(joinpath(project_dir, "src", "$(name).jl"))
end

"Return project directories discovered beneath `packages_root` in stable order."
function find_package_roots(packages_root::AbstractString)
    package_roots = String[]

    for (root, _dirs, files) in walkdir(packages_root)
        "Project.toml" in files || continue
        project_dir = normpath(root)
        project = TOML.parsefile(joinpath(project_dir, "Project.toml"))
        is_package_root(project_dir, project) || continue
        push!(package_roots, project_dir)
    end

    sort!(package_roots)
    return package_roots
end

"Return declared workspace members that are discovered local package roots."
function workspace_members(project_dir::AbstractString, package_roots::Vector{String})
    project = TOML.parsefile(joinpath(project_dir, "Project.toml"))
    workspace = get(project, "workspace", nothing)
    isnothing(workspace) && return String[]

    members = String[]
    for relative_path in get(workspace, "projects", String[])
        member_dir = normpath(joinpath(project_dir, relative_path))
        member_dir in package_roots || continue
        push!(members, member_dir)
    end

    sort!(members)
    return members
end

"Group local package roots so each declared workspace is refreshed once."
function find_package_workspaces(packages_root::AbstractString)
    package_roots = find_package_roots(packages_root)
    member_roots = Set{String}()
    workspaces = PackageWorkspace[]

    for package_root in package_roots
        members = workspace_members(package_root, package_roots)
        union!(member_roots, members)
        push!(workspaces, PackageWorkspace(; root=package_root, members))
    end

    filter!(workspace -> !(workspace.root in member_roots), workspaces)
    sort!(workspaces; by=workspace -> workspace.root)
    return workspaces
end

"Return a repository-relative label for cleaner logging."
function package_label(pkg_dir::AbstractString)
    return relpath(pkg_dir, REPO_ROOT)
end

"Run repository maintenance steps for one package workspace in a child Julia process."
function refresh_workspace!(workspace::PackageWorkspace, options::RefreshOptions)
    label = package_label(workspace.root)

    println()
    println("=== Refreshing ", label, " ===")
    update_code = options.allow_updates ? "Pkg.update(; workspace=true); " : ""
    code = "using Pkg; " * update_code * "Pkg.resolve(; workspace=true); Pkg.instantiate(; workspace=true); Pkg.precompile(; workspace=true)"
    cmd = Cmd(`$(Base.julia_cmd()) --project=$(workspace.root) --startup-file=no -e $(code)`; dir=workspace.root)
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

    workspaces = find_package_workspaces(LOCAL_PACKAGES_ROOT)
    isempty(workspaces) && error("No local package environments were found under $(LOCAL_PACKAGES_ROOT)")

    if options.list_only
        foreach(workspace -> println(package_label(workspace.root)), workspaces)
        return nothing
    end

    println("Repository root: ", REPO_ROOT)
    println("Discovered ", length(workspaces), " local package workspaces.")
    println("Mode: ", options.allow_updates ? "update + resolve + instantiate + precompile" : "resolve + instantiate + precompile")

    failures = Pair{String, Exception}[]

    for workspace in workspaces
        try
            refresh_workspace!(workspace, options)
        catch err
            err isa InterruptException && rethrow()
            push!(failures, package_label(workspace.root) => err)
            println("*** Failed ", package_label(workspace.root), ": ", sprint(showerror, err))
        end
    end

    println()
    println("Summary: ", length(workspaces) - length(failures), "/", length(workspaces), " package workspaces refreshed successfully.")

    if !isempty(failures)
        println("Failures:")
        for (label, err) in failures
            println(" - ", label, ": ", sprint(showerror, err))
        end
        error("Local package updater failed for $(length(failures)) package workspace(s).")
    end

    return nothing
end

end # module LocalPackageUpdater

if !isempty(PROGRAM_FILE) && abspath(PROGRAM_FILE) == abspath(@__FILE__)
    LocalPackageUpdater.main(ARGS)
end
