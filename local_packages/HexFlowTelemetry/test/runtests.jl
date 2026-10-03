using Test
using HexFlowTelemetry
using TimerOutputs

# Capture real stdout without replacing the module or its runtime configuration.
function capture_diagnostics(config::HexFlowTelemetry.DiagnosticConfig, counter::Int)
    return mktemp() do _, io
        redirect_stdout(io) do
            handle_diagnostics(config, counter)
        end
        seekstart(io)
        read(io, String)
    end
end

@testset "Runtime telemetry" begin
    configs = (render_loop_diagnostic_config, flowcalc_loop_diagnostic_config)
    @test render_loop_diagnostic_config.timer === render_loop_timer
    @test flowcalc_loop_diagnostic_config.timer === flowcalc_loop_timer
    @test render_loop_diagnostic_config.interval == 1000
    @test flowcalc_loop_diagnostic_config.interval == 500

    @testset "Disabled by default" begin
        for config in configs
            @test !config.enabled
            @timeit config.timer "Disabled" zeros(100)
            @test isempty(collect(keys(config.timer)))
            @test isempty(capture_diagnostics(config, config.interval))
        end
        mktempdir() do directory
            report_directory = joinpath(directory, "telemetry")
            output = IOBuffer()
            @test isnothing(finish_telemetry!(; directory = report_directory, io = output))
            @test !ispath(report_directory)
            @test isempty(String(take!(output)))
        end
    end

    @testset "Independent warm-up, merging and partial intervals" begin
        start_telemetry!(true)
        expected_timers = (TimerOutput(), TimerOutput())
        for (config, expected_timer) in zip(configs, expected_timers)
            @test config.enabled
            @timeit config.timer "Warm-up only" begin
                @timeit config.timer "Nested" zeros(100)
            end
            @test isempty(capture_diagnostics(config, 0))
            @test isempty(capture_diagnostics(config, config.interval - 1))
            @test !config.warmup_complete
            live_output = capture_diagnostics(config, config.interval)
            @test occursin(config.name, live_output)
            @test occursin("warm-up", live_output)
            @test occursin("Warm-up only", live_output)
            @test occursin("~Warm-up only~", live_output)
            @test config.warmup_complete
            @test isempty(collect(keys(config.timer)))
            @test isempty(collect(keys(config.cumulative_timer)))

            # Paused calculators can revisit the same tick; do not print or reset again.
            @timeit config.timer "Work" begin
                zeros(200)
                @timeit config.timer "Nested" zeros(1000)
            end
            @test isempty(capture_diagnostics(config, config.interval))
            @test TimerOutputs.ncalls(config.timer["Work"]) == 1

            sample = copy(config.timer)
            TimerOutputs.complement!(sample)
            complement = sample["Work", "~Work~"]
            @test TimerOutputs.time(complement) == TimerOutputs.time(sample["Work"]) - TimerOutputs.time(sample["Work", "Nested"])
            @test TimerOutputs.allocated(complement) == TimerOutputs.allocated(sample["Work"]) - TimerOutputs.allocated(sample["Work", "Nested"])
            merge!(expected_timer, sample)
            live_output = capture_diagnostics(config, 2 * config.interval)
            @test !occursin("warm-up", live_output)
            @test occursin("~Work~", live_output)
            for label in ("Work", "Nested", "~Work~")
                section = label == "Work" ? config.cumulative_timer["Work"] : config.cumulative_timer["Work", label]
                expected = label == "Work" ? sample["Work"] : sample["Work", label]
                @test TimerOutputs.ncalls(section) == TimerOutputs.ncalls(expected)
                @test TimerOutputs.time(section) == TimerOutputs.time(expected)
                @test TimerOutputs.allocated(section) == TimerOutputs.allocated(expected)
                @test TimerOutputs.gctime(section) == TimerOutputs.gctime(expected)
            end

            @timeit config.timer "Work" zeros(1000)
            merge!(expected_timer, config.timer)
            capture_diagnostics(config, 3 * config.interval)
            @test TimerOutputs.ncalls(config.cumulative_timer["Work"]) == 2
            @timeit config.timer "Partial" begin
                @timeit config.timer "Nested" zeros(1000)
            end
            sample = copy(config.timer)
            TimerOutputs.complement!(sample)
            merge!(expected_timer, sample)
        end

        # Session shutdown collects a remainder; a new session restarts its counters.
        collect_telemetry!()
        for (config, expected_timer) in zip(configs, expected_timers)
            @test TimerOutputs.ncalls(config.cumulative_timer["Partial"]) == 1
            @test TimerOutputs.todict(config.cumulative_timer) == TimerOutputs.todict(expected_timer)
            @timeit config.timer "Work" zeros(1000)
            merge!(expected_timer, config.timer)
            @test !isempty(capture_diagnostics(config, config.interval))
            @test TimerOutputs.ncalls(config.cumulative_timer["Work"]) == 3
            @timeit config.timer "Final partial" begin
                @timeit config.timer "Nested" zeros(1000)
            end
            sample = copy(config.timer)
            TimerOutputs.complement!(sample)
            merge!(expected_timer, sample)
        end

        mktempdir() do directory
            output = IOBuffer()
            path = finish_telemetry!(; directory, io = output)
            @test isfile(path)
            @test dirname(path) == directory
            @test endswith(path, ".txt")
            report = read(path, String)
            @test startswith(String(take!(output)), "\n" * report)
            @test occursin("cumulative telemetry", report)
            @test occursin("Allocations", report)
            @test occursin("GC", report)
            @test occursin("avg", report)
            @test !occursin("Warm-up only", report)
            @test occursin("~Work~", report)
            @test occursin("~Partial~", report)
            @test occursin("~Final partial~", report)
            for (config, expected_timer) in zip(configs, expected_timers)
                @test occursin(config.name, report)
                @test !config.enabled
                @test TimerOutputs.ncalls(config.cumulative_timer["Final partial"]) == 1
                @test TimerOutputs.ncalls(config.cumulative_timer["Partial"]) == 1
                # Leaf-only Work intervals must not be added to the earlier complement at shutdown.
                @test TimerOutputs.todict(config.cumulative_timer) == TimerOutputs.todict(expected_timer)
                @timeit config.timer "Disabled after finish" zeros(100)
                @test isempty(collect(keys(config.timer)))
            end
            @test isnothing(finish_telemetry!(; directory, io = output))
            @test length(readdir(directory)) == 1
        end
    end

    @testset "Shutdown before either warm-up completes" begin
        start_telemetry!(true)
        @timeit render_loop_timer "Too early" zeros(100)
        @timeit flowcalc_loop_timer "Too early" zeros(100)
        capture_diagnostics(flowcalc_loop_diagnostic_config, 500)
        @timeit flowcalc_loop_timer "Calculator remainder" zeros(100)
        @test !render_loop_diagnostic_config.warmup_complete
        @test flowcalc_loop_diagnostic_config.warmup_complete

        mktempdir() do directory
            path = finish_telemetry!(; directory, io = IOBuffer())
            report = read(path, String)
            @test occursin("warm-up sample was not completed", report)
            @test !occursin("Too early", report)
            @test occursin("Calculator remainder", report)
            @test isempty(collect(keys(render_loop_diagnostic_config.cumulative_timer)))
        end
    end

    @testset "Fresh runs reset cumulative state" begin
        start_telemetry!(true)
        for config in configs
            @test !config.warmup_complete
            @test config.last_sample_counter == 0
            @test isempty(collect(keys(config.cumulative_timer)))
        end
        start_telemetry!()
        for config in configs
            @timeit config.timer "Disabled again" zeros(100)
            @test !config.enabled
            @test isempty(collect(keys(config.timer)))
        end
    end
end
