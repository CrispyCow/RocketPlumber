using Test
using FlowMap
using HexFrame
using HexComponentsAPI
using StaticArrays

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
include(joinpath(dirname(dirname(dirname(@__DIR__))), "src", "timelapse.jl"))
include(joinpath(TOOL_DIR, "src", "TimelapseExportTool.jl"))
using .TimelapseExportTool

function options(arguments...)
    return parse_cli(["input.jld2", "--inspect", arguments...]; repository_root = normpath(joinpath(@__DIR__, "..", "..", "..")))
end

function map_with_tiles(tiles)
    return GameMap(
        surface_shiptags = Dict(tile => :primary for tile in tiles),
        ships = Dict(:primary => ShipState()),
    )
end

mutable struct TimelineTestCompBehav <: ComponentBehavior
    visible_state::Bool
end

mutable struct InterruptingTimelineCompBehav <: ComponentBehavior
    visible_state::Bool
end

"Raise an interrupt so timeline comparison tests cancellation propagation."
Base.isequal(::InterruptingTimelineCompBehav, ::InterruptingTimelineCompBehav) = throw(InterruptException())

function map_with_component(state::Bool; behaviour = TimelineTestCompBehav(state))
    gamemap = map_with_tiles([TileCoord(0, 0)])
    gamemap.components[TileCoord(0, 0)] = PlacedComponent(behaviour, HexFrame.Q_POS, :primary)
    return gamemap
end

@testset "CLI parsing and validation" begin
    defaults = parse_cli(["input.jld2", "--inspect"])
    @test defaults.format == :mp4
    @test (defaults.width, defaults.height, defaults.fps) == (1920, 1080, 30)
    gif = parse_cli(["input.jld2", "--inspect", "--output=movie.gif", "--resolution", "320X180", "--fps=15"])
    @test gif.format == :gif
    @test (gif.width, gif.height, gif.fps) == (320, 180, 15)
    @test parse_cli(["input.jld2", "--inspect", "-o", "movie.mp4"]).output == abspath("movie.mp4")
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--unknown"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--fps", "30", "--fps=30"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "extra"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--resolution", "321x180"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--format", "gif", "--crf", "20"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--camera", "manual"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--camera", "expand", "--viewport", "0,0,1,1"])
    manual = parse_cli(["input.jld2", "--inspect", "--camera=manual", "--viewport=-2,-3,4,5"])
    @test manual.viewport == (-2.0, -3.0, 4.0, 5.0)
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--padding", "NaN"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--keyframe-seconds", "0"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--fps", "241"])
    @test parse_cli(["--help"]).help
end

@testset "Output publication safety" begin
    mktempdir() do directory
        destination_directory = joinpath(directory, "existing_destination")
        mkpath(destination_directory)
        sentinel = joinpath(destination_directory, "sentinel.txt")
        open(sentinel, "w") do io
            write(io, "keep")
        end
        directory_options = parse_cli([
            "input.jld2", "--output", destination_directory, "--format", "mp4", "--force",
        ])
        @test_throws OutputError TimelapseExportTool.prepare_output_path!(directory_options)
        @test read(sentinel, String) == "keep"

        raced_output = joinpath(directory, "raced.mp4")
        raced_options = parse_cli(["input.jld2", "--output", raced_output])
        TimelapseExportTool.prepare_output_path!(raced_options)
        open(raced_output, "w") do io
            write(io, "race winner")
        end
        temporary_output = joinpath(directory, "temporary.mp4")
        open(temporary_output, "w") do io
            write(io, "encoded")
        end
        @test_throws OutputError TimelapseExportTool._publish_encoded_output!(temporary_output, raced_output, false)
        @test read(raced_output, String) == "race winner"
        @test read(temporary_output, String) == "encoded"

        replace_output = joinpath(directory, "replace.mp4")
        open(replace_output, "w") do io
            write(io, "old")
        end
        TimelapseExportTool._publish_encoded_output!(temporary_output, replace_output, true)
        @test read(replace_output, String) == "encoded"
        @test !ispath(temporary_output)
    end
end

@testset "FFmpeg stderr draining" begin
    child_code = "write(stderr, repeat(\"x\", 2 * 1024 * 1024)); write(stderr, \"TAIL_MARKER\\n\"); exit(9)"
    session = TimelapseExportTool._start_ffmpeg(`$(Base.julia_cmd()) --startup-file=no -e $child_code`)
    failure = try
        TimelapseExportTool._finish_ffmpeg!(session, "stderr test")
        nothing
    catch error
        error
    end
    @test failure isa OutputError
    @test occursin("TAIL_MARKER", failure.message)
    @test length(session.tail) <= TimelapseExportTool.FFMPEG_TAIL_BYTES

    early_exit_code = "write(stderr, \"EARLY_EXIT_MARKER\\n\"); exit(9)"
    early_session = TimelapseExportTool._start_ffmpeg(`$(Base.julia_cmd()) --startup-file=no -e $early_exit_code`)
    wait(early_session.process)
    early_failure = try
        TimelapseExportTool._write_ffmpeg_frame!(early_session, zeros(UInt8, 16), "early-exit test")
        nothing
    catch error
        error
    end
    @test early_failure isa OutputError
    @test occursin("EARLY_EXIT_MARKER", early_failure.message)
end

@testset "Bounds, aspect ratio, and camera schedules" begin
    empty_map = GameMap(surface_shiptags = Dict{TileCoord, Symbol}(), ships = Dict{Symbol, ShipState}())
    @test tile_area_bounds(empty_map) == WorldRect(-5.0, -5.0, 5.0, 5.0)
    one_tile = tile_area_bounds(map_with_tiles([TileCoord(0, 0)]))
    @test one_tile == WorldRect(-518 / 512, -449 / 512, 518 / 512, 449 / 512)
    offset_map = map_with_tiles([TileCoord(0, 0)])
    offset_map.ships[:primary] = ShipState(docking_status = ApproachingDockStat(
        AxialCoord(1000.0, -1000.0), AxialCoord(0.0, 0.0), 1.0,
    ))
    @test tile_area_bounds(offset_map) == one_tile
    @test padded_bounds(WorldRect(0.0, 0.0, 2.0, 4.0), 0.1, 2.0) == WorldRect(-2.0, -2.0, 4.0, 6.0)
    for ratio in ((320, 180), (180, 320), (240, 240))
        original = WorldRect(-2.0, -1.0, 3.0, 4.0)
        adjusted = aspect_expand(original, ratio...)
        @test adjusted.x_min <= original.x_min <= adjusted.x_max
        @test adjusted.y_min <= original.y_min <= adjusted.y_max
        @test isapprox((adjusted.x_max - adjusted.x_min) / (adjusted.y_max - adjusted.y_min), ratio[1] / ratio[2])
    end
    entries = [
        TimelineEntry(map_with_tiles([TileCoord(0, 0)]), "one", 1, false),
        TimelineEntry(map_with_tiles([TileCoord(5, 0)]), "two", 2, false),
        TimelineEntry(map_with_tiles([TileCoord(1, 0)]), "three", 3, false),
    ]
    expand = build_camera_schedule(entries, options("--resolution", "320x180"))
    @test expand[3].rect == expand[2].rect
    for index in 2:length(expand)
        @test expand[index].rect.x_min <= expand[index - 1].rect.x_min
        @test expand[index].rect.x_max >= expand[index - 1].rect.x_max
        @test expand[index].rect.y_min <= expand[index - 1].rect.y_min
        @test expand[index].rect.y_max >= expand[index - 1].rect.y_max
    end
    fixed = build_camera_schedule(entries, options("--camera", "fixed", "--resolution", "320x180"))
    @test all(view -> view.rect == fixed[1].rect, fixed)
    manual = build_camera_schedule(entries, options("--camera", "manual", "--viewport", "-2,-1,3,4", "--resolution", "180x320"))
    @test manual[1].rect.x_min <= -2 && manual[1].rect.x_max >= 3
    @test manual[1].rect.y_min <= -1 && manual[1].rect.y_max >= 4

    for resolution in ("320x180", "180x320")
        zero_padding = build_camera_schedule(
            [TimelineEntry(map_with_tiles([TileCoord(0, 0)]), "one", 1, false)],
            options("--resolution", resolution, "--padding", "0", "--min-padding", "0"),
        )
        viewport = only(zero_padding).rect
        @test viewport.x_min <= -518 / 512 && viewport.x_max >= 518 / 512
        @test viewport.y_min <= -449 / 512 && viewport.y_max >= 449 / 512
    end
end

@testset "Timeline assembly and policies" begin
    first_map = map_with_tiles([TileCoord(0, 0)])
    duplicate = deepcopy(first_map)
    later = map_with_tiles([TileCoord(2, 0)])
    current = map_with_tiles([TileCoord(4, 0)])
    bundle = GameMapBundle(current, TimelapseHistory(frames = [first_map, duplicate, later]))
    auto = assemble_timeline(bundle, options())
    @test length(auto.candidates) == 4
    @test length(auto.frames) == 3
    @test auto.frames[1].origin == "history frame 1"
    @test auto.frames[2].origin == "history frame 3"
    never = assemble_timeline(bundle, parse_cli(["input.jld2", "--inspect", "--include-current=never"]))
    @test length(never.frames) == 2
    always = assemble_timeline(GameMapBundle(first_map, TimelapseHistory(frames = [first_map])), parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(always.frames) == 2
    empty_history = GameMapBundle(first_map, TimelapseHistory(frames = GameMap[]))
    @test_throws ValidationError assemble_timeline(empty_history, parse_cli(["input.jld2", "--inspect"]))
    only_current = assemble_timeline(empty_history, parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(only_current.frames) == 1
    escape = GalaxyEscapeSpaceMap(SVector{2, Float64}(1.0, 0.0), 0.0, 0.0, first_map)
    escape_bundle = GameMapBundle(GameMap(space_map = escape), TimelapseHistory(frames = [first_map]))
    omitted = assemble_timeline(escape_bundle, parse_cli(["input.jld2", "--inspect"]))
    @test !omitted.current_appended
    @test_throws ValidationError assemble_timeline(escape_bundle, parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(assemble_timeline(bundle, parse_cli(["input.jld2", "--inspect", "--no-dedupe"])).frames) == 4

    stateful = map_with_component(true)
    stateful_copy = deepcopy(stateful)
    stateful_bundle = GameMapBundle(stateful_copy, TimelapseHistory(frames = [stateful]))
    stateful_timeline = assemble_timeline(stateful_bundle, options())
    @test length(stateful_timeline.candidates) == 1
    @test length(stateful_timeline.frames) == 1
    @test !stateful_timeline.current_appended

    changed_state = deepcopy(stateful)
    changed_state.components[TileCoord(0, 0)].component.visible_state = false
    changed_timeline = assemble_timeline(
        GameMapBundle(changed_state, TimelapseHistory(frames = [stateful])),
        options(),
    )
    @test length(changed_timeline.frames) == 2

    interrupting = map_with_component(true; behaviour = InterruptingTimelineCompBehav(true))
    @test_throws InterruptException TimelapseExportTool._render_relevant_equal(interrupting, deepcopy(interrupting))
end

@testset "Timing and deterministic animation ticks" begin
    timing = parse_cli(["input.jld2", "--inspect", "--keyframe-seconds", "0.1", "--start-hold", "0.2", "--end-hold", "0.3", "--fps", "15"])
    schedule = build_frame_schedule(2, timing)
    @test [frame.frame_count for frame in schedule.keyframes] == [5, 6]
    @test schedule.total_frames == 11
    @test schedule.duration_seconds == 11 / 15
    one = build_frame_schedule(1, timing)
    @test one.keyframes[1].frame_count == round(Int, 0.6 * 15)
    map = map_with_tiles([TileCoord(0, 0)])
    map.statistics.simulated_ticks = 120
    @test [animation_tick(map, frame, 15) for frame in 0:3] == [120, 124, 128, 132]
end

println("Time-lapse exporter pure tests passed")
