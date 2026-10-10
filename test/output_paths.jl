using Test, BaseDirs, RocketPlumber, HexFlowPersistence, HexFlowTelemetry, FlowMap

documents, workdir = ARGS

# Windows and macOS do not use XDG configuration. Keep their filesystem tests isolated too.
if !Sys.islinux()
    BaseDirs.DOCUMENTS_DIR = documents
end

@testset "User output directories" begin
    root = joinpath(documents, "RocketPlumber-saves")
    @test !ispath(root)  # Importing the full application must remain passive
    @test RocketPlumber.output_dir() == root
    directories = (
        RocketPlumber.maps_dir => "maps",
        RocketPlumber.pictures_dir => "pictures",
        RocketPlumber.videos_dir => "videos",
        RocketPlumber.telemetry_dir => joinpath("logs", "telemetry"),
        RocketPlumber.crashes_dir => joinpath("logs", "crashes"),
    )
    for (resolve, relative) in directories
        @test resolve() == joinpath(root, relative)
        @test isabspath(resolve())
        cd(workdir) do
            @test resolve() == joinpath(root, relative)
        end
    end
    @test !ispath(root)

    timestamp = "20261010_123456"
    @test RocketPlumber.default_capture_path(:screenshot, timestamp) == joinpath(root, "pictures", "screenshot_$timestamp.png")
    @test RocketPlumber.default_capture_path(:recording, timestamp) == joinpath(root, "videos", "recording_$timestamp.mp4")
    @test_throws ArgumentError RocketPlumber.default_capture_path(:invalid, timestamp)
    @test !ispath(root)

    @testset "Filename normalisation" begin
        for (suffix, expected_suffix) in (("", ".jld2"), (".jld", ".jld2"), (".JLD", ".jld2"), (".jld2", ".jld2"), (".other", ".other"))
            selected_path = joinpath(workdir, "outside" * suffix)
            destination = joinpath(workdir, "outside" * expected_suffix)
            @test RocketPlumber.normalise_map_save_path(selected_path) == destination
        end
    end

    @testset "Map dialogs and persistence" begin
        messages = String[]
        console_push = message -> push!(messages, message)
        selected_path = nothing
        function dialog(directory; filterlist)
            @test string(directory) == joinpath(root, "maps")
            @test isdir(directory)
            @test filterlist == "jld2"
            return selected_path
        end

        @test isnothing(RocketPlumber.map_save_dialog(console_push; dialog))
        @test isnothing(RocketPlumber.map_load_dialog(; dialog))
        @test isempty(messages)

        failed_dialog = (directory; filterlist) -> error("native dialog unavailable")
        @test_throws ErrorException RocketPlumber.map_load_dialog(; dialog = failed_dialog)
        interrupted_dialog = (directory; filterlist) -> throw(InterruptException())
        @test_throws InterruptException RocketPlumber.map_load_dialog(; dialog = interrupted_dialog)

        # One normalised dialog path exercises the persistence integration
        selected_path = joinpath(workdir, "new_outside.jld")
        path = RocketPlumber.map_save_dialog(console_push; dialog)
        @test path == joinpath(workdir, "new_outside.jld2")
        gamemap = GameMap()
        increment_simulated_ticks!(gamemap)
        RocketPlumber.save_game(gamemap, path)
        @test get_simulated_ticks(loadmap(path)) == 1
        @test !ispath(selected_path)
        @test isempty(messages)

        rm(RocketPlumber.maps_dir())
        selected_path = path
        @test RocketPlumber.map_load_dialog(; dialog) == path

        # Normalisation must not overwrite an unconfirmed destination
        destination = joinpath(workdir, "outside.jld2")
        write(destination, "keep this file")
        selected_path = joinpath(workdir, "outside.jld")
        @test_throws ArgumentError RocketPlumber.normalise_map_save_path(selected_path)
        @test_logs (:warn, "Map save dialog failed") begin
            @test isnothing(RocketPlumber.map_save_dialog(console_push; dialog))
        end
        @test occursin("Select the full .jld2 filename", only(messages))
        @test read(destination, String) == "keep this file"

        # Explicit filenames retain the native dialog's overwrite confirmation
        empty!(messages)
        selected_path = destination
        @test RocketPlumber.map_save_dialog(console_push; dialog) == destination
        @test read(destination, String) == "keep this file"
        @test isempty(messages)

        if !Sys.iswindows()
            destination = joinpath(workdir, "linked.jld2")
            link_target = joinpath(workdir, "missing_target")
            symlink(link_target, destination)
            @test_throws ArgumentError RocketPlumber.normalise_map_save_path(joinpath(workdir, "linked"))
            @test islink(destination)
            @test readlink(destination) == link_target
            @test !ispath(link_target)
        end
    end

    @testset "Output-directory failures" begin
        maps = RocketPlumber.maps_dir()
        rm(maps)
        write(maps, "blocked maps directory")
        state = RocketPlumber.StartMenuState(page = RocketPlumber.PAGE_NEW_GAME, action = RocketPlumber.ACTION_LOAD_MAP)
        window = RocketPlumber.GLFW.Window(C_NULL)
        @test_logs (:warn, "Map load dialog failed") begin
            @test isnothing(RocketPlumber.handle_start_menu_action!(state, window))
        end
        @test state.page == RocketPlumber.PAGE_INITIAL
        @test state.load_error == "Could not open the save-file dialog."
        @test read(maps, String) == "blocked maps directory"
        rm(maps)

        messages = String[]
        console_push = message -> push!(messages, message)
        rec = RocketPlumber.RecordingState()
        pictures = RocketPlumber.pictures_dir()
        write(pictures, "blocked pictures directory")
        @test_logs (:warn, "Screenshot capture failed") begin
            @test isnothing(RocketPlumber.save_screenshot!(rec, Int32(2), Int32(2), console_push))
        end
        @test only(messages) == "Screenshot failed; see the terminal log for details"
        @test isempty(rec.screenshot_buffer)
        @test read(pictures, String) == "blocked pictures directory"
        rm(pictures)

        empty!(messages)
        videos = RocketPlumber.videos_dir()
        write(videos, "blocked videos directory")
        @test_logs (:warn, "Recording start failed") begin
            @test !RocketPlumber.start_recording!(rec, Int32(2), Int32(2), console_push)
        end
        @test only(messages) == "Recording failed; see the terminal log for details"
        @test !rec.is_recording
        @test isempty(rec.output_path)
        @test isempty(rec.recording_buffers)
        @test isempty(rec.pbo_ids)
        @test isnothing(rec.ffmpeg_process)
        @test isnothing(rec.writer_task)
        @test read(videos, String) == "blocked videos directory"
        rm(videos)
    end

    @testset "Application diagnostics" begin
        @test !ispath(RocketPlumber.crashes_dir())
        path = RocketPlumber.write_game_crash_dump((stored_gamemap = GameMap(),))
        @test dirname(path) == joinpath(root, "logs", "crashes")
        @test isfile(path)
        @test HexFlowPersistence.load_game_version(path) == string(Base.pkgversion(RocketPlumber))

        @test !ispath(RocketPlumber.telemetry_dir())
        start_telemetry!(false)
        @test isnothing(finish_telemetry!(; directory = RocketPlumber.telemetry_dir(), io = IOBuffer()))
        @test !ispath(RocketPlumber.telemetry_dir())
        start_telemetry!(true)
        path = finish_telemetry!(; directory = RocketPlumber.telemetry_dir(), io = IOBuffer())
        @test dirname(path) == joinpath(root, "logs", "telemetry")
        @test occursin("Rocket Plumber cumulative telemetry", read(path, String))
    end

    for (resolve, relative) in directories
        @test resolve(; create = true) == joinpath(root, relative)
        @test isdir(resolve())
    end

    if Sys.islinux()
        # Re-resolve after changing XDG configuration: application helpers must not cache paths
        changed_documents = joinpath(workdir, "Changed Documents")
        write(joinpath(ENV["XDG_CONFIG_HOME"], "user-dirs.dirs"), "XDG_DOCUMENTS_DIR=\"$changed_documents\"\n")
        BaseDirs.reload()
        @test RocketPlumber.output_dir() == joinpath(changed_documents, "RocketPlumber-saves")
        @test !ispath(RocketPlumber.output_dir())
    end
end
