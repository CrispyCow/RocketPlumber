#!/usr/bin/env julia

"""
Run the root application and every local package test suite in this repository.

The runner includes the root `RocketPlumber` project and discovers any directory
under `local_packages/` that contains both a `Project.toml` and
`test/runtests.jl`. It executes `Pkg.test()` for each target in a fresh Julia
process. Output for each target is captured to a dedicated log file, and the
runner only prints the full log when a target fails.
"""
module RunAllPackageTests

using Dates

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const LOCAL_PACKAGES_ROOT = joinpath(REPO_ROOT, "local_packages")
const LOGS_ROOT = joinpath(REPO_ROOT, "logs", "package_test_runs")

"Return the default worker count for parallel test execution."
default_jobs() = clamp(Sys.CPU_THREADS ÷ 2, 1, 6)

Base.@kwdef struct RunnerOptions
    jobs::Int = default_jobs()
    julia_threads::String = "1"
    instantiate::Bool = false
    list_only::Bool = false
    verbose_pass_logs::Bool = false
end

"Return a copy of RunnerOptions with selected fields replaced."
function updated_options(
    options::RunnerOptions;
    jobs::Int=options.jobs,
    julia_threads::String=options.julia_threads,
    instantiate::Bool=options.instantiate,
    list_only::Bool=options.list_only,
    verbose_pass_logs::Bool=options.verbose_pass_logs,
)
    return RunnerOptions(; jobs, julia_threads, instantiate, list_only, verbose_pass_logs)
end

Base.@kwdef struct TestTarget
    pkg_dir::String
    label::String
end

const ROOT_TEST_TARGET = TestTarget(; pkg_dir=REPO_ROOT, label="RocketPlumber")

mutable struct RunningTest
    target::TestTarget
    process::Base.Process
    log_io::IO
    log_path::String
    started_at::Float64
end

Base.@kwdef struct TestResult
    target::TestTarget
    success::Bool
    exit_code::Int
    elapsed_s::Float64
    log_path::String
end

function usage_text()
    return join([
        "Usage: julia tools/run_all_package_tests.jl [options]",
        "",
        "Options:",
        "  -j, --jobs <N>             Number of package tests to run in parallel.",
        "      --julia-threads <N>    JULIA_NUM_THREADS for each child test process.",
        "      --instantiate          Run Pkg.instantiate() in each test environment first.",
        "      --list                 Print discovered test suites and exit.",
        "      --verbose-pass-logs    Also print captured logs for passing test suites.",
        "  -h, --help                 Show this help text.",
    ], '\n')
end

function parse_int_arg(flag::AbstractString, value::AbstractString)
    parsed = tryparse(Int, value)
    parsed === nothing && error("$(flag) expects an integer, got $(repr(value))")
    parsed > 0 || error("$(flag) expects a positive integer, got $(parsed)")
    return parsed
end

function parse_args(args::Vector{String})
    options = RunnerOptions()
    index = 1

    while index <= length(args)
        arg = args[index]

        if arg in ("-h", "--help")
            println(usage_text())
            return nothing
        elseif arg in ("-j", "--jobs")
            index == length(args) && error("$(arg) requires a value")
            options = updated_options(options; jobs=parse_int_arg(arg, args[index + 1]))
            index += 1
        elseif startswith(arg, "--jobs=")
            options = updated_options(options; jobs=parse_int_arg("--jobs", String(split(arg, "=", limit=2)[2])))
        elseif arg == "--julia-threads"
            index == length(args) && error("$(arg) requires a value")
            options = updated_options(options; julia_threads=args[index + 1])
            index += 1
        elseif startswith(arg, "--julia-threads=")
            options = updated_options(options; julia_threads=String(split(arg, "=", limit=2)[2]))
        elseif arg == "--instantiate"
            options = updated_options(options; instantiate=true)
        elseif arg == "--list"
            options = updated_options(options; list_only=true)
        elseif arg == "--verbose-pass-logs"
            options = updated_options(options; verbose_pass_logs=true)
        else
            error("Unrecognised argument: $(arg)")
        end

        index += 1
    end

    return options
end

"Discover the root application and every local package with its own test suite."
function find_test_targets()
    isdir(LOCAL_PACKAGES_ROOT) || error("Could not find local_packages directory at $(LOCAL_PACKAGES_ROOT)")

    targets = TestTarget[]

    for (root, _dirs, files) in walkdir(LOCAL_PACKAGES_ROOT)
        "Project.toml" in files || continue
        isfile(joinpath(root, "test", "runtests.jl")) || continue
        push!(targets, TestTarget(; pkg_dir=normpath(root), label=relpath(root, REPO_ROOT)))
    end

    push!(targets, ROOT_TEST_TARGET)
    sort!(targets; by=target -> target.label)
    return targets
end

"Return a filesystem-safe log filename for a package label."
function log_filename(label::AbstractString)
    return replace(label, r"[^A-Za-z0-9._-]+" => "_") * ".log"
end

"Build the child Julia command used to execute one package test suite."
function build_test_cmd(target::TestTarget, options::RunnerOptions)
    test_code = options.instantiate ? "using Pkg; Pkg.instantiate(); Pkg.test()" : "using Pkg; Pkg.test()"
    cmd = Cmd(`$(Base.julia_cmd()) --project=$(target.pkg_dir) --startup-file=no --color=yes -e $(test_code)`; dir=target.pkg_dir)
    return addenv(cmd, "JULIA_NUM_THREADS" => options.julia_threads)
end

"Start one package test process and capture its output to a log file."
function start_test!(target::TestTarget, options::RunnerOptions, log_dir::AbstractString)
    log_path = joinpath(log_dir, log_filename(target.label))
    log_io = open(log_path, "w")
    try
        println(log_io, "=== Running ", target.label, " ===")
        println(log_io, "Started: ", Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS"))
        println(log_io, "Command: ", build_test_cmd(target, options))
        println(log_io)
        flush(log_io)

        process = run(pipeline(build_test_cmd(target, options); stdout=log_io, stderr=log_io); wait=false)
        return RunningTest(target, process, log_io, log_path, time())
    catch
        try
            close(log_io)
        catch
        end
        rethrow()
    end
end

"Finish a running package test and return its result."
function finish_test!(running::RunningTest)
    try
        wait(running.process)
        println(running.log_io)
        println(running.log_io, "Finished: ", Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS"))
        println(running.log_io, "Exit code: ", running.process.exitcode)
        flush(running.log_io)
    finally
        try
            close(running.log_io)
        catch
        end
    end

    return TestResult(
        ;
        target=running.target,
        success=running.process.exitcode == 0,
        exit_code=running.process.exitcode,
        elapsed_s=time() - running.started_at,
        log_path=running.log_path,
    )
end

"Stop active test processes and close their logs during exceptional exit."
function cleanup_active!(active::Vector{RunningTest})
    for running in active
        try
            process_exited(running.process) || kill(running.process)
        catch
        end
        try
            wait(running.process)
        catch
        end
        try
            isopen(running.log_io) && close(running.log_io)
        catch
        end
    end
    return nothing
end

"Print a readable summary for one completed test suite."
function report_result(result::TestResult; verbose_pass_logs::Bool=false)
    status = result.success ? "PASS" : "FAIL"
    println("[", status, "] ", result.target.label, " (", round(result.elapsed_s; digits=1), " s)")

    if !result.success || verbose_pass_logs
        log_contents = read(result.log_path, String)
        println("Log: ", result.log_path)
        println(repeat("-", 80))
        print(log_contents)
        endswith(log_contents, "\n") || println()
        println(repeat("-", 80))
    end

    return nothing
end

function run_tests(targets::Vector{TestTarget}, options::RunnerOptions)
    jobs = min(options.jobs, length(targets))
    timestamp = Dates.format(now(), dateformat"yyyy-mm-dd_HHMMSS")
    log_dir = joinpath(LOGS_ROOT, timestamp)
    mkpath(log_dir)

    println("Repository root: ", REPO_ROOT)
    println("Discovered ", length(targets), " package test suite", length(targets) == 1 ? "" : "s", ".")
    println("Parallel jobs: ", jobs)
    println("Child JULIA_NUM_THREADS: ", options.julia_threads)
    println("Logs directory: ", log_dir)

    pending = copy(targets)
    active = RunningTest[]
    results = TestResult[]

    try
        while !isempty(pending) || !isempty(active)
            while !isempty(pending) && length(active) < jobs
                target = popfirst!(pending)
                println("[RUN ] ", target.label)
                push!(active, start_test!(target, options, log_dir))
            end

            completed_indices = findall(running -> process_exited(running.process), active)

            if isempty(completed_indices)
                sleep(0.2)
                continue
            end

            for index in reverse(completed_indices)
                result = finish_test!(active[index])
                deleteat!(active, index)
                push!(results, result)
                report_result(result; verbose_pass_logs=options.verbose_pass_logs)
            end
        end
    catch
        cleanup_active!(active)
        rethrow()
    end

    sort!(results; by=result -> result.target.label)
    failures = filter(result -> !result.success, results)

    println()
    println("Summary: ", length(results) - length(failures), "/", length(results), " test suite", length(results) == 1 ? "" : "s", " passed.")

    if !isempty(failures)
        println("Failing suites:")
        for failure in failures
            println(" - ", failure.target.label, " (exit ", failure.exit_code, ")")
        end
        error("Package test run failed for $(length(failures)) suite(s).")
    end

    return nothing
end

function main(args::Vector{String}=String[])
    options = parse_args(args)
    options === nothing && return nothing

    targets = find_test_targets()
    isempty(targets) && error("No package test suites were found")

    if options.list_only
        println("Discovered ", length(targets), " package test suite", length(targets) == 1 ? "" : "s", ":")
        for target in targets
            println(" - ", target.label)
        end
        return nothing
    end

    run_tests(targets, options)
    return nothing
end

end # module RunAllPackageTests

is_direct_execution = !isempty(PROGRAM_FILE) && abspath(PROGRAM_FILE) == abspath(@__FILE__)
RunAllPackageTests.main(is_direct_execution ? ARGS : String[])
