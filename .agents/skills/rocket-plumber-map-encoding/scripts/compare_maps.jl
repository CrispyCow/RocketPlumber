#!/usr/bin/env julia

"""Compare a trusted map-generator function with a saved GameMap."""

using StaticArrays, LinearAlgebra
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowMap
using HexFlowProcGen, HexFlowNozzleComponents, FlowEngine
using HexFlowPersistence
using RocketPlumber

const COMPARISON_TOLERANCE = 1.0e-6

function resolve_map_path(input::String)::String
    endswith(lowercase(input), ".jld2") || error("Map input must have a .jld2 extension: $input")
    path = abspath(input)
    isfile(path) || error("Map file not found: $path")
    return path
end

function load_game_map(map_input::String)::GameMap
    map_path = resolve_map_path(map_input)
    return HexFlowPersistence.loadmap(map_path)
end

function validate_generator_name(generator_file::String)::Symbol
    endswith(lowercase(generator_file), ".jl") || error("Generator file must have a .jl extension: $generator_file")
    stem = splitext(basename(generator_file))[1]
    startswith(stem, "mapgen_") || error(
        "Generator filename must start with mapgen_: $(basename(generator_file))"
    )
    Base.isidentifier(stem) || error("Generator filename is not a valid Julia identifier: $stem")
    return Symbol(stem)
end

"Compare values recursively, reporting the first useful field path mismatch."
function compare_value(a, b, path::String; tolerance::Float64 = COMPARISON_TOLERANCE, seen_pairs = Set{Tuple{UInt, UInt}}())
    typeof(a) == typeof(b) || return "$path: type $(typeof(a)) != $(typeof(b))"

    if ismutabletype(typeof(a))
        pair = (objectid(a), objectid(b))
        pair in seen_pairs && return nothing
        push!(seen_pairs, pair)
    end

    if a isa Real
        return (a == b || isapprox(a, b; atol = tolerance, rtol = tolerance)) ? nothing :
            "$path: $a != $b (tolerance $tolerance)"
    elseif a isa AbstractString || a isa Symbol || a isa Char || a isa Type || a isa Function || isnothing(a)
        return a == b ? nothing : "$path: $(repr(a)) != $(repr(b))"
    elseif a isa AbstractArray
        length(a) == length(b) || return "$path: length $(length(a)) != $(length(b))"
        for index in eachindex(a, b)
            mismatch = compare_value(a[index], b[index], "$path[$index]"; tolerance, seen_pairs)
            isnothing(mismatch) || return mismatch
        end
        return nothing
    elseif a isa AbstractDict
        keys_a = collect(keys(a))
        keys_b = collect(keys(b))
        Set(keys_a) == Set(keys_b) || return "$path: dictionary keys differ"
        for key in keys_a
            mismatch = compare_value(a[key], b[key], "$path[$(repr(key))]"; tolerance, seen_pairs)
            isnothing(mismatch) || return mismatch
        end
        return nothing
    elseif a isa AbstractSet
        length(a) == length(b) || return "$path: set length $(length(a)) != $(length(b))"
        unmatched = collect(b)
        for (index, value_a) in pairs(collect(a))
            match_index = findfirst(value_b -> isnothing(compare_value(value_a, value_b, path; tolerance)), unmatched)
            isnothing(match_index) && return "$path: set value $(repr(value_a)) has no match"
            deleteat!(unmatched, match_index)
        end
        return nothing
    end

    if isstructtype(typeof(a))
        for field in fieldnames(typeof(a))
            mismatch = compare_value(getfield(a, field), getfield(b, field), "$path.$field"; tolerance, seen_pairs)
            isnothing(mismatch) || return mismatch
        end
        return nothing
    end

    return a == b ? nothing : "$path: $(repr(a)) != $(repr(b))"
end

function tunable_mismatch(original, generated, path::String; tolerance::Float64 = COMPARISON_TOLERANCE)
    try
        original_values = getfield.(original, :current_val)
        generated_values = getfield.(generated, :current_val)
        length(original_values) == length(generated_values) || return "$path: tunable count differs"
        for (index, (original_value, generated_value)) in enumerate(zip(original_values, generated_values))
            mismatch = compare_value(original_value, generated_value, "$path[$index]"; tolerance)
            isnothing(mismatch) || return mismatch
        end
    catch error_value
        return "$path: unable to read tunables ($(sprint(showerror, error_value)))"
    end
    return nothing
end

function safe_tunable_mismatch(getter::Function, original, generated, path::String; tolerance::Float64 = COMPARISON_TOLERANCE)
    try
        return tunable_mismatch(getter(original), getter(generated), path; tolerance)
    catch error_value
        return "$path: unable to read tunables ($(sprint(showerror, error_value)))"
    end
end

function component_entries(gamemap::GameMap)
    return Dict((placed.ship, coord) => placed for (coord, placed) in gamemap.components)
end

function pipe_entries(gamemap::GameMap)
    return Dict((placed.ship, coord) => placed for (coord, placed) in gamemap.pipe_behaviors)
end

function surface_entries(gamemap::GameMap)
    return Set((ship, coord) for (coord, ship) in each_surface_owner(gamemap))
end

function compare_placements(original::GameMap, generated::GameMap; tolerance::Float64 = COMPARISON_TOLERANCE)
    mismatches = String[]
    original_components = component_entries(original)
    generated_components = component_entries(generated)
    for key in sort!(collect(keys(original_components)); by = repr)
        haskey(generated_components, key) || (push!(mismatches, "component missing at $(repr(key))"); continue)
        original_component = original_components[key]
        generated_component = generated_components[key]
        original_component.rotation == generated_component.rotation || push!(mismatches, "component $(repr(key)): rotation differs")
        original_component.mirrored == generated_component.mirrored || push!(mismatches, "component $(repr(key)): mirroring differs")
        mismatch = compare_value(original_component.component, generated_component.component, "component $(repr(key)).behaviour"; tolerance)
        isnothing(mismatch) || push!(mismatches, mismatch)
        tunables = safe_tunable_mismatch(get_tunables, original_component, generated_component, "component $(repr(key)).tunables"; tolerance)
        isnothing(tunables) || push!(mismatches, tunables)
    end
    for key in setdiff(Set(keys(generated_components)), Set(keys(original_components)))
        push!(mismatches, "extra component at $(repr(key))")
    end

    original_pipes = pipe_entries(original)
    generated_pipes = pipe_entries(generated)
    for key in sort!(collect(keys(original_pipes)); by = repr)
        haskey(generated_pipes, key) || (push!(mismatches, "pipe missing at $(repr(key))"); continue)
        original_pipe = original_pipes[key]
        generated_pipe = generated_pipes[key]
        mismatch = compare_value(original_pipe.pipe, generated_pipe.pipe, "pipe $(repr(key)).behaviour"; tolerance)
        isnothing(mismatch) || push!(mismatches, mismatch)
        tunables = safe_tunable_mismatch(get_pipe_tunables, original_pipe, generated_pipe, "pipe $(repr(key)).tunables"; tolerance)
        isnothing(tunables) || push!(mismatches, tunables)
    end
    for key in setdiff(Set(keys(generated_pipes)), Set(keys(original_pipes)))
        push!(mismatches, "extra pipe at $(repr(key))")
    end
    return mismatches, original_components, generated_components, original_pipes, generated_pipes
end

function all_elements(gamemap::GameMap)::Vector{AbsoluteElement}
    elements = AbsoluteElement[]
    for (coord, component) in gamemap.components
        append!(elements, produce_abs_elements(component, coord))
    end
    for (coord, pipe) in gamemap.pipe_behaviors
        append!(elements, produce_abs_elements(pipe, coord))
    end
    return elements
end

function element_matches(original::AbsoluteElement, generated::AbsoluteElement; tolerance::Float64)
    original.type == generated.type || return false
    original.connections == generated.connections || return false
    original.id == generated.id || return false
    original.dependent_id == generated.dependent_id || return false
    original.active == generated.active || return false
    return original.value == generated.value || isapprox(original.value, generated.value; atol = tolerance, rtol = tolerance)
end

function compare_elements(original::GameMap, generated::GameMap; tolerance::Float64 = COMPARISON_TOLERANCE)
    original_elements = all_elements(original)
    generated_elements = all_elements(generated)
    remaining = copy(generated_elements)
    missing = AbsoluteElement[]
    for element in original_elements
        match_index = findfirst(candidate -> element_matches(element, candidate; tolerance), remaining)
        if isnothing(match_index)
            push!(missing, element)
        else
            deleteat!(remaining, match_index)
        end
    end
    return missing, remaining, length(original_elements), length(generated_elements)
end

function all_fluid_declarations(gamemap::GameMap)
    declarations = Vector{AbsFluidDecl}()
    list_fluid_declarations!(declarations, gamemap)
    return declarations
end

function compare_declarations(original::GameMap, generated::GameMap; tolerance::Float64 = COMPARISON_TOLERANCE)
    original_declarations = all_fluid_declarations(original)
    generated_declarations = all_fluid_declarations(generated)
    remaining = copy(generated_declarations)
    missing = Any[]
    for declaration in original_declarations
        match_index = findfirst(candidate -> isnothing(compare_value(declaration, candidate, "declaration"; tolerance)), remaining)
        if isnothing(match_index)
            push!(missing, declaration)
        else
            deleteat!(remaining, match_index)
        end
    end
    return missing, remaining, length(original_declarations), length(generated_declarations)
end

function is_traversable(value)
    return !(value === nothing || value isa Number || value isa Symbol || value isa AbstractString || value isa Char || value isa Type || value isa Function)
end

function walk_aliases!(value, placement, local_ids::Set{UInt}, locations::Dict{UInt, Vector{String}})
    is_traversable(value) || return nothing
    if ismutabletype(typeof(value))
        identity = objectid(value)
        identity in local_ids && return nothing
        push!(local_ids, identity)
        references = get!(locations, identity, String[])
        placement in references || push!(references, placement)
    end
    if value isa AbstractArray
        for item in value
            walk_aliases!(item, placement, local_ids, locations)
        end
    elseif value isa AbstractDict
        for (key, item) in value
            walk_aliases!(key, placement, local_ids, locations)
            walk_aliases!(item, placement, local_ids, locations)
        end
    elseif value isa AbstractSet
        for item in value
            walk_aliases!(item, placement, local_ids, locations)
        end
    elseif isstructtype(typeof(value))
        for field in fieldnames(typeof(value))
            walk_aliases!(getfield(value, field), placement, local_ids, locations)
        end
    end
    return nothing
end

function alias_warnings(gamemap::GameMap)
    locations = Dict{UInt, Vector{String}}()
    for (coord, placed) in gamemap.components
        walk_aliases!(placed.component, "component :$(placed.ship) $coord", Set{UInt}(), locations)
    end
    for (coord, placed) in gamemap.pipe_behaviors
        walk_aliases!(placed.pipe, "pipe :$(placed.ship) $coord", Set{UInt}(), locations)
    end
    warnings = String[]
    for (identity, references) in locations
        length(references) > 1 || continue
        push!(warnings, "mutable object $identity shared by " * join(references, ", "))
    end
    sort!(warnings)
    return warnings
end

function compare_maps(original::GameMap, generated::GameMap; tolerance::Float64 = COMPARISON_TOLERANCE)
    original_ships = Set(keys(original.ships))
    generated_ships = Set(keys(generated.ships))
    placement_mismatches, original_components, generated_components, original_pipes, generated_pipes = compare_placements(original, generated; tolerance)
    original_surfaces = surface_entries(original)
    generated_surfaces = surface_entries(generated)
    missing_elements, extra_elements, original_element_count, generated_element_count = compare_elements(original, generated; tolerance)
    missing_declarations, extra_declarations, original_declaration_count, generated_declaration_count = compare_declarations(original, generated; tolerance)
    source_aliases = alias_warnings(original)
    generated_aliases = alias_warnings(generated)
    return Dict{String, Any}(
        "ship_names_match" => original_ships == generated_ships,
        "original_ships" => sort!(collect(original_ships); by = string),
        "generated_ships" => sort!(collect(generated_ships); by = string),
        "component_count_match" => length(original_components) == length(generated_components),
        "original_component_count" => length(original_components),
        "generated_component_count" => length(generated_components),
        "pipe_count_match" => length(original_pipes) == length(generated_pipes),
        "original_pipe_count" => length(original_pipes),
        "generated_pipe_count" => length(generated_pipes),
        "placement_mismatches" => placement_mismatches,
        "surface_match" => original_surfaces == generated_surfaces,
        "original_surface_count" => length(original_surfaces),
        "generated_surface_count" => length(generated_surfaces),
        "missing_surfaces" => collect(setdiff(original_surfaces, generated_surfaces)),
        "extra_surfaces" => collect(setdiff(generated_surfaces, original_surfaces)),
        "elements_match" => isempty(missing_elements) && isempty(extra_elements),
        "original_element_count" => original_element_count,
        "generated_element_count" => generated_element_count,
        "missing_elements" => missing_elements,
        "extra_elements" => extra_elements,
        "declarations_match" => isempty(missing_declarations) && isempty(extra_declarations),
        "original_declaration_count" => original_declaration_count,
        "generated_declaration_count" => generated_declaration_count,
        "missing_declarations" => missing_declarations,
        "extra_declarations" => extra_declarations,
        "generated_aliases" => generated_aliases,
        "source_aliases" => source_aliases,
    )
end

function element_summary(element::AbsoluteElement)::String
    return "$(element.type) id=$(element.id) dependent=$(element.dependent_id) " *
        "$(element.connections.v1) ↔ $(element.connections.v2) value=$(element.value) active=$(element.active)"
end

function print_comparison_results(results::Dict{String, Any})
    println("MAP COMPARISON RESULTS")
    println("  Overall: $(results["perfect_match"] ? "PASS" : "FAIL")")
    println("  Ships: $(length(results["original_ships"])) original, $(length(results["generated_ships"])) generated — $(results["ship_names_match"] ? "PASS" : "FAIL")")
    println("  Components: $(results["original_component_count"]) original, $(results["generated_component_count"]) generated — $(results["component_count_match"] ? "PASS" : "FAIL")")
    println("  Pipes: $(results["original_pipe_count"]) original, $(results["generated_pipe_count"]) generated — $(results["pipe_count_match"] ? "PASS" : "FAIL")")
    println("  Surfaces: $(results["original_surface_count"]) original, $(results["generated_surface_count"]) generated — $(results["surface_match"] ? "PASS" : "FAIL")")
    println("  Circuit elements: $(results["original_element_count"]) original, $(results["generated_element_count"]) generated — $(results["elements_match"] ? "PASS" : "FAIL")")
    println("  Fluid declarations: $(results["original_declaration_count"]) original, $(results["generated_declaration_count"]) generated — $(results["declarations_match"] ? "PASS" : "FAIL")")
    println("  Generated mutable sharing: $(isempty(results["generated_aliases"]) ? "PASS" : "FAIL")")
    isempty(results["source_aliases"]) || println("  Warning: source map shares mutable state across placements ($(length(results["source_aliases"])) object(s))")

    for (title, values) in (("Placement mismatches", results["placement_mismatches"]), ("Missing surfaces", results["missing_surfaces"]), ("Extra surfaces", results["extra_surfaces"]))
        isempty(values) && continue
        println("\n$title:")
        for value in Iterators.take(values, 20)
            println("  ", value)
        end
        length(values) > 20 && println("  ... and $(length(values) - 20) more")
    end
    for (title, values) in (("Missing circuit elements", results["missing_elements"]), ("Extra circuit elements", results["extra_elements"]))
        isempty(values) && continue
        println("\n$title:")
        for value in Iterators.take(values, 20)
            println("  ", element_summary(value))
        end
        length(values) > 20 && println("  ... and $(length(values) - 20) more")
    end
    for (title, values) in (
            ("Missing fluid declarations", results["missing_declarations"]),
            ("Extra fluid declarations", results["extra_declarations"]),
            ("Generated alias failures", results["generated_aliases"]),
            ("Source alias warnings", results["source_aliases"]),
        )
        isempty(values) && continue
        println("\n$title:")
        for value in Iterators.take(values, 20)
            println("  ", value)
        end
        length(values) > 20 && println("  ... and $(length(values) - 20) more")
    end
    return nothing
end

function compare_map_files(original_map_input::String, generator_file::String)
    isfile(generator_file) || error("Generator file not found: $generator_file")
    function_name = validate_generator_name(generator_file)
    original_map = load_game_map(original_map_input)
    Base.include(RocketPlumber, abspath(generator_file))
    isdefined(RocketPlumber, function_name) || error(
        "Generator $(basename(generator_file)) must define top-level function $function_name()"
    )
    generator = Base.invokelatest(getfield, RocketPlumber, function_name)
    generated_map = Base.invokelatest(generator)
    generated_map isa GameMap || error(
        "$function_name() returned $(typeof(generated_map)); expected GameMap"
    )
    results = compare_maps(original_map, generated_map)
    results["perfect_match"] = results["ship_names_match"] &&
        results["component_count_match"] && results["pipe_count_match"] &&
        isempty(results["placement_mismatches"]) && results["surface_match"] &&
        isempty(results["missing_surfaces"]) && isempty(results["extra_surfaces"]) &&
        results["elements_match"] && results["declarations_match"] &&
        isempty(results["generated_aliases"])
    print_comparison_results(results)
    return results
end

function print_usage(io::IO = stdout)
    println(io, "Usage: julia --project=. .agents/skills/rocket-plumber-map-encoding/scripts/compare_maps.jl <map.jld2> <generator.jl>")
    println(io, "  The generator function must be top-level and named after its mapgen_ filename stem.")
end

function main()
    if any(argument -> argument in ("-h", "--help"), ARGS)
        print_usage()
        return nothing
    end
    length(ARGS) == 2 || begin
        print_usage(stderr)
        exit(1)
    end
    try
        results = compare_map_files(ARGS[1], ARGS[2])
        exit(results["perfect_match"] ? 0 : 1)
    catch error_value
        println(stderr, "Error: ", sprint(showerror, error_value))
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
