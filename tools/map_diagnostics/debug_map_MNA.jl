"""
    Map Circuit Diagnostic Tool — Rocket Plumber

Loads a .jld2 map file headlessly and runs one full simulation tick
(update_components! → update_map! → update_mna!) to diagnose circuit
issues such as singular A matrices in the MNA solver.

Produces a detailed report including:
  • Map summary (ships, components with state, pipes)
  • Full circuit element listing (pre-prune and post-prune)
  • MNA A matrix structure displayed in braille via display(sparse(A))
  • SVD-based rank analysis and null-space identification when singular
  • G-diagonal dump and voltage source listing

This script reuses the game's own loadmap() and JLD2 conversion functions
by including gameloop.jl and components.jl, so it stays in sync with any
future changes to the save format.

Usage:
    julia --project=. tools/map_diagnostics/debug_map_MNA.jl <mappath>

Example:
    julia --project=. tools/map_diagnostics/debug_map_MNA.jl maps/playtest1.jld2
"""

# ===============================================================
# Package Loading
# ===============================================================
#
# map_loading.jl has minimal dependencies (no GLFW, no rendering),
# so we only need the core game packages here.
# components.jl defines concrete component instances and
# encounter_system_config, which map_loading.jl's rconvert functions
# reference at load time.
# ===============================================================

using LinearAlgebra, StaticArrays, SparseArrays
using JLD2, Accessors

# Core game packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, HexFlowProcGen
using HexFlowControl, HexFlowCalculator
using SquirrelNoise

# Component packages — needed for JLD2 deserialisation of saved components
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents
using HexFlowPipeComponents, HexFlowBasicPipes

# ===============================================================
# Include Game Source Files
# ===============================================================
#
# components.jl defines concrete component instances and
# encounter_system_config (referenced by map_loading.jl's SpaceMapState rconvert).
#
# map_loading.jl defines loadmap(), _build_map_typemap(), and all
# JLD2.rconvert registrations for legacy map formats.
# ===============================================================

const _src_dir = normpath(joinpath(@__DIR__, "..", "..", "src"))
include(joinpath(_src_dir, "components.jl"))
include(joinpath(_src_dir, "map_loading.jl"))

# ===============================================================
# Element Display Helpers
# ===============================================================

"Convert an ElementTypes enum value to a human-readable string."
function element_type_name(t::HexElements.ElementTypes)::String
    t == HexElements.CONST_RESISTOR  && return "RESISTOR"
    t == HexElements.CONST_CURRENT   && return "CSOURCE"
    t == HexElements.CONST_VOLTAGE   && return "VSOURCE"
    t == HexElements.C_DEP_CURRENT   && return "CCCS"
    t == HexElements.V_DEP_VOLTAGE   && return "VCVS"
    return "UNKNOWN($(Int(t)))"
end

"""
Print a vector of AbsoluteElements with type, value, connections, and IDs.
Groups by element type and prints a count header first.
"""
function print_elements(elements::Vector{AbsoluteElement}; label::String = "Elements")
    type_counts = Dict{String, Int}()
    for e in elements
        tn = element_type_name(e.type)
        type_counts[tn] = get(type_counts, tn, 0) + 1
    end

    println("  $label: $(length(elements)) total")
    println("    ", join(["$t: $c" for (t, c) in sort(collect(type_counts))], "  "))

    for (i, e) in enumerate(elements)
        dep_str = e.dependent_id.index != 0 ? " dep=$(e.dependent_id)" : ""
        active_str = e.active ? "" : " INACTIVE"
        println("    [$i] $(element_type_name(e.type)) v=$(round(e.value, digits=4)) " *
                "$(e.connections.v1) → $(e.connections.v2)" *
                " id=$(e.id)$dep_str$active_str")
    end
end

# ===============================================================
# A Matrix Analysis
# ===============================================================

"""
Reconstruct and analyse the MNA A matrix from the current MNA_State.

Rebuilds the G, B, C, D sub-matrices from the split elements, then:
 1. Displays the full sparse A matrix using Julia's braille display
 2. Computes rank via SVD
 3. If singular, identifies the null-space nodes and voltage sources
 4. Prints the G diagonal and voltage source listing
"""
function analyse_A_matrix(mna_state::MNA_State)
    node_to_index = mna_state.node_to_index
    resistors     = mna_state.resistors
    csources      = mna_state.csources
    vsources      = mna_state.vsources
    vsource_lookup = mna_state.vsource_lookup

    num_nodes   = length(node_to_index)
    num_vsource = length(vsources)
    total_size  = num_nodes + num_vsource

    if total_size == 0
        println("\n  A matrix is empty (no nodes or voltage sources).")
        return nothing
    end

    println("\n===========================================================")
    println("A MATRIX ANALYSIS")
    println("===========================================================")
    println("  Nodes: $num_nodes    Voltage sources: $num_vsource    Total: $(total_size)×$(total_size)")

    #= ---------- G sub-matrix (N×N) — resistors only ----------- =#
    # Matches FlowEngine.jl MNA_getA: only CONST_RESISTOR elements are stamped into G.
    # CCCS elements are stamped into the B sub-matrix instead.
    G = zeros(num_nodes, num_nodes)
    for (_, element) in resistors
        conductance = element.value
        v1 = element.connections.v1
        v2 = element.connections.v2

        v1_idx = node_to_index[v1]
        G[v1_idx, v1_idx] += conductance

        if !is_grounded(v2)
            v2_idx = node_to_index[v2]
            G[v2_idx, v2_idx] += conductance
            G[v1_idx, v2_idx] -= conductance
            G[v2_idx, v1_idx] -= conductance
        end
    end

    #= ---------- pure_B sub-matrix (N×M) — vsource ±1 entries ----------- =#
    # Standard +1/−1 entries for ALL voltage sources (independent and dependent).
    pure_B = zeros(num_nodes, num_vsource)
    for (id, element) in vsources
        vs_idx = vsource_lookup[id]
        v1 = element.connections.v1
        v2 = element.connections.v2
        if !is_grounded(v1)
            pure_B[node_to_index[v1], vs_idx] = 1.0
        end
        if !is_grounded(v2)
            pure_B[node_to_index[v2], vs_idx] = -1.0
        end
    end

    #= ---------- B sub-matrix (N×M) — pure_B + CCCS modifications ----------- =#
    # CCCS (C_DEP_CURRENT) stamps go into B, modifying the column of the controlling
    # vsource at the CCCS's own terminal node rows. This matches the actual solver.
    B = copy(pure_B)
    for (_, element) in csources
        if element.type == HexElements.C_DEP_CURRENT
            dep_id = element.dependent_id
            if !haskey(vsource_lookup, dep_id)
                println("  ⚠ CCCS depends on non-vsource element $(dep_id) — skipping")
                continue
            end
            dep_vs_idx = vsource_lookup[dep_id]
            gain = element.value

            pos_node = element.connections.v1
            neg_node = element.connections.v2

            pos_idx = node_to_index[pos_node]
            B[pos_idx, dep_vs_idx] += gain

            if !is_grounded(neg_node)
                neg_idx = node_to_index[neg_node]
                B[neg_idx, dep_vs_idx] -= gain
            end
        end
    end

    #= ---------- C sub-matrix (M×N) — transpose(pure_B) + VCVS modifications ----------- =#
    # Base C comes from transposed pure_B. VCVS adds gain stamps for the dependent
    # element's terminals. Dependent element lookup searches all three dicts.
    C = copy(transpose(pure_B))
    for (id, element) in vsources
        if element.type == HexElements.V_DEP_VOLTAGE
            dep_id = element.dependent_id

            # Look up dependent element across all element dicts (matches actual solver)
            dep_element = if haskey(resistors, dep_id)
                resistors[dep_id]
            elseif haskey(csources, dep_id)
                csources[dep_id]
            elseif haskey(vsources, dep_id)
                vsources[dep_id]
            else
                println("  ⚠ VCVS depends on unknown element $(dep_id) — skipping")
                continue
            end

            vs_idx = vsource_lookup[id]

            # Stamp −gain at dependent element's v1, +gain at v2 (if not grounded)
            dep_v1 = dep_element.connections.v1
            if !is_grounded(dep_v1)
                C[vs_idx, node_to_index[dep_v1]] -= element.value
            end
            dep_v2 = dep_element.connections.v2
            if !is_grounded(dep_v2)
                C[vs_idx, node_to_index[dep_v2]] += element.value
            end
        end
    end

    #= ---------- D sub-matrix (M×M) — always zero ----------- =#
    D = zeros(num_vsource, num_vsource)

    # --- Assemble full A matrix (matching FlowEngine's hvcat order) ---
    A = hvcat((2, 2), G, B, C, D)
    A_sparse = sparse(A)

    # --- Display sparse structure in braille ---
    println("\n  Sparse A matrix structure (braille):")
    display(A_sparse)
    println()  # newline after display output

    # --- Rank analysis via SVD ---
    r = rank(A)
    nz = nnz(A_sparse)
    println("\n  Non-zeros: $nz / $(total_size^2)  ($(round(100*nz/max(total_size^2,1), digits=1))% dense)")
    println("  Rank: $r / $total_size")

    if r < total_size
        println("  ⚠  MATRIX IS SINGULAR (rank deficient by $(total_size - r))")
        svd_result = svd(A)
        tol = max(total_size, 1) * eps(maximum(svd_result.S))
        null_cols = findall(s -> s < tol, svd_result.S)
        println("  Near-zero singular values at indices: $null_cols")
        println("  Smallest singular values: $(round.(svd_result.S[max(1, end-4):end], sigdigits=4))")

        index_to_node = mna_state.index_to_node
        null_space_nodes = Set{NodeCoord}()

        for ci in null_cols
            null_vec = svd_result.Vt[ci, :]
            significant = findall(x -> abs(x) > 0.01, null_vec)
            println("\n  Null vector $ci — significant entries:")
            for idx in significant
                if idx <= num_nodes
                    node = index_to_node[idx]
                    push!(null_space_nodes, node)
                    println("    Node [$idx] = $node  (weight $(round(null_vec[idx], sigdigits=4)))")
                else
                    vs_idx = idx - num_nodes
                    vs_id = nothing
                    for (id, lookup_idx) in vsource_lookup
                        if lookup_idx == vs_idx
                            vs_id = id
                            break
                        end
                    end
                    println("    VSource [$vs_idx] = $vs_id  (weight $(round(null_vec[idx], sigdigits=4)))")
                end
            end
        end

        # Print all elements touching the null-space nodes for diagnosis
        if !isempty(null_space_nodes)
            println("\n  Elements touching null-space nodes:")
            all_elements_dict = merge(resistors, csources, vsources)
            for (id, element) in all_elements_dict
                v1 = element.connections.v1
                v2 = element.connections.v2
                v1_in = v1 in null_space_nodes
                v2_in = v2 in null_space_nodes || is_grounded(v2)
                if v1_in || (!is_grounded(v2) && v2 in null_space_nodes)
                    dep_str = element.dependent_id.index != 0 ? " dep=$(element.dependent_id)" : ""
                    grnd = is_grounded(v2) ? " [→GND]" : ""
                    marker_v1 = v1_in ? "★" : " "
                    marker_v2 = (!is_grounded(v2) && v2 in null_space_nodes) ? "★" : " "
                    println("    $(element_type_name(element.type)) v=$(round(element.value, digits=4)) " *
                            "$marker_v1$(v1) → $marker_v2$(v2)$grnd$dep_str  id=$id")
                end
            end
        end
    else
        println("  ✓ Matrix is full rank — LU decomposition will succeed")
    end

    # --- G diagonal (conductance sums per node) ---
    println("\n  G diagonal (conductance sums at each node):")
    for i in 1:num_nodes
        node = mna_state.index_to_node[i]
        val = G[i, i]
        flag = val == 0.0 ? "  ⚠ ZERO" : ""
        println("    [$i] $node : $(round(val, sigdigits=6))$flag")
    end

    # --- Voltage sources ---
    println("\n  Voltage sources:")
    for (id, element) in vsources
        idx = vsource_lookup[id]
        dep_str = element.dependent_id.index != 0 ? " (depends on $(element.dependent_id))" : ""
        grounded = is_grounded(element.connections.v2) ? " [grounded]" : " [floating]"
        println("    [$idx] $(element_type_name(element.type)) v=$(round(element.value, digits=4)) " *
                "$(element.connections.v1) → $(element.connections.v2)$dep_str$grounded")
    end

    return nothing
end

# ===============================================================
# Map Summary
# ===============================================================

"Print a detailed summary of the map's ships, components, and pipes."
function print_map_summary(gamemap::GameMap)
    println("\n===========================================================")
    println("MAP SUMMARY")
    println("===========================================================")

    ship_names = collect(keys(gamemap.ships))
    println("Ships: $(length(ship_names)) — $ship_names")
    println("Space map type: $(typeof(gamemap.space_map))")

    for (name, ship) in gamemap.ships
        n_comps = length(ship.components)
        n_pipes = length(ship.pipe_behaviors)
        n_tiles = length(ship.ship_tiles)
        println("\n  --- Ship :$name ---")
        println("  Surface tiles: $n_tiles    Components: $n_comps    Pipes: $n_pipes")
        println("  Docking status: $(typeof(ship.docking_status))")

        # List components with type, rotation, and key state info
        for (coord, comp_on_tile) in ship.components
            comp = comp_on_tile.component
            rot = comp_on_tile.rotation
            type_name = replace(string(typeof(comp)), r"^.*\." => "")

            extra = ""
            # Extract tank state when available
            if hasproperty(comp, :tank) && hasproperty(comp.tank, :tank) && hasproperty(comp.tank.tank, :state)
                tank = comp.tank.tank
                charge = round(tank.state.charge, digits=2)
                stalled = is_stalled(tank.stallstate)
                extra = " charge=$charge stalled=$stalled"
            elseif hasproperty(comp, :tank) && hasproperty(comp.tank, :state)
                tank = comp.tank
                charge = round(tank.state.charge, digits=2)
                stalled = is_stalled(tank.stallstate)
                extra = " charge=$charge stalled=$stalled"
            end
            # Extract pump energy when available
            if hasproperty(comp, :energy)
                energy = round(HexFlowPumpComponents.get_current_energy(comp.energy), digits=1)
                max_e = round(HexFlowPumpComponents.get_max_energy(comp.energy), digits=1)
                extra *= " energy=$energy/$max_e"
            end

            println("    $coord rot=$rot : $type_name$extra")
        end

        # Pipe type summary
        pipe_types = Dict{String, Int}()
        for (_, pipe) in ship.pipe_behaviors
            t = replace(string(typeof(pipe)), r"^.*\." => "")
            pipe_types[t] = get(pipe_types, t, 0) + 1
        end
        if !isempty(pipe_types)
            println("    Pipes: ", join(["$t×$c" for (t, c) in pipe_types], ", "))
        end
    end
end

# ===============================================================
# Simulation Pipeline
# ===============================================================

"""
Run one full simulation tick matching the real game loop order:
    update_components! → update_map! → update_mna!

Returns `(success, failed_step, exception)`.
On failure the function still populates derived/mna as far as possible
so that analyse_A_matrix can inspect the partial state.
"""
function run_simulation_tick!(gamemap::GameMap, derived::DerivedMapState,
                              mna::MNA_State, tick::Int64)

    # --- update_components! ---
    println("\n  Step 1: update_components!")
    try
        update_components!(gamemap, mna)
        println("  [✓] update_components! passed")
    catch e
        println("  [✗] update_components! FAILED: $e")
        return (false, "update_components!", e)
    end

    # --- update_map! (broken into sub-steps for diagnostics) ---
    println("  Step 2: update_map!")
    try
        find_ship_surface_edgetiles!(derived, gamemap)

        derived.allelements = list_elements(gamemap)
        derived.allnodes = list_nodes(derived.allelements)
        println("    All elements: $(length(derived.allelements))    All nodes: $(length(derived.allnodes))")

        # Iterative pruning loop (runs until hash-stable)
        derived.prunedelements = derived.allelements
        last_hash::UInt64 = 0
        prune_iters = 0
        while last_hash != hash(derived.prunedelements)
            derived.prunedelements = prune(derived.prunedelements)
            derived.prunedelements = ground_search(derived.prunedelements)
            last_hash = hash(derived.prunedelements)
            derived.prunedelements = clear_dangling_dependants(derived.prunedelements)
            prune_iters += 1
        end
        derived.prunednodes = list_nodes(derived.prunedelements)
        println("    After pruning ($prune_iters iters): $(length(derived.prunedelements)) elements    $(length(derived.prunednodes)) nodes")

        if !isempty(derived.prunednodes)
            derived.nodeprimefluidtags = fluidtag_nodes(derived, gamemap)
            build_node_connection_map!(derived)
            connect_fluidtags!(derived)
            mna.node_to_index, mna.index_to_node = MNA_indexnodes(derived)
            MNA_splitelements!(mna, derived)

            println("    Attempting MNA_getA (LU decomposition)...")
            mna.mat_A = MNA_getA(mna)
            println("  [✓] update_map! passed")
        else
            empty!(mna.node_voltages)
            empty!(mna.vsource_currents)
            empty!(mna.node_voltages_scaled)
            empty!(derived.nodeactualfluids)
            println("    Circuit empty — no pruned nodes, skipping MNA")
        end
    catch e
        println("  [✗] update_map! FAILED: $e")
        return (false, "update_map!", e)
    end

    # --- update_mna! (solve) ---
    if !isempty(derived.prunednodes)
        println("  Step 3: update_mna!")
        try
            mna.mat_Z = MNA_getZ(mna)
            mna.node_voltages, mna.vsource_currents = MNA_solve(mna)
            println("  [✓] update_mna! passed")
        catch e
            println("  [✗] update_mna! FAILED: $e")
            return (false, "update_mna!", e)
        end
    end

    return (true, "", nothing)
end

# ===============================================================
# Main
# ===============================================================

function main(args::Vector{String})
    if isempty(args)
        println("""
        Map Circuit Diagnostic Tool — Rocket Plumber

        Usage:
            julia --project=. tools/map_diagnostics/debug_map_MNA.jl <mappath>

        Loads a .jld2 map and runs one simulation tick to detect circuit
        issues. Prints map summary, element listing, and A matrix analysis.
        """)
        return 1
    end

    mappath = args[1]
    if !isfile(mappath)
        println("ERROR: File not found: $mappath")
        return 1
    end

    println("===========================================================")
    println("MAP CIRCUIT DIAGNOSTIC TOOL — Rocket Plumber")
    println("===========================================================")
    println("Map: $mappath")

    # --- Load map using the game's own loadmap() ---
    println("\nLoading map...")
    gamemap = loadmap(mappath)
    print_map_summary(gamemap)

    # --- Run one full simulation tick ---
    derived = DerivedMapState()
    mna = MNA_State()

    println("\n===========================================================")
    println("SIMULATION TICK (update_components! → update_map! → update_mna!)")
    println("===========================================================")

    success, fail_step, err = run_simulation_tick!(gamemap, derived, mna, Int64(1))

    # --- Always print element listings ---
    if !isempty(derived.allelements)
        println()
        print_elements(derived.allelements; label = "All elements (pre-prune)")
    end
    if !isempty(derived.prunedelements)
        println()
        print_elements(derived.prunedelements; label = "Pruned elements (post-prune)")
    end

    # --- A matrix analysis (runs on success AND failure if state is available) ---
    if !isempty(mna.node_to_index)
        try
            analyse_A_matrix(mna)
        catch ae
            println("\n  A matrix analysis failed: $ae")
        end
    end

    # --- Final verdict ---
    println("\n===========================================================")
    if success
        println("RESULT: PASSED — no circuit issues detected")
    else
        println("RESULT: FAILED at $fail_step")
        println("Exception: $err")
    end
    println("===========================================================")

    return success ? 0 : 1
end

exit(main(ARGS))
