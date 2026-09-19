#=
Scope: Shared timing instrumentation and diagnostic output
Formatter: Runic
=#

module HexFlowTelemetry

using Printf
using TimerOutputs

# ===============================================================
# Exports
# ===============================================================

export render_loop_timer, flowcalc_loop_timer
export render_loop_diagnostic_config, flowcalc_loop_diagnostic_config
export handle_diagnostics, print_gc_statistics

# ===============================================================
# Thread Safety
# ===============================================================

"ReentrantLock to prevent interleaved console output when multiple threads print diagnostics"
const telemetry_print_lock = ReentrantLock()

# ===============================================================
# Timer Objects (owned by this package)
# ===============================================================

const render_loop_timer = TimerOutput()
const flowcalc_loop_timer = TimerOutput()

# ===============================================================
# Configuration
# ===============================================================

"Configuration for one diagnostic timer; each loop has its own instance"
struct DiagnosticConfig
    enabled::Bool
    timer::TimerOutput
    interval::Int
    name::String
end

# Per-loop timer configurations
const render_loop_diagnostic_config::DiagnosticConfig = DiagnosticConfig(
    false,
    render_loop_timer,
    1000,  # Frames
    "RENDER LOOP (Main Thread)",
)

const flowcalc_loop_diagnostic_config::DiagnosticConfig = DiagnosticConfig(
    false,
    flowcalc_loop_timer,
    500,  # Ticks
    "FLOW CALCULATOR LOOP (Background Thread)",
)

const gc_telemetry_enabled::Bool = false

# ===============================================================
# Diagnostic Printing
# ===============================================================

# Render-loop state
gc_frame_counter = 0
const gc_interval = 2000

"Print and reset a loop timer at its configured interval without interleaving output"
function handle_diagnostics(config::DiagnosticConfig, counter::Int64)
    if !config.enabled
        return nothing
    end

    if counter % config.interval != 0
        return nothing
    end

    # Print one uninterrupted report
    lock(telemetry_print_lock) do
        println("\n" * "="^100)
        println("$(config.name) - Counter: $counter")
        println("="^100)
        show(stdout, config.timer; compact = false, allocations = true, sortby = :time)
        println()
        println("="^100 * "\n")
    end

    # Begin the next measurement interval after releasing the output lock
    reset_timer!(config.timer)

    return nothing
end

"Print periodic garbage-collector statistics from the render loop"
function print_gc_statistics()
    global gc_frame_counter

    if !gc_telemetry_enabled
        return nothing
    end

    gc_frame_counter += 1
    if gc_frame_counter % gc_interval != 0
        return nothing
    end

    # Print one uninterrupted report
    lock(telemetry_print_lock) do
        println("\n" * "="^100)
        println("GARBAGE COLLECTOR STATISTICS - Frame: $gc_frame_counter")
        println("="^100)

        gc_stats = Base.gc_num()
        println("  Total GC time: $(@sprintf("%.4f", gc_stats.total_time / 1.0e9)) seconds")
        println("  Total allocations: $(@sprintf("%.2f", gc_stats.allocd / 1024 / 1024)) MB")
        println("  Total freed: $(@sprintf("%.2f", gc_stats.freed / 1024 / 1024)) MB")
        println("  GC runs (full): $(gc_stats.full_sweep)")
        println("  GC runs (partial): $(gc_stats.pause - gc_stats.full_sweep)")

        println("="^100 * "\n")
    end

    return nothing
end

end # module HexFlowTelemetry
