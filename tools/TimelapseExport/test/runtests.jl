using Test
using FlowMap
using HexFrame
using HexComponentsAPI
using StaticArrays

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
include(joinpath(TOOL_DIR, "src", "TimelapseExportTool.jl"))
using .TimelapseExportTool

@testset "Lazy export runtime" begin
    @test !isdefined(TimelapseExportTool.Runtime, :GLFW)
    @test !isdefined(TimelapseExportTool.Runtime, :FFMPEG)
    @test !isdefined(TimelapseExportTool.Persistence, :HexFlowPersistence)
    @test TimelapseExportTool.main(["--help"]) == 0
    @test !isdefined(TimelapseExportTool.Runtime, :GLFW)
    @test !isdefined(TimelapseExportTool.Persistence, :HexFlowPersistence)
end

@kwdef struct TestTimelapseHistory
    frames::Vector{GameMap}
end

struct TestMapBundle
    gamemap::GameMap
    timelapse::TestTimelapseHistory
end

function options(arguments...)
    return parse_cli(["input.jld2", "--inspect", arguments...]; repository_root = normpath(joinpath(@__DIR__, "..", "..", "..")))
end

function map_with_tiles(tiles)
    return GameMap(
        surface_shiptags = Dict(tile => :primary for tile in tiles),
        ships = Dict(:primary => ShipState()),
    )
end

struct TimelineTestCompBehav <: ComponentBehavior
    visible_state::Bool
end

struct InterruptingTimelineCompBehav <: ComponentBehavior
    visible_state::Bool
end

"Raise an interrupt so timeline comparison tests cancellation propagation."
Base.isequal(::InterruptingTimelineCompBehav, ::InterruptingTimelineCompBehav) = throw(InterruptException())

function map_with_component(state::Bool; behaviour = TimelineTestCompBehav(state))
    gamemap = map_with_tiles([TileCoord(0, 0)])
    gamemap.components[TileCoord(0, 0)] = PlacedComponent(behaviour, HexFrame.Q_POS, :primary)
    return gamemap
end

@testset "Rendering asset lookup" begin
    rendering_package = dirname(dirname(Base.find_package("HexFlowRendering")))
    shader_dir = joinpath(rendering_package, "assets", "shaders")
    texture_atlas_dir = joinpath(rendering_package, "assets", "texture_atlas")
    @test isfile(joinpath(shader_dir, "BaseTile.vert"))
    @test isfile(joinpath(shader_dir, "BaseTile.frag"))
    @test isfile(joinpath(shader_dir, "BaseTile_LiquidEffect.frag"))
    @test isfile(joinpath(shader_dir, "BaseTile_GasEffect.frag"))
    @test isfile(joinpath(texture_atlas_dir, "TileTextureAtlas1.png"))
    @test isfile(joinpath(texture_atlas_dir, "TileTextureAtlas1.json"))
end

@testset "CLI parsing and validation" begin
    defaults = parse_cli(["input.jld2", "--inspect"])
    @test defaults.format == :mp4
    @test defaults.camera == :expand
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
    fit = options("--camera", "fit", "--padding", "0.2", "--min-padding", "1")
    @test (fit.camera, fit.padding, fit.min_padding) == (:fit, 0.2, 1.0)
    @test options("--camera=fit").camera == :fit
    @test options("--camera=smooth").camera == :smooth
    @test_throws UsageError options("--camera", "unknown")
    @test_throws UsageError options("--camera", "fit", "--viewport", "0,0,1,1")
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--camera", "expand", "--viewport", "0,0,1,1"])
    manual = parse_cli(["input.jld2", "--inspect", "--camera=manual", "--viewport=-2,-3,4,5"])
    @test manual.viewport == (-2.0, -3.0, 4.0, 5.0)
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--padding", "NaN"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--keyframe-seconds", "0"])
    @test_throws UsageError parse_cli(["input.jld2", "--inspect", "--fps", "241"])
    @test parse_cli(["--help"]).help
end

function centred_bounds(half_size::Real; centre_x::Real = 0.0, centre_y::Real = 0.0)
    return WorldRect(centre_x - half_size, centre_y - half_size, centre_x + half_size, centre_y + half_size)
end

function viewport_centre(viewport::CameraViewport)
    rect = viewport.rect
    return ((rect.x_min + rect.x_max) / 2.0, (rect.y_min + rect.y_max) / 2.0)
end

viewport_half_height(viewport::CameraViewport) = (viewport.rect.y_max - viewport.rect.y_min) / 2.0

function viewport_contains(viewport::CameraViewport, bounds::WorldRect; tolerance::Float64 = 1.0e-10)
    rect = viewport.rect
    return rect.x_min <= bounds.x_min + tolerance && rect.x_max >= bounds.x_max - tolerance &&
        rect.y_min <= bounds.y_min + tolerance && rect.y_max >= bounds.y_max - tolerance
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

@testset "Independent fit camera" begin
    small = map_with_tiles([TileCoord(0, 0)])
    large = deepcopy(small)
    large.surface_shiptags[TileCoord(40, 20)] = :secondary
    large.ships[:secondary] = ShipState()
    moved = map_with_tiles([TileCoord(-20, -10)])
    offset = deepcopy(moved)
    offset.ships[:primary] = ShipState(docking_status = ApproachingDockStat(
        AxialCoord(1000.0, -1000.0), AxialCoord(0.0, 0.0), 1.0,
    ))
    entries = [
        TimelineEntry(gamemap, "fit frame $index", index, false)
        for (index, gamemap) in enumerate([small, large, small, moved, offset, GameMap()])
    ]

    for resolution in ("240x240", "320x180", "180x320"), padding in ((0.0, 0.0), (0.2, 1.0))
        fit_options = options(
            "--camera", "fit", "--resolution", resolution,
            "--padding", string(padding[1]), "--min-padding", string(padding[2]),
        )
        fit = build_camera_schedule(entries, fit_options)
        @test fit[2].zoom < fit[1].zoom
        @test fit[3].zoom > fit[2].zoom
        @test fit[3] == fit[1]
        @test fit[4].zoom ≈ fit[3].zoom
        @test fit[4].view_x != fit[3].view_x
        @test fit[4].view_y != fit[3].view_y
        @test fit[5] == fit[4]

        for (entry, viewport) in zip(entries, fit)
            padded = padded_bounds(tile_area_bounds(entry.gamemap), fit_options.padding, fit_options.min_padding)
            rect = viewport.rect
            @test rect.x_min <= padded.x_min && rect.x_max >= padded.x_max
            @test rect.y_min <= padded.y_min && rect.y_max >= padded.y_max
            @test (rect.x_max - rect.x_min) / (rect.y_max - rect.y_min) ≈ fit_options.width / fit_options.height
            @test viewport.view_x ≈ -(padded.x_min + padded.x_max) / 2 atol = 1.0e-5
            @test viewport.view_y ≈ -(padded.y_min + padded.y_max) / 2 atol = 1.0e-5
            @test viewport == only(build_camera_schedule([entry], fit_options))
        end
    end
end

@testset "Smooth offline camera planning" begin
    constant_bounds = fill(centred_bounds(3.0; centre_x = 2.0, centre_y = -1.0), 6)
    constant_plan = build_smooth_camera_plan(constant_bounds, 1000, 1000)
    constant_views = [evaluate_camera(constant_plan, position) for position in range(0.0, 6.0; length = 49)]
    constant_centre = viewport_centre(constant_views[1])
    @test all(view -> all(viewport_centre(view) .≈ constant_centre) &&
        viewport_half_height(view) ≈ viewport_half_height(constant_views[1]), constant_views)

    growing_bounds = [centred_bounds(size) for size in 1.0:5.0]
    growing_plan = build_smooth_camera_plan(growing_bounds, 1000, 1000)
    growing_sizes = [viewport_half_height(evaluate_camera(growing_plan, position)) for position in range(0.0, 5.0; length = 51)]
    @test all(diff(growing_sizes) .>= -1.0e-10)
    @test growing_sizes[end] > growing_sizes[1]

    shrinking_bounds = reverse(growing_bounds)
    shrinking_plan = build_smooth_camera_plan(shrinking_bounds, 1000, 1000)
    shrinking_sizes = [viewport_half_height(evaluate_camera(shrinking_plan, position)) for position in range(0.0, 5.0; length = 51)]
    @test all(diff(shrinking_sizes) .<= 1.0e-10)
    @test shrinking_sizes[end] < shrinking_sizes[1]

    alternating_bounds = [centred_bounds(size) for size in (1.0, 5.0, 1.0, 5.0, 1.0, 5.0, 1.0)]
    alternating_plan = build_smooth_camera_plan(alternating_bounds, 1000, 1000)
    alternating_sizes = [viewport_half_height(evaluate_camera(alternating_plan, position)) for position in range(0.0, 7.0; length = 71)]
    @test extrema(alternating_sizes)[2] - extrema(alternating_sizes)[1] < 0.25 * (5.0 - 1.0)

    pulsed_bounds = [centred_bounds(index in (11, 21, 31) ? 5.0 : 1.0) for index in 1:41]
    pulsed_plan = build_smooth_camera_plan(pulsed_bounds, 1000, 1000)
    pulsed_sizes = [viewport_half_height(evaluate_camera(pulsed_plan, position)) for position in 10.0:0.5:30.0]
    @test minimum(pulsed_sizes) > 0.75 * maximum(pulsed_sizes)

    sudden_growth = [centred_bounds(size) for size in (1.0, 1.0, 1.0, 8.0, 8.0)]
    growth_plan = build_smooth_camera_plan(sudden_growth, 1000, 1000)
    @test viewport_half_height(evaluate_camera(growth_plan, 1.5; keyframe_index = 2)) > 1.0
    @test viewport_contains(evaluate_camera(growth_plan, 3.0; keyframe_index = 3), sudden_growth[4])

    sudden_shrink = reverse(sudden_growth)
    shrink_plan = build_smooth_camera_plan(sudden_shrink, 1000, 1000)
    before_shrink = viewport_half_height(evaluate_camera(shrink_plan, 2.9999; keyframe_index = 3))
    after_shrink = viewport_half_height(evaluate_camera(shrink_plan, 3.0001; keyframe_index = 4))
    @test after_shrink ≈ before_shrink rtol = 1.0e-4
    @test after_shrink > 4.0

    # The PCHIP trajectory carries velocity through ordinary snapshot boundaries.
    moving_bounds = [centred_bounds(size; centre_x = index - 1.0) for (index, size) in enumerate(1.0:5.0)]
    moving_plan = build_smooth_camera_plan(moving_bounds, 1000, 1000)
    epsilon = 1.0e-5
    for boundary in 1:4
        left = evaluate_camera(moving_plan, boundary - epsilon; keyframe_index = boundary)
        at = evaluate_camera(moving_plan, boundary; keyframe_index = boundary)
        right = evaluate_camera(moving_plan, boundary + epsilon; keyframe_index = boundary + 1)
        left_centre = viewport_centre(left)[1]
        at_centre = viewport_centre(at)[1]
        right_centre = viewport_centre(right)[1]
        @test (at_centre - left_centre) / epsilon ≈ (right_centre - at_centre) / epsilon rtol = 2.0e-4 atol = 1.0e-4
        @test (viewport_half_height(at) - viewport_half_height(left)) / epsilon ≈
            (viewport_half_height(right) - viewport_half_height(at)) / epsilon rtol = 2.0e-4 atol = 1.0e-4
    end

    varied_bounds = [
        centred_bounds(1.0; centre_x = -4.0, centre_y = 1.0),
        centred_bounds(5.0; centre_x = 3.0, centre_y = -2.0),
        centred_bounds(2.0; centre_x = 8.0, centre_y = 4.0),
    ]
    for resolution in ((1600, 900), (900, 1600), (1000, 1000))
        plan = build_smooth_camera_plan(varied_bounds, resolution...)
        for keyframe_index in eachindex(varied_bounds), fraction in range(0.0, 1.0; length = 21)
            position = keyframe_index - 1 + fraction
            viewport = evaluate_camera(plan, position; keyframe_index = keyframe_index)
            @test viewport_contains(viewport, varied_bounds[keyframe_index])
            @test (viewport.rect.x_max - viewport.rect.x_min) / (viewport.rect.y_max - viewport.rect.y_min) ≈ resolution[1] / resolution[2]
        end
    end

    one_plan = build_smooth_camera_plan([centred_bounds(2.0; centre_x = 4.0)], 1000, 1000)
    @test evaluate_camera(one_plan, 0.0).rect == evaluate_camera(one_plan, 1.0).rect
    two_bounds = [centred_bounds(1.0; centre_x = -3.0), centred_bounds(4.0; centre_x = 5.0)]
    two_plan = build_smooth_camera_plan(two_bounds, 1000, 1000)
    @test viewport_contains(evaluate_camera(two_plan, 1.0; keyframe_index = 1), two_bounds[1])
    @test viewport_contains(evaluate_camera(two_plan, 1.0; keyframe_index = 2), two_bounds[2])
    settled_view = evaluate_camera(two_plan, 3.0; keyframe_index = 2)
    @test viewport_centre(settled_view) == (5.0, 0.0)
    @test viewport_half_height(settled_view) == 4.0
    almost_settled_view = evaluate_camera(two_plan, 3.0 - 1.0e-5; keyframe_index = 2)
    @test abs(viewport_centre(settled_view)[1] - viewport_centre(almost_settled_view)[1]) < 1.0e-8
    @test abs(viewport_half_height(settled_view) - viewport_half_height(almost_settled_view)) < 1.0e-8

    fast_options = options("--camera", "smooth", "--fps", "60", "--keyframe-seconds", "0.1", "--start-hold", "0", "--end-hold", "0")
    slow_options = options("--camera", "smooth", "--fps", "60", "--keyframe-seconds", "0.5", "--start-hold", "0", "--end-hold", "0")
    fast_frame = build_frame_schedule(3, fast_options).keyframes[2]
    slow_frame = build_frame_schedule(3, slow_options).keyframes[2]
    fast_position = camera_timeline_position(fast_frame, 2, fast_options)
    slow_position = camera_timeline_position(slow_frame, 10, slow_options)
    @test fast_position ≈ slow_position
    playback_plan = build_smooth_camera_plan(varied_bounds, 1000, 1000)
    fast_view = evaluate_camera(playback_plan, fast_position)
    slow_view = evaluate_camera(playback_plan, slow_position)
    @test all(viewport_centre(fast_view) .≈ viewport_centre(slow_view))
    @test viewport_half_height(fast_view) ≈ viewport_half_height(slow_view)

    held_options = options("--camera", "smooth", "--fps", "10", "--keyframe-seconds", "0.2", "--start-hold", "0.3", "--end-hold", "0.4")
    held_schedule = build_frame_schedule(2, held_options)
    @test all(camera_timeline_position(held_schedule.keyframes[1], local_frame, held_options) == 0.0 for local_frame in 0:3)
    @test all(camera_timeline_position(held_schedule.keyframes[2], local_frame, held_options) == 2.0 for local_frame in 2:5)
    @test camera_timeline_position(two_plan, held_schedule.keyframes[2], 0, held_options) == 1.0
    @test camera_timeline_position(two_plan, held_schedule.keyframes[2], 1, held_options) == 1.5
    @test camera_timeline_position(two_plan, held_schedule.keyframes[2], 2, held_options) == 2.0
    @test camera_timeline_position(two_plan, held_schedule.keyframes[2], 3, held_options) == 2.5
    @test all(camera_timeline_position(two_plan, held_schedule.keyframes[2], local_frame, held_options) == 3.0 for local_frame in 4:5)
end

@testset "Smooth camera isolated scale peak" begin
    bounds = [centred_bounds(index == 40 ? 8.0 : 1.0) for index in 1:80]
    plan = build_smooth_camera_plan(bounds, 1000, 1000)
    sizes = [viewport_half_height(evaluate_camera(plan, position)) for position in 0.0:0.25:80.0]

    # Limit relative changes over one snapshot, including between interpolation knots.
    previous_sizes = sizes[1:(end - 4)]
    following_sizes = sizes[5:end]
    relative_changes = max.(following_sizes ./ previous_sizes, previous_sizes ./ following_sizes)
    @test maximum(relative_changes) < 1.25
end

@testset "Timeline assembly and policies" begin
    first_map = map_with_tiles([TileCoord(0, 0)])
    duplicate = deepcopy(first_map)
    later = map_with_tiles([TileCoord(2, 0)])
    current = map_with_tiles([TileCoord(4, 0)])
    bundle = TestMapBundle(current, TestTimelapseHistory(frames = [first_map, duplicate, later]))
    auto = assemble_timeline(bundle, options())
    @test length(auto.candidates) == 4
    @test length(auto.frames) == 3
    @test auto.frames[1].origin == "history frame 1"
    @test auto.frames[2].origin == "history frame 3"
    never = assemble_timeline(bundle, parse_cli(["input.jld2", "--inspect", "--include-current=never"]))
    @test length(never.frames) == 2
    always = assemble_timeline(TestMapBundle(first_map, TestTimelapseHistory(frames = [first_map])), parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(always.frames) == 2
    empty_history = TestMapBundle(first_map, TestTimelapseHistory(frames = GameMap[]))
    @test_throws ValidationError assemble_timeline(empty_history, parse_cli(["input.jld2", "--inspect"]))
    only_current = assemble_timeline(empty_history, parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(only_current.frames) == 1
    escape = GalaxyEscapeSpaceMap(SVector{2, Float64}(1.0, 0.0), 0.0, 0.0, first_map)
    escape_bundle = TestMapBundle(GameMap(space_map = escape), TestTimelapseHistory(frames = [first_map]))
    omitted = assemble_timeline(escape_bundle, parse_cli(["input.jld2", "--inspect"]))
    @test !omitted.current_appended
    @test_throws ValidationError assemble_timeline(escape_bundle, parse_cli(["input.jld2", "--inspect", "--include-current=always"]))
    @test length(assemble_timeline(bundle, parse_cli(["input.jld2", "--inspect", "--no-dedupe"])).frames) == 4

    stateful = map_with_component(true)
    stateful_copy = deepcopy(stateful)
    stateful_bundle = TestMapBundle(stateful_copy, TestTimelapseHistory(frames = [stateful]))
    stateful_timeline = assemble_timeline(stateful_bundle, options())
    @test length(stateful_timeline.candidates) == 1
    @test length(stateful_timeline.frames) == 1
    @test !stateful_timeline.current_appended

    changed_state = map_with_component(false)
    changed_timeline = assemble_timeline(
        TestMapBundle(changed_state, TestTimelapseHistory(frames = [stateful])),
        options(),
    )
    @test length(changed_timeline.frames) == 2

    interrupting = map_with_component(true; behaviour = InterruptingTimelineCompBehav(true))
    # Different values reach custom equality rather than identical-value short-circuiting
    different_state = map_with_component(false; behaviour = InterruptingTimelineCompBehav(false))
    @test_throws InterruptException TimelapseExportTool._render_relevant_equal(interrupting, different_state)
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

# Concrete behaviour registration has a transitive GLFW dependency; these tests use no window.
ENV["JULIA_GLFW_PLATFORM"] = "null"
TimelapseExportTool.load_persistence!()

@testset "Saved history validation before rendering" begin
    persistence = TimelapseExportTool.Persistence.HexFlowPersistence

    mktempdir() do directory
        gamemap = map_with_tiles([TileCoord(0, 0)])
        map_only_path = joinpath(directory, "map_only.jld2")
        persistence.savemap(gamemap, map_only_path; game_version = v"0.1.0")
        @test_throws ValidationError TimelapseExportTool._run_with_persistence(parse_cli([map_only_path, "--inspect"]))

        valid_path = joinpath(directory, "history.jld2")
        history = persistence.TimelapseHistory(frames = [gamemap])
        persistence.savemap(persistence.GameMapBundle(gamemap, history), valid_path; game_version = v"0.1.0")
        @test TimelapseExportTool._run_with_persistence(parse_cli([valid_path, "--inspect"])) == 0
        @test TimelapseExportTool._run_with_persistence(parse_cli([valid_path, "--inspect", "--camera", "smooth"])) == 0
        @test !isdefined(TimelapseExportTool.Runtime, :GLFW)
    end
end

println("Time-lapse exporter tests passed")
