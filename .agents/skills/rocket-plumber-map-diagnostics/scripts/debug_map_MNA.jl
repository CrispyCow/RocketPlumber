"""
    debug_map_MNA.jl <map-path> [ticks]

Load a saved map through current JLD2 upgrades and exercise the calculator's
component and solve APIs. Report generated elements and analyse FlowEngine's
canonical sparse MNA matrix. Ticks retain in-memory map and solver state; the
script does not emulate reactivation scheduling or the full game loop.
"""

using LinearAlgebra, SparseArrays
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, SquirrelNoise
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents, HexFlowBasicPipes
using HexFlowPersistence

function load_saved_map(path::String)::GameMap
    return HexFlowPersistence.loadmap_strict(path)
end

component_type_name(comp) = replace(string(typeof(comp)), r"^.*\." => "")
element_type_name(type::HexElements.ElementTypes) = string(type)

"Match an ElementID source hash against placements in this loaded map."
function build_element_source_index(gamemap::GameMap)::Dict{UInt64, Vector{String}}
    source_index = Dict{UInt64, Vector{String}}()
    for (coord, placed) in gamemap.components
        source = "component ship=$(placed.ship) tile=$coord $(component_type_name(placed.component))"
        push!(get!(source_index, hash(coord), String[]), source)
    end
    for (coord, placed) in gamemap.pipe_behaviors
        source = "pipe ship=$(placed.ship) edge=$coord $(component_type_name(placed.pipe))"
        push!(get!(source_index, hash(coord), String[]), source)
    end
    return source_index
end

function print_elements(elements::Vector{AbsoluteElement}, source_index::Dict{UInt64, Vector{String}}; label::String)
    println("  $label: $(length(elements))")
    for (index, element) in enumerate(elements)
        dependent = element.dependent_id.index == 0 ? "" : " depends=$(element.dependent_id)"
        active = element.active ? "" : " inactive"
        owners = join(get(source_index, element.id.map_source_hash, String[]), " | ")
        println("    [$index] $(element_type_name(element.type)) value=$(round(element.value; sigdigits=5)) " *
                "$(element.connections.v1) → $(element.connections.v2) id=$(element.id)$dependent$active source=$owners")
    end
end

function print_map_summary(gamemap::GameMap)
    println("\nMAP SUMMARY")
    println("Ships: $(collect(keys(gamemap.ships)))")
    println("Components: $(count_components(gamemap))    Pipes: $(count_pipes(gamemap))    Surface tiles: $(count_surface_tiles(gamemap))")
    for (name, ship) in gamemap.ships
        println("\nShip :$name — $(count_components(gamemap; ship_name = name)) components, $(count_pipes(gamemap; ship_name = name)) pipes, docking=$(typeof(ship.docking_status))")
        for (coord, placed) in gamemap.components
            placed.ship === name || continue
            println("  $coord rot=$(placed.rotation) mirrored=$(placed.mirrored) $(component_type_name(placed.component))")
        end
        pipe_types = Dict{String, Int}()
        for pipe in values(gamemap.pipe_behaviors)
            pipe.ship === name || continue
            label = replace(string(typeof(pipe.pipe)), r"^.*\." => "")
            pipe_types[label] = get(pipe_types, label, 0) + 1
        end
        isempty(pipe_types) || println("  Pipes: ", join(["$type×$count" for (type, count) in sort!(collect(pipe_types))], ", "))
    end
end

function print_activation_states(gamemap::GameMap)
    println("\nCOMPONENT STATE FLAGS")
    for (coord, placed) in get_components(gamemap)
        comp = placed.component
        flags = String[]
        if hasproperty(comp, :state) && hasproperty(comp.state, :auto_deactivation)
            push!(flags, "auto_deactivated=$(HexFlowBasicComponents.is_inactive(comp.state.auto_deactivation))")
        end
        if hasproperty(comp, :nozzle)
            nozzle = comp.nozzle
            hasproperty(nozzle, :deactivation) && push!(flags, "nozzle_inactive=$(HexFlowBasicComponents.is_inactive(nozzle.deactivation))")
            hasproperty(nozzle, :overheat) && push!(flags, "nozzle_damaged=$(HexFlowNozzleComponents.is_damaged(nozzle))")
        end
        if comp isa HexFlowPumpComponents.TurboPumpCompBehav
            push!(flags, "pump_inactive=$(HexFlowBasicComponents.is_inactive(comp.deactivation))")
            push!(flags, "pump_damaged=$(HexFlowBasicComponents.is_damaged(comp.overheat))")
            push!(flags, "temperature_k=$(round(HexFlowBasicComponents.get_component_temperature(comp.overheat); digits = 1))")
        end
        if hasproperty(comp, :switch) && hasproperty(comp.switch, :state)
            push!(flags, "switch=$(comp.switch.state)")
        end
        if comp isa HexFlowTankComponents.PressureFedTankCompBehav
            tank = comp.tank
            push!(flags, "liquid=$(tank.liquid_state.charge) gas=$(tank.gas_state.charge) liquid_sealed=$(HexFlowTankComponents.liquid_is_sealed(tank)) gas_sealed=$(HexFlowTankComponents.gas_is_sealed(tank)) stored=$(tank.stored_liquid.fluid)")
        elseif comp isa HexFlowTankComponents.ThevininTankCompBehav
            tank = comp.tank.tank
            push!(flags, "charge=$(tank.state.charge) sealed=$(HexFlowTankComponents.is_sealed(tank))")
        end
        isempty(flags) || println("  ship=$(placed.ship) $coord $(component_type_name(comp)): $(join(flags, " "))")
    end
end

"""Run the current base component and solve path once, retaining derived state on failure."""
function run_diagnostic_tick!(gamemap::GameMap, derived::DerivedMapState, mna::MNA_State, scratchpad::CalculatorScratchpad, tick::Int64, phase::Base.RefValue{String})
    phase[] = "update_components!"
    println("\nTick $tick: update_components!")
    update_components!(gamemap, mna, derived)
    println("  passed")

    # This is the current base-solve sequence used by solve_from_inputs!. It omits
    # the live loop's reactivation scan/trial and unrelated gameplay timing phases.
    phase[] = "collect_primary_map_inputs!"
    collect_primary_map_inputs!(gamemap, derived)
    println("  primary elements: $(length(derived.primaryelements)); primary nodes: $(length(derived.primarynodes))")
    phase[] = "update_map_from_inputs!"
    update_map_from_inputs!(derived, mna, scratchpad, tick)
    println("  filtered elements: $(length(derived.filteredelements)); filtered nodes: $(length(derived.filterednodes))")
    phase[] = "update_mna!"
    update_mna!(derived, mna, tick)
    phase[] = "compute_region_temperatures!"
    compute_region_temperatures!(derived, scratchpad, mna)
    phase[] = "complete"
    return nothing
end

"""Analyse the sparse A matrix built by FlowEngine, without re-stamping it locally."""
function analyse_A_matrix(mna::MNA_State, derived::DerivedMapState, source_index::Dict{UInt64, Vector{String}}; partial::Bool = false)
    if isempty(derived.filterednodes)
        println("\nA matrix is empty (no filtered circuit nodes or voltage sources).")
        return nothing
    end

    # The normal path uses exactly the sparse matrix factorised by the calculator.
    # A partial failure needs FlowEngine's canonical stamp/build API.
    A_sparse = partial ? MNA_buildA_sparse(mna) : mna.a_cache.mat_A_sparse
    size(A_sparse, 1) == 0 && (println("\nA matrix is empty (no nodes or voltage sources)." ); return nothing)
    A = Matrix(A_sparse)
    total_size = size(A, 1)
    num_nodes = length(mna.node_to_index)
    println(partial ? "\nMNA MATRIX (rebuilt from partial survivors; filtering may be incomplete)" : "\nMNA MATRIX (FlowEngine canonical cache)")
    println("  Nodes: $num_nodes    Voltage sources: $(length(mna.vsources))    Size: $(size(A))")
    println("  Non-zeros: $(nnz(A_sparse)) / $(length(A))")
    display(A_sparse)
    matrix_rank = rank(A)
    println("\n  Rank: $matrix_rank / $total_size")

    if matrix_rank < total_size
        println("  Rank deficient by $(total_size - matrix_rank). This identifies unconstrained directions, not a root cause by itself.")
        decomposition = svd(A)
        tolerance = max(size(A)...) * eps(maximum(decomposition.S))
        null_columns = findall(value -> value <= tolerance, decomposition.S)
        null_nodes = Set{NodeCoord}()
        println("  Smallest singular values: $(round.(decomposition.S[max(1, end - 4):end]; sigdigits = 4))")
        for column in null_columns
            vector = decomposition.Vt[column, :]
            println("  Null vector $column:")
            for index in findall(value -> abs(value) > 0.01, vector)
                if index <= num_nodes
                    node = mna.index_to_node[index]
                    push!(null_nodes, node)
                    println("    node $node: $(round(vector[index]; sigdigits = 4))")
                else
                    source_index = index - num_nodes
                    source_pairs = collect(pairs(mna.vsource_lookup))
                    source_pair_index = findfirst(pair -> last(pair) == source_index, source_pairs)
                    source_id = isnothing(source_pair_index) ? nothing : first(source_pairs[source_pair_index])
                    println("    voltage source index $source_index id=$source_id: $(round(vector[index]; sigdigits = 4))")
                end
            end
        end
        if !isempty(null_nodes)
            println("\n  Elements touching prominent null-vector nodes:")
            for element in derived.filteredelements
                if element.connections.v1 in null_nodes || element.connections.v2 in null_nodes
                    owners = join(get(source_index, element.id.map_source_hash, String[]), " | ")
                    dependent = element.dependent_id.index == 0 ? "" : " depends=$(element.dependent_id)"
                    println("    $(element_type_name(element.type)) $(element.connections.v1) → $(element.connections.v2) id=$(element.id)$dependent source=$owners")
                end
            end
        end
    else
        println("  Matrix has full numerical rank at Julia's rank tolerance.")
    end

    println("\n  G diagonal (conductance sum by node):")
    for index in 1:num_nodes
        println("    $(mna.index_to_node[index]): $(A[index, index])")
    end

    println("\n  Voltage sources:")
    for (id, element) in mna.vsources
        dependent = element.dependent_id.index == 0 ? "" : " depends=$(element.dependent_id)"
        owners = join(get(source_index, id.map_source_hash, String[]), " | ")
        println("    $id $(element_type_name(element.type)) $(element.connections.v1) → $(element.connections.v2) value=$(element.value)$dependent source=$owners")
    end
    return nothing
end

function main(args::Vector{String})::Int
    isempty(args) && (println("Usage: julia --project=. .agents/skills/rocket-plumber-map-diagnostics/scripts/debug_map_MNA.jl <map-path> [ticks]"); return 1)
    path = args[1]
    isfile(path) || (println("ERROR: File not found: $path"); return 1)
    ticks = length(args) >= 2 ? parse(Int, args[2]) : 1
    ticks > 0 || error("ticks must be positive")

    println("MAP CIRCUIT DIAGNOSTIC — BASE SOLVE APPROXIMATION")
    println("Map: $path    Ticks: $ticks")
    gamemap = load_saved_map(path)
    print_map_summary(gamemap)
    print_activation_states(gamemap)
    source_index = build_element_source_index(gamemap)

    derived = DerivedMapState()
    mna = MNA_State()
    scratchpad = CalculatorScratchpad()
    success = true
    failed_tick = 0
    failure = nothing
    phase = Ref("")
    matrix_ready = false
    partial_matrix = false
    for tick in 1:ticks
        matrix_ready = false
        try
            run_diagnostic_tick!(gamemap, derived, mna, scratchpad, Int64(tick), phase)
            matrix_ready = true
        catch error
            success = false
            failed_tick = tick
            failure = error
            println("\nTick $tick failed during $(phase[]): ", sprint(showerror, error))
            if phase[] == "update_map_from_inputs!" && !isempty(derived.filteredelements)
                # Canonical setup can fail while factorising A. Re-index current
                # survivors for inspection without duplicating the filter.
                try
                    list_nodes!(derived.filterednodes, derived.filteredelements)
                    MNA_indexnodes!(mna, derived)
                    MNA_splitelements!(mna, derived)
                    matrix_ready = true
                    partial_matrix = true
                catch setup_error
                    println("Partial MNA preparation failed: ", sprint(showerror, setup_error))
                end
            elseif phase[] == "update_mna!" || phase[] == "compute_region_temperatures!"
                matrix_ready = true
            end
            break
        end
    end

    println("\nELEMENTS AFTER CANONICAL FILTERING")
    print_elements(derived.primaryelements, source_index; label = "Generated elements before filtering")
    print_elements(derived.filteredelements, source_index; label = "Survivors after prune/ground/dependant filtering")
    if matrix_ready
        try
            analyse_A_matrix(mna, derived, source_index; partial = partial_matrix)
        catch error
            println("Matrix analysis could not complete: ", sprint(showerror, error))
            success = false
            isnothing(failure) && (failure = error)
        end
    else
        println("\nMNA matrix unavailable: failure occurred before current-tick MNA state was prepared.")
    end

    if success
        println("\nRESULT: Base solve completed for $ticks tick(s). No failure was reproduced on this map.")
    else
        location = failed_tick > 0 ? "at tick $failed_tick during $(phase[])" : "during matrix analysis"
        println("\nRESULT: Diagnostic failed $location: ", sprint(showerror, failure))
    end
    return success ? 0 : 1
end

exit(main(ARGS))
