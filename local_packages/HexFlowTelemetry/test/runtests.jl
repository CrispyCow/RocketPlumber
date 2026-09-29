ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexFlowTelemetry

const telemetry_source_path = joinpath(dirname(pathof(HexFlowTelemetry)), "HexFlowTelemetry.jl")

const enabled_telemetry_source = replace(
    read(telemetry_source_path, String),
    "const gc_telemetry_enabled::Bool = false" => "const gc_telemetry_enabled::Bool = true",
)

const EnabledTelemetryTest = Module(:EnabledTelemetryTest)
Base.include_string(EnabledTelemetryTest, enabled_telemetry_source, "HexFlowTelemetry.jl")

const EnabledTelemetry = EnabledTelemetryTest.HexFlowTelemetry

@testset "GC telemetry diagnostics" begin
    @test_nowarn redirect_stdout(devnull) do
        for _ in 1:EnabledTelemetry.gc_interval
            EnabledTelemetry.print_gc_statistics()
        end
    end
end
