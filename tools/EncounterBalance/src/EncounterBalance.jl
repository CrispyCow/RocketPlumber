# ===============================================================
# Encounter Balance Visualisation Tool
# ===============================================================
#
# Plots encounter class, fuel tag, and component-set selection weights over a
# representative richness range. The audit samples completed generated ships.
#
# Recommended usage (from repo root):
#   julia tools/encounter_balance.jl [--audit | --display]
#
# Prerequisite (first time only):
#   julia --project=tools/EncounterBalance -e "using Pkg; Pkg.instantiate()"

using Printf
using Statistics
using Plots
using HexFlowProcGen, HexFluids, FlowMap, SquirrelNoise

# Bring in all dependencies that src/components.jl expects in scope
using HexFrame, HexElements, HexComponentsAPI
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents
using HexFlowBasicPipes

# Load the encounter config definitions from the game
include(joinpath(@__DIR__, "..", "..", "..", "src", "components.jl"))

const RICHNESS_RANGE = 1.0:0.05:8.0  # calculate_richness clamps to at least 1.0
const AUDIT_RICHNESS_VALUES = Float64[1.0, 2.0, 4.0, 8.0]
const AUDIT_SEED_COUNT = 512
const AUDIT_FLUIDS = (
    HexFluids.COLD_GAS,
    HexFluids.MONOPROP_LIQUID,
    HexFluids.FUEL_LIQUID,
    HexFluids.OXIDISER_LIQUID,
)

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

    return plot(richness_range, data,
        label = permutedims(names),
        xlabel = "Richness",
        ylabel = "Weight",
        title = title,
        linewidth = 2,
        legend = :outerright,
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

    return areaplot(richness_range, normalised,
        label = permutedims(names),
        xlabel = "Richness",
        ylabel = "Proportion",
        title = title,
        fillalpha = 0.85,
        legend = :outerright,
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

function plot_fuel_tags(
        class_name::String,
        source::FluidTaggedEncounterComponents,
        richness_range,
    )
    fuel_configs = source.fuel_configs
    tags = sort!(collect(keys(fuel_configs)))
    names = [string(tag) for tag in tags]
    rules = ScalingRule[fuel_configs[tag].weight for tag in tags]

    p1 = plot_scaling_lines(richness_range, names, rules;
        title = "Fuel Tag Weights — $class_name")
    p2 = plot_proportions(richness_range, names, rules;
        title = "Fuel Tag Proportions — $class_name")
    return p1, p2
end

"Plot the weights used to select component sets within one encounter pool."
function plot_component_pool(class_name::String, fuel_tag::Union{FluidType, Nothing},
        pool::Vector{WeightedComponentSet}, richness_range)
    names = [weighted_set.component_set.name for weighted_set in pool]
    rules = ScalingRule[weighted_set.weight for weighted_set in pool]
    title_suffix = isnothing(fuel_tag) ? class_name : "$class_name — $fuel_tag"

    p1 = plot_scaling_lines(richness_range, names, rules;
        title = "Component Set Weights — $title_suffix")
    p2 = plot_proportions(richness_range, names, rules;
        title = "Component Set Proportions — $title_suffix")
    return p1, p2
end

# ===============================================================
# Generated encounter audit
# ===============================================================

struct AuditSample
    component_count::Int
    hull_tile_count::Int
    tank_count::Int
    transfer_pump_count::Int
    tank_cluster_count::Int
    wet_masses::NTuple{4, Float64}
end

struct AuditSummary
    encounter_class::EncounterClass
    fuel_tag::Union{FluidType, Nothing}
    richness::Float64
    target_components::Int
    clustered_count_scale::Float64
    samples::Vector{AuditSample}
end

"Return coordinates in a stable order for audit output and invariant errors."
function sorted_tile_coords(coords)
    return sort!(collect(coords); by = coord -> (Int(coord.q), Int(coord.r)))
end

"Return connected tank-occupied tile clusters using the ordinary hex adjacency relation."
function tank_spatial_clusters(blueprint::ShipBlueprint)::Vector{Vector{TileCoord}}
    tank_coords = Set(
        coord for (coord, placed_component) in blueprint.components
        if placed_component.component isa ThevininTankCompBehav
    )
    remaining = copy(tank_coords)
    clusters = Vector{Vector{TileCoord}}()

    while !isempty(remaining)
        start = first(sorted_tile_coords(remaining))
        delete!(remaining, start)
        cluster = TileCoord[start]
        frontier = TileCoord[start]

        while !isempty(frontier)
            current = pop!(frontier)
            for neighbour in get_adjacent_tiles_for_tile(current)
                neighbour in remaining || continue
                delete!(remaining, neighbour)
                push!(cluster, neighbour)
                push!(frontier, neighbour)
            end
        end

        push!(clusters, sorted_tile_coords(cluster))
    end

    return clusters
end

"Return the initial state fields whose equality prevents visible cluster equilibration."
function tank_initial_state(component::ThevininTankCompBehav)
    tank_core = component.tank.tank
    return (
        max_charge = tank_core.max_charge,
        charge = tank_core.state.charge,
        max_voltage = tank_core.max_voltage,
        series_conductance = component.series_conductance,
        stored_fluid = get_stored_fluid(component),
    )
end

"Validate that one generated tank cluster shares one rolled initial state."
function validate_tank_clusters(
        blueprint::ShipBlueprint,
        encounter_class::EncounterClass,
        fuel_tag::Union{FluidType, Nothing},
        richness::Float64,
        seed::UInt32,
    )::Int
    clusters = tank_spatial_clusters(blueprint)

    for cluster in clusters
        reference = tank_initial_state(blueprint.components[first(cluster)].component)
        for coord in cluster[2:end]
            state = tank_initial_state(blueprint.components[coord].component)
            state == reference && continue
            throw(ArgumentError(
                "Unequal tank initial state in $encounter_class, fuel tag $fuel_tag, " *
                "richness $richness, seed $seed at $coord; " *
                "reference $(first(cluster)) = $reference, actual = $state"
            ))
        end
    end

    return length(clusters)
end

"Collect one completed blueprint's audit metrics."
function audit_sample(
        blueprint::ShipBlueprint,
        encounter_class::EncounterClass,
        fuel_tag::Union{FluidType, Nothing},
        richness::Float64,
        seed::UInt32,
    )::AuditSample
    tank_count = 0
    transfer_pump_count = 0
    wet_masses = zeros(Float64, length(AUDIT_FLUIDS))

    for placed_component in values(blueprint.components)
        component = placed_component.component
        tank_count += component isa ThevininTankCompBehav
        transfer_pump_count += component isa ElectricPumpCompBehav{ElectricTransferPump}
        for (index, fluid) in pairs(AUDIT_FLUIDS)
            wet_masses[index] += get_component_wet_mass(component; fluid)
        end
    end

    tank_cluster_count = validate_tank_clusters(
        blueprint, encounter_class, fuel_tag, richness, seed
    )
    return AuditSample(
        length(blueprint.components),
        length(blueprint.ship_tiles),
        tank_count,
        transfer_pump_count,
        tank_cluster_count,
        Tuple(wet_masses),
    )
end

"Return all positive-weight fuel tags for an encounter class at `richness`."
function audit_fuel_tags(
        source::EncounterComponentSource,
        richness::Float64,
    )::Vector{Union{FluidType, Nothing}}
    source isa DirectEncounterComponents && return Union{FluidType, Nothing}[nothing]
    fluid_source = source::FluidTaggedEncounterComponents
    tags = FluidType[]
    for tag in sort!(collect(keys(fluid_source.fuel_configs)))
        weight = evaluate_scaling(fluid_source.fuel_configs[tag].weight, richness)
        weight > 0.0 && push!(tags, tag)
    end
    return Union{FluidType, Nothing}[tags...]
end

"Generate one deterministic black-box audit summary from completed encounters."
function audit_encounter_case(
        encounter_class::EncounterClass,
        class_config::EncounterClassConfig,
        fuel_tag::Union{FluidType, Nothing},
        richness::Float64,
    )::AuditSummary
    target_components = compute_target_components(class_config.target_components, richness)
    clustered_count_scale = HexFlowProcGen.compute_clustered_spawn_count_scale(class_config, richness)
    samples = AuditSample[]

    for seed in UInt32(1):UInt32(AUDIT_SEED_COUNT)
        blueprint = generate_encounter(
            encounter_class,
            fuel_tag,
            richness,
            seed,
            class_config,
        )
        push!(samples, audit_sample(blueprint, encounter_class, fuel_tag, richness, seed))
    end

    return AuditSummary(
        encounter_class,
        fuel_tag,
        richness,
        target_components,
        clustered_count_scale,
        samples,
    )
end

"Return a sample metric by name."
function audit_values(summary::AuditSummary, field::Symbol)::Vector{Float64}
    return Float64[getproperty(sample, field) for sample in summary.samples]
end

"Format a floating-point audit value for a Markdown table."
format_audit_value(value::Real) = @sprintf("%.2f", value)
format_audit_percent(value::Real) = @sprintf("%.1f%%", 100.0 * value)

"Print the component-count and hull metrics for the completed audit cases."
function print_component_audit_table(summaries::Vector{AuditSummary})
    println("\n### Component and hull balance")
    println("| Class | Fuel tag | Richness | Target | Cluster scale | Mean | Min | P10 | Median | P90 | Max | Under target | Over target | Hull mean | Hull P10 | Hull median | Hull P90 | Hull max | Occupancy |")
    println("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

    for summary in summaries
        component_values = audit_values(summary, :component_count)
        hull_values = audit_values(summary, :hull_tile_count)
        occupancy_values = [
            sample.component_count / sample.hull_tile_count for sample in summary.samples
        ]
        under_target = count(
            value -> value < summary.target_components,
            component_values,
        ) / length(component_values)
        over_target = count(
            value -> value > summary.target_components,
            component_values,
        ) / length(component_values)
        println(
            "| $(summary.encounter_class) | $(summary.fuel_tag) | $(format_audit_value(summary.richness)) | " *
            "$(summary.target_components) | $(format_audit_value(summary.clustered_count_scale)) | " *
            "$(format_audit_value(mean(component_values))) | $(format_audit_value(minimum(component_values))) | " *
            "$(format_audit_value(quantile(component_values, 0.10))) | " *
            "$(format_audit_value(median(component_values))) | " *
            "$(format_audit_value(quantile(component_values, 0.90))) | " *
            "$(format_audit_value(maximum(component_values))) | " *
            "$(format_audit_percent(under_target)) | $(format_audit_percent(over_target)) | " *
            "$(format_audit_value(mean(hull_values))) | " *
            "$(format_audit_value(quantile(hull_values, 0.10))) | " *
            "$(format_audit_value(median(hull_values))) | " *
            "$(format_audit_value(quantile(hull_values, 0.90))) | " *
            "$(format_audit_value(maximum(hull_values))) | " *
            "$(format_audit_value(mean(occupancy_values))) |"
        )
    end
end

"Print tank, pump, cluster, and stored-fluid metrics for the completed audit cases."
function print_inventory_audit_table(summaries::Vector{AuditSummary})
    fluid_names = [string(fluid) for fluid in AUDIT_FLUIDS]
    println("\n### Inventory balance")
    println("| Class | Fuel tag | Richness | Mean tanks | Mean transfer pumps | Mean tank clusters | " *
        join("Mean $(name) mass | " for name in fluid_names) * "")
    println("| --- | --- | ---: | ---: | ---: | ---: | " *
        join("---: | " for _ in AUDIT_FLUIDS) * "")

    for summary in summaries
        fluid_mass_columns = join(
            format_audit_value(mean(sample.wet_masses[index] for sample in summary.samples)) * " | "
            for index in eachindex(AUDIT_FLUIDS)
        )
        println(
            "| $(summary.encounter_class) | $(summary.fuel_tag) | " *
            "$(format_audit_value(summary.richness)) | " *
            "$(format_audit_value(mean(audit_values(summary, :tank_count)))) | " *
            "$(format_audit_value(mean(audit_values(summary, :transfer_pump_count)))) | " *
            "$(format_audit_value(mean(audit_values(summary, :tank_cluster_count)))) | " *
            "$fluid_mass_columns"
        )
    end
end

"Run the deterministic, non-interactive encounter balance audit."
function run_audit(config::EncounterSystemConfig)
    summaries = AuditSummary[]
    for encounter_class in sort!(collect(keys(config.encounter_class_configs)))
        class_config = config.encounter_class_configs[encounter_class]
        for richness in AUDIT_RICHNESS_VALUES
            for fuel_tag in audit_fuel_tags(class_config.component_source, richness)
                push!(summaries, audit_encounter_case(
                    encounter_class, class_config, fuel_tag, richness
                ))
            end
        end
    end

    println("# Encounter balance audit")
    println("Seeds: UInt32(1) through UInt32($AUDIT_SEED_COUNT)")
    print_component_audit_table(summaries)
    print_inventory_audit_table(summaries)
    return nothing
end

"Save related weight and proportion plots as one image."
function save_plot_pair(output_dir::String, filename::String, weight_plot::Plots.Plot,
        proportion_plot::Plots.Plot; display_plot::Bool = false)
    combined = plot(weight_plot, proportion_plot;
        layout = (1, 2),
        size = (1900, 600),
        margin = 8Plots.mm)
    output_path = joinpath(output_dir, filename)
    savefig(combined, output_path)
    display_plot && display(combined)
    println("Saved $output_path")
    return nothing
end

"Generate class, fuel-tag, and component-set selection plots from the current game config."
function run_plots(config::EncounterSystemConfig; display_plot::Bool = false)
    output_dir = normpath(joinpath(@__DIR__, "..", "outputs"))
    mkpath(output_dir)

    class_weights, class_proportions = plot_encounter_classes(config, RICHNESS_RANGE)
    save_plot_pair(output_dir, "encounter_classes.png", class_weights, class_proportions; display_plot)

    for encounter_class in sort!(collect(keys(config.encounter_class_configs)))
        class_config = config.encounter_class_configs[encounter_class]
        source = class_config.component_source
        class_name = string(encounter_class)
        class_slug = lowercase(class_name)

        if source isa FluidTaggedEncounterComponents
            fuel_weights, fuel_proportions = plot_fuel_tags(class_name, source, RICHNESS_RANGE)
            save_plot_pair(output_dir, "fuel_tags_$class_slug.png",
                fuel_weights, fuel_proportions; display_plot)
        end

        fuel_tags = source isa DirectEncounterComponents ?
            Union{FluidType, Nothing}[nothing] :
            Union{FluidType, Nothing}[sort!(collect(keys(source.fuel_configs)))...]

        for fuel_tag in fuel_tags
            pool = resolve_encounter_component_pool(source, fuel_tag)
            component_weights, component_proportions =
                plot_component_pool(class_name, fuel_tag, pool, RICHNESS_RANGE)
            tag_slug = isnothing(fuel_tag) ? "direct" : lowercase(string(fuel_tag))
            save_plot_pair(output_dir, "component_pool_$(class_slug)_$(tag_slug).png",
                component_weights, component_proportions; display_plot)
        end
    end

    return nothing
end

"Run the requested plot or audit mode using the application's encounter configuration."
function main(args::Vector{String} = ARGS)
    if "--help" in args
        println("Usage: julia tools/encounter_balance.jl [--audit | --display | --help]")
        println("Default: save selection plots in tools/EncounterBalance/outputs/.")
        println("--audit: sample generated encounters and print Markdown balance tables.")
        println("--display: also display each generated plot in a graphical Julia front end.")
        return nothing
    end

    invalid_args = filter(arg -> !(arg in ("--audit", "--display")), args)
    isempty(invalid_args) || throw(ArgumentError("Unknown Encounter Balance argument(s): $(join(invalid_args, ", "))"))
    if "--audit" in args && "--display" in args
        throw(ArgumentError("--display applies only to the plot mode"))
    end

    if "--audit" in args
        run_audit(encounter_system_config)
    else
        run_plots(encounter_system_config; display_plot = "--display" in args)
    end

    return nothing
end

main()
