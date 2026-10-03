#=
Scope: Shared timing instrumentation and diagnostic output
Formatter: Runic
=#

module HexFlowTelemetry

using TimerOutputs

# ===============================================================
# Exports
# ===============================================================

export render_loop_timer, flowcalc_loop_timer
export render_loop_diagnostic_config, flowcalc_loop_diagnostic_config
export start_telemetry!, collect_telemetry!, finish_telemetry!, handle_diagnostics

# ===============================================================
# Timer State and Configuration
# ===============================================================

"Prevent interleaved console output from the render and calculator threads."
const telemetry_print_lock = ReentrantLock()

const render_loop_timer = TimerOutput()
const flowcalc_loop_timer = TimerOutput()
disable_timer!(render_loop_timer)
disable_timer!(flowcalc_loop_timer)

"Interval and cumulative timing state owned by one loop's task."
mutable struct DiagnosticConfig
    enabled::Bool
    const timer::TimerOutput
    const cumulative_timer::TimerOutput
    const interval::Int
    const name::String
    warmup_complete::Bool
    last_sample_counter::Int
end

const render_loop_diagnostic_config = DiagnosticConfig(
    false, render_loop_timer, TimerOutput(), 1000, "RENDER LOOP (Main Thread)", false, 0,
)
const flowcalc_loop_diagnostic_config = DiagnosticConfig(
    false, flowcalc_loop_timer, TimerOutput(), 500, "FLOW CALCULATOR LOOP (Background Thread)", false, 0,
)
const diagnostic_configs = (render_loop_diagnostic_config, flowcalc_loop_diagnostic_config)

# ===============================================================
# Runtime Sampling
# ===============================================================

"Reset timing state and choose runtime instrumentation before either loop starts."
function start_telemetry!(enabled::Bool = false)
    for config in diagnostic_configs
        reset_timer!(config.timer)
        reset_timer!(config.cumulative_timer)
        config.warmup_complete = false
        config.last_sample_counter = 0
        config.enabled = enabled
        if enabled
            enable_timer!(config.timer)
        else
            disable_timer!(config.timer)
        end
    end
    return nothing
end

"Print each periodic sample once, excluding the first sample from cumulative timings."
function handle_diagnostics(config::DiagnosticConfig, counter::Int)
    if !config.enabled
        return nothing
    end
    if counter <= 0 || counter % config.interval != 0 || counter == config.last_sample_counter
        return nothing
    end

    TimerOutputs.complement!(config.timer)
    lock(telemetry_print_lock) do
        warmup_label = config.warmup_complete ? "" : " (warm-up; excluded from final summary)"
        println("\n$(config.name) - Counter: $counter$warmup_label")
        print_timer(stdout, config.timer; allocations = true, gc = true, bars = false, sortby = :time)
    end

    if config.warmup_complete
        merge!(config.cumulative_timer, config.timer)
    else
        config.warmup_complete = true
        reset_timer!(config.cumulative_timer)
    end
    reset_timer!(config.timer)
    config.last_sample_counter = counter

    return nothing
end

"Collect eligible partial intervals after both loops stop, preserving totals across sessions."
function collect_telemetry!()
    for config in diagnostic_configs
        if config.enabled && config.warmup_complete
            TimerOutputs.complement!(config.timer)
            merge!(config.cumulative_timer, config.timer)
        end
        reset_timer!(config.timer)
        config.last_sample_counter = 0
    end
    return nothing
end

# ===============================================================
# Final Report
# ===============================================================

"Print and save the same cumulative report after all instrumented tasks have stopped."
function finish_telemetry!(; directory::String = joinpath(pwd(), "logs", "telemetry"), io::IO = stdout)
    if !any(config -> config.enabled, diagnostic_configs)
        return nothing
    end

    collect_telemetry!()
    for config in diagnostic_configs
        disable_timer!(config.timer)
        config.enabled = false
    end

    report_io = IOBuffer()
    println(report_io, "Rocket Plumber cumulative telemetry")
    println(report_io, "First periodic sample per stream excluded as warm-up; subsequent partial intervals included.")
    for config in diagnostic_configs
        println(report_io, "\n$(config.name)")
        if config.warmup_complete
            print_timer(report_io, config.cumulative_timer; allocations = true, gc = true, bars = false, sortby = :time)
        else
            println(report_io, "No cumulative measurements: warm-up sample was not completed.")
        end
    end
    report = String(take!(report_io))

    mkpath(directory)
    report_path = abspath(joinpath(directory, "telemetry-$(getpid())-$(time_ns()).txt"))
    write(report_path, report)
    lock(telemetry_print_lock) do
        print(io, '\n', report)
        println(io, "Telemetry report saved to: $report_path")
    end
    return report_path
end

end # module HexFlowTelemetry
