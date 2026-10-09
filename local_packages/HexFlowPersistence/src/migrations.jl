#=
Scope: JLD2 conversions and typemap for previous-release saves
Formatter: Runic
=#

# Rocket Plumber aims to support saves from the previous public release. Its single
# frozen save is the primary end-to-end compatibility regression test. When a changed
# persisted type or state is not represented by that fixture, add a small targeted
# historical migration test. Development/prerelease saves remain best-effort.
# The sole provisional teaser_0.1.0-dev.jld2 baseline in test/fixtures is replaced
# by a final-release save at 0.1.0, rather than accumulated alongside it.
#
# Add release migrations here as rconvert(::Type{CurrentType}, old::NamedTuple)
# methods, and typemap["Old.Module.Type"] = JLD2.Upgrade(CurrentType) below.

"Build the JLD2 typemap for release compatibility migrations."
function _build_map_typemap()::Dict{String, Any}
    return Dict{String, Any}()
end
