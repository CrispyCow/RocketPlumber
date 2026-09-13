struct ReconstructionContext
    derived
    mna
    scratchpad
    mna_snapshot
end

struct ReconstructionError <: ToolError
    message::String
    code::Int
end
ReconstructionError(message::AbstractString) = ReconstructionError(String(message), 4)

function create_reconstruction_context()
    flow_engine = Main.FlowEngine
    return ReconstructionContext(
        flow_engine.DerivedMapState(),
        flow_engine.MNA_State(),
        flow_engine.CalculatorScratchpad(),
        flow_engine.MNA_StateSnapshot(),
    )
end

"Synchronously derive one historical map without advancing or mutating it."
function reconstruct_keyframe!(context::ReconstructionContext, entry::TimelineEntry; retained_index::Union{Nothing, Int} = nothing, verbose::Bool = false)
    verbose && println("Reconstructing $(entry.origin)")
    try
        calculator = Main.HexFlowCalculator
        calculator.collect_primary_map_inputs!(entry.gamemap, context.derived)
        calculator.solve_from_inputs!(context.derived, context.mna, context.scratchpad, get_simulated_ticks(entry.gamemap))
        calculator.snapshot!(context.mna_snapshot, context.mna)
    catch error
        error isa InterruptException && rethrow()
        label = isnothing(entry.history_index) ? entry.origin : "history frame $(entry.history_index)"
        retained = isnothing(retained_index) ? "" : "retained keyframe $(retained_index), "
        throw(ReconstructionError("Failed to reconstruct $(retained)$(label): $(sprint(showerror, error))"))
    end
    return context
end
