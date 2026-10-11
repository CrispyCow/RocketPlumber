#=
Scope: Extension point for released-save compatibility migrations
Formatter: Runic
=#

# Only current-format saves are supported before the first release. Once a released
# persistence baseline exists, add required JLD2.Upgrade mappings and corresponding
# JLD2.rconvert methods here, with historical regression tests.

"Build the release-migration typemap; unmapped types use normal JLD2 reconstruction."
_build_map_typemap() = Dict{String, Any}()
