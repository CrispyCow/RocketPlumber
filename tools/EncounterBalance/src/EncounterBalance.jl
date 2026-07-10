# ===============================================================
# Encounter Balance Visualisation Tool
# ===============================================================
#
# Plots encounter generation scaling rules over the practical richness range
# to visualise class ratios, fuel tag proportions, and component pool weights.
#
# Usage (from repo root):
#   julia --project=. tools/EncounterBalance/src/EncounterBalance.jl
#
# Prerequisite (first time only):
#   julia --project=tools/EncounterBalance -e "using Pkg; Pkg.instantiate()"

# Make the tool's environment visible so Plots.jl can be loaded,
# while the root --project=. provides all game packages.
const TOOL_ENV = normpath(joinpath(@__DIR__, ".."))
pushfirst!(LOAD_PATH, TOOL_ENV)

using Plots
using HexFlowProcGen, HexFluids, FlowMap

# Bring in all dependencies that src/components.jl expects in scope
using HexFrame, HexElements, HexComponentsAPI
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents
using HexFlowBasicPipes

# Load the encounter config definitions from the game
include(joinpath(@__DIR__, "..", "..", "..", "src", "components.jl"))

const RICHNESS_RANGE = 0.0:0.05:8.0

# ===============================================================
# Plot helpers
# ===============================================================

"Line plot of raw scaling rule values over richness."
function plot_scaling_lines(richness_range, names::Vector{String},
        rules::Vector{<:ScalingRule}; title::String = "Scaling Rules vs Richness")
    data = hcat([
        [evaluate_scaling(rule, Float64(r)) for r in richness_range]
        for rule in rules
    ]...)

    plot(richness_range, data,
        label = permutedims(names),
        xlabel = "Richness",
        ylabel = "Weight",
        title = title,
        linewidth = 2,
        legend = :right,
        size = (900, 500))
end

"Stacked area chart of normalised proportions over richness."
function plot_proportions(richness_range, names::Vector{String},
        rules::Vector{<:ScalingRule}; title::String = "Proportions vs Richness")
    raw = hcat([
        [evaluate_scaling(rule, Float64(r)) for r in richness_range]
        for rule in rules
    ]...)

    totals = sum(raw, dims=2)
    normalised = raw ./ max.(totals, 1e-10)

    areaplot(richness_range, normalised,
        label = permutedims(names),
        xlabel = "Richness",
        ylabel = "Proportion",
        title = title,
        fillalpha = 0.85,
        legend = :right,
        ylims = (0, 1),
        size = (900, 500))
end

# ===============================================================
# Encounter class plots
# ===============================================================

function plot_encounter_classes(config::EncounterSystemConfig, richness_range)
    classes = sort!(collect(keys(config.encounter_class_configs)))
    names = [string(cls) for cls in classes]
    rules = ScalingRule[config.encounter_class_configs[cls].class_weight for cls in classes]

    p1 = plot_scaling_lines(richness_range, names, rules;
        title = "Encounter Class Weights")
    p2 = plot_proportions(richness_range, names, rules;
        title = "Encounter Class Proportions")
    return p1, p2
end

# ===============================================================
# Fuel tag plots (per encounter class)
# ===============================================================

function plot_fuel_tags(class_name::String, class_config::EncounterClassConfig, richness_range)
    fuel_configs = class_config.fuel_configs
    tags = sort!(collect(keys(fuel_configs)))
    names = [string(tag) for tag in tags]
    rules = ScalingRule[fuel_configs[tag].weight for tag in tags]

    p1 = plot_scaling_lines(richness_range, names, rules;
        title = "Fuel Tag Weights — $class_name")
    p2 = plot_proportions(richness_range, names, rules;
        title = "Fuel Tag Proportions — $class_name")
    return p1, p2
end

# ===============================================================
# Main
# ===============================================================

function main()
    config = encounter_system_config
    richness_range = RICHNESS_RANGE

    subplots = Plots.Plot[]

    # Encounter class weights and proportions
    p_cw, p_cp = plot_encounter_classes(config, richness_range)
    push!(subplots, p_cw, p_cp)

    # Fuel tag weights and proportions per class (skip single-fuel classes)
    for cls in sort!(collect(keys(config.encounter_class_configs)))
        class_config = config.encounter_class_configs[cls]
        length(class_config.fuel_configs) <= 1 && continue
        p_fw, p_fp = plot_fuel_tags(string(cls), class_config, richness_range)
        push!(subplots, p_fw, p_fp)
    end

    # Combine into a single figure with subplots in a 2-column grid
    n = length(subplots)
    rows = cld(n, 2)  # ceiling division
    combined = plot(subplots...,
        layout = (rows, 2),
        size = (1600, 450 * rows),
        margin = 8Plots.mm)
    display(combined)

    println("\nPlot displayed. Press Enter to exit.")
    readline()
end

main()
