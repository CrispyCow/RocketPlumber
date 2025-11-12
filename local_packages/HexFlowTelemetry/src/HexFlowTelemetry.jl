module HexFlowTelemetry

using TimerOutputs
using Printf

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

"""
Configuration for diagnostic timing output for a single timer.
Each thread manages its own DiagnosticConfig instance.

Fields:
- `enabled`: Whether diagnostic printing is enabled
- `timer`: Reference to the TimerOutput object to monitor
- `interval`: Print diagnostics every N counts (frames, ticks, updates, etc.)
- `name`: Display name for the timer (shown in diagnostic output)
"""
struct DiagnosticConfig
    enabled::Bool
    timer::TimerOutput
    interval::Int
    name::String
end

# Pre-configured diagnostic instances for each timer
const render_loop_diagnostic_config::DiagnosticConfig = DiagnosticConfig(
    false,                               # disabled
    render_loop_timer,                   # timer
    1000,                                # interval (frames)
    "RENDER LOOP (Main Thread)"         # name
)

const flowcalc_loop_diagnostic_config::DiagnosticConfig = DiagnosticConfig(
    false,                               # disabled
    flowcalc_loop_timer,                 # timer
    500,                                 # interval (ticks)
    "FLOW CALCULATOR LOOP (Background Thread)"  # name
)

const gc_telemetry_enabled::Bool = false  # Global toggle for GC telemetry

# ===============================================================
# Diagnostic Printing
# ===============================================================

# Module-level counter for GC statistics (only accessed by render loop)
gc_frame_counter = 0
const gc_interval = 2000

"Handle diagnostic printing for a single timer. Thread-safe - call from any thread."
function handle_diagnostics(config::DiagnosticConfig, counter::Int64)
    # Check if diagnostics are enabled
    if !config.enabled
        return
    end

    # Check if it's time to print (stateless modulo check)
    if counter % config.interval != 0
        return
    end

    # Lock to prevent interleaved output from multiple threads
    lock(telemetry_print_lock) do
        println("\n" * "="^100)
        println("$(config.name) - Counter: $counter")
        println("="^100)
        show(stdout, config.timer; compact = false, allocations = true, sortby = :time)
        println()
        println("="^100 * "\n")
    end

    # Reset timer after printing (outside lock to minimize critical section)
    reset_timer!(config.timer)

    return nothing
end

"Print garbage collector statistics. Thread-safe - call from render loop only."
function print_gc_statistics()
    if !gc_telemetry_enabled
        return nothing
    end

    gc_frame_counter += 1
    if gc_frame_counter % gc_interval != 0
        return nothing
    end

    # Lock to prevent interleaved output
    lock(telemetry_print_lock) do
        println("\n" * "="^100)
        println("GARBAGE COLLECTOR STATISTICS - Frame: $(gc_frame_counter[])")
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
