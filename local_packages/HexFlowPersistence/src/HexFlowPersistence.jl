#=
Scope: Rocket Plumber game-map persistence and save-format migrations
Formatter: Runic
=#

module HexFlowPersistence

using JLD2
import Dates
using FlowMap
using HexComponentsAPI
using HexFlowProcGen
using HexFrame
import JLD2: rconvert

# Register concrete component and pipe types before JLD2 reconstructs a saved map.
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents, HexFlowBasicPipes

export TimelapseHistory, GameMapBundle
export loadmap, loadmap_bundle, savemap

# ===============================================================
# Persisted Types
# ===============================================================

@kwdef struct TimelapseHistory
    frames::Vector{GameMap} = GameMap[]
end

"Pair the authoritative current map with its optional time-lapse history."
@kwdef struct GameMapBundle
    gamemap::GameMap
    timelapse::Union{Nothing, TimelapseHistory} = nothing
end

GameMapBundle(gamemap::GameMap) = GameMapBundle(gamemap = gamemap)

include("migrations.jl")

# ===============================================================
# Save and Load
# ===============================================================

"Read the informational game version string, or `nothing` for a legacy/unversioned save."
function load_game_version(mappath::String)::Union{Nothing, String}
    return JLD2.jldopen(mappath, "r") do file
        get(file, "game_version", nothing)
    end
end

#= ---------- Loading ---------- =#

"Return a stored map, rejecting missing or invalid authoritative data."
function _stored_map(file::JLD2.JLDFile)::GameMap
    haskey(file, "stored_gamemap") || throw(ArgumentError("save file is missing stored_gamemap"))
    gamemap = file["stored_gamemap"]
    gamemap isa GameMap || throw(ArgumentError("stored_gamemap has type $(typeof(gamemap)); expected GameMap"))
    return gamemap
end

"Return optional history, rejecting malformed stored data."
function _stored_timelapse(file::JLD2.JLDFile)::Union{Nothing, TimelapseHistory}
    haskey(file, "stored_timelapse") || return nothing
    history = file["stored_timelapse"]
    isnothing(history) && return nothing
    history isa TimelapseHistory || throw(ArgumentError("stored_timelapse has an invalid type $(typeof(history)); expected TimelapseHistory"))
    return history
end

"Load and validate the authoritative map, propagating file and conversion failures."
function loadmap(mappath::String)::GameMap
    return JLD2.jldopen(mappath, "r"; typemap = _build_map_typemap()) do file
        _stored_map(file)
    end
end

"Load the authoritative map, discarding malformed optional history while preserving interrupts."
function loadmap_bundle(mappath::String)::GameMapBundle
    return JLD2.jldopen(mappath, "r"; typemap = _build_map_typemap()) do file
        gamemap = _stored_map(file)
        timelapse = try
            _stored_timelapse(file)
        catch e
            e isa InterruptException && rethrow()
            @warn "Time-lapse load failed: $(sprint(showerror, e)); continuing with the loaded map." path = mappath exception = (e, catch_backtrace())
            nothing
        end
        GameMapBundle(gamemap, timelapse)
    end
end

#= ---------- Saving ---------- =#

"Save a bundle with the caller's game version and the established map/history keys."
function savemap(bundle::GameMapBundle, mappath::String; game_version::VersionNumber)
    timelapse = bundle.timelapse
    if isnothing(timelapse)
        JLD2.jldsave(mappath; game_version = string(game_version), stored_gamemap = bundle.gamemap)
    else
        JLD2.jldsave(mappath; game_version = string(game_version), stored_gamemap = bundle.gamemap, stored_timelapse = timelapse)
    end
    return nothing
end

"Save a map without a time-lapse using the caller's game version."
savemap(gamemap::GameMap, mappath::String; game_version::VersionNumber) = savemap(GameMapBundle(gamemap), mappath; game_version)

#= ---------- Crash Dumps ---------- =#

"""
Write a calculator crash payload as JLD2 datasets and return the file path.

Called synchronously on the calculator thread; the payload's live map and solver
outputs are read without mutation or retention. The caller supplies the game version;
this package owns timestamp, path, and JLD2 writing.
"""
function write_crash_dump(payload::NamedTuple; game_version::VersionNumber, directory::String = "maps")::String
    timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    crashpath = joinpath(directory, "crash_$(timestamp).jld2")
    mkpath(dirname(crashpath))
    JLD2.jldsave(crashpath; game_version = string(game_version), payload...)

    return crashpath
end

end # module HexFlowPersistence
