#=
Scope: Rocket Plumber game-map persistence and save-format migrations
Formatter: Runic
=#

module HexFlowPersistence

using JLD2
using FlowMap
using HexComponentsAPI
using HexFlowProcGen
using HexFrame
import JLD2: rconvert

# Register concrete component and pipe types before JLD2 reconstructs a saved map.
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents, HexFlowBasicPipes

export TIMELAPSE_FORMAT_VERSION, TimelapseHistory, GameMapBundle
export loadmap, loadmap_bundle, loadmap_strict, loadmap_bundle_strict, savemap

# ===============================================================
# Persisted Types
# ===============================================================

const TIMELAPSE_FORMAT_VERSION::UInt16 = UInt16(2)

@kwdef struct TimelapseHistory
    format_version::UInt16 = TIMELAPSE_FORMAT_VERSION
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

#= ---------- Strict Loading ---------- =#

"Return a stored map, rejecting missing or invalid authoritative data."
function _stored_map(file::JLD2.JLDFile)::GameMap
    haskey(file, "stored_gamemap") || throw(ArgumentError("save file is missing stored_gamemap"))
    gamemap = file["stored_gamemap"]
    gamemap isa GameMap || throw(ArgumentError("stored_gamemap has type $(typeof(gamemap)); expected GameMap"))
    return gamemap
end

"Return optional history, rejecting malformed or unsupported stored data."
function _stored_timelapse(file::JLD2.JLDFile; allow_stored_nothing::Bool = false)::Union{Nothing, TimelapseHistory}
    haskey(file, "stored_timelapse") || return nothing
    history = file["stored_timelapse"]
    allow_stored_nothing && isnothing(history) && return nothing
    history isa TimelapseHistory || throw(ArgumentError("stored_timelapse has an invalid type $(typeof(history)); expected TimelapseHistory"))
    history.format_version == TIMELAPSE_FORMAT_VERSION ||
        throw(ArgumentError("unsupported time-lapse format version $(history.format_version)"))
    return history
end

"Load and validate the authoritative map, propagating file and conversion failures."
function loadmap_strict(mappath::String)::GameMap
    return JLD2.jldopen(mappath, "r"; typemap = _build_map_typemap()) do file
        _stored_map(file)
    end
end

"Load a map and optional history, propagating malformed or unsupported data."
function loadmap_bundle_strict(mappath::String)::GameMapBundle
    return JLD2.jldopen(mappath, "r"; typemap = _build_map_typemap()) do file
        gamemap = _stored_map(file)
        timelapse = _stored_timelapse(file)
        GameMapBundle(gamemap, timelapse)
    end
end

#= ---------- Forgiving Loading ---------- =#

"Load a GameMap from the given path, or return an empty map on failure."
function loadmap(mappath::String)::GameMap
    try
        return loadmap_strict(mappath)
    catch e
        @warn "Map load failed; returning empty." exception = (e, catch_backtrace())
        return GameMap()
    end
end

"Load a map while isolating failures in optional time-lapse history."
function loadmap_bundle(mappath::String)::GameMapBundle
    try
        return JLD2.jldopen(mappath, "r"; typemap = _build_map_typemap()) do file
            gamemap = _stored_map(file)
            timelapse = try
                _stored_timelapse(file; allow_stored_nothing = true)
            catch e
                @warn "Time-lapse load failed: $(sprint(showerror, e)); continuing with the loaded map." exception = (e, catch_backtrace())
                nothing
            end
            GameMapBundle(gamemap, timelapse)
        end
    catch e
        @warn "Map load failed; returning empty." exception = (e, catch_backtrace())
        return GameMapBundle(GameMap())
    end
end

#= ---------- Saving ---------- =#

"Save a GameMapBundle with the established map and optional history keys."
function savemap(bundle::GameMapBundle, mappath::String)
    timelapse = bundle.timelapse
    if !isnothing(timelapse) && timelapse.format_version != TIMELAPSE_FORMAT_VERSION
        throw(ArgumentError("unsupported time-lapse format version $(timelapse.format_version)"))
    end

    try
        if isnothing(timelapse)
            JLD2.jldsave(mappath; stored_gamemap = bundle.gamemap)
        else
            JLD2.jldsave(mappath; stored_gamemap = bundle.gamemap, stored_timelapse = timelapse)
        end
    catch e
        @warn "Map save failed." path = mappath exception = (e, catch_backtrace())
    end
    return nothing
end

"Save a map without a time-lapse, preserving the legacy map-only API."
savemap(gamemap::GameMap, mappath::String) = savemap(GameMapBundle(gamemap), mappath)

end # module HexFlowPersistence
