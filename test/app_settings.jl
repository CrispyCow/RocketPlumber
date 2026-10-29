#=
Scope: Application settings persistence, staging, scale steps, and session lifetime
Formatter: Runic
=#

"Replace the whole application state for a sequential test, including on failure."
function with_test_app_state(test::Function)
    previous = RocketPlumber.app_state()
    RocketPlumber.initialise_app_state!()
    try
        return test()
    finally
        RocketPlumber._APP_STATE[] = previous
    end
end

@testset "Settings persistence" begin
    with_test_app_state() do
        mktempdir() do directory
            state = RocketPlumber.app_state()
            defaults = RocketPlumber.AppSettings()
            path = joinpath(directory, "output", "settings.toml")

            @testset "Missing file" begin
                state.settings = RocketPlumber.AppSettings(fullscreen = true)
                @test RocketPlumber.load_app_settings!(path)
                @test state.settings == defaults
                @test isnothing(state.pending_settings)
                @test isempty(readdir(directory))
            end

            @testset "Committed settings round trip" begin
                expected = RocketPlumber.AppSettings(ui_scale = RocketPlumber.UIScale233, fullscreen = true, vsync = false, background_dust = false, last_monitor = "DELL U2724D")
                state.settings = expected
                RocketPlumber.set_fullscreen!(false)
                RocketPlumber.save_app_settings(path)
                @test RocketPlumber.TOML.parsefile(path) == Dict(
                    "ui_scale" => "UIScale233", "fullscreen" => true,
                    "vsync" => false, "background_dust" => false,
                    "last_monitor" => "DELL U2724D",
                )
                @test RocketPlumber.load_app_settings!(path)
                @test state.settings == expected
                @test isnothing(state.pending_settings)
            end

            @testset "Unset monitor is omitted" begin
                state.settings = defaults
                RocketPlumber.save_app_settings(path)
                @test !haskey(RocketPlumber.TOML.parsefile(path), "last_monitor")
            end

            @testset "Partial and unknown fields" begin
                write(path, "fullscreen = true\nfuture_preference = 42\n")
                @test RocketPlumber.load_app_settings!(path)
                @test state.settings == RocketPlumber.AppSettings(fullscreen = true)
            end

            @testset "Invalid fields retain defaults" begin
                write(path, "ui_scale = \"UIScale999\"\nfullscreen = true\nvsync = \"false\"\nbackground_dust = false\nlast_monitor = 42\n")
                @test RocketPlumber.load_app_settings!(path)
                @test state.settings == RocketPlumber.AppSettings(fullscreen = true, background_dust = false)
            end

            @testset "Malformed file is preserved" begin
                contents = "fullscreen = ["
                write(path, contents)
                @test !RocketPlumber.load_app_settings!(path)
                @test state.settings == defaults
                @test read(path, String) == contents
            end

            @testset "Unreadable settings" begin
                # A directory cannot be parsed as a settings file on any platform.
                unreadable = mkpath(joinpath(directory, "unreadable.toml"))
                state.settings = RocketPlumber.AppSettings(fullscreen = true)
                @test !RocketPlumber.load_app_settings!(unreadable)
                @test state.settings == defaults
                @test isdir(unreadable)
            end

            @testset "Save failures" begin
                blocked = joinpath(directory, "blocked")
                write(blocked, "keep this file")
                @test isnothing(RocketPlumber.save_app_settings(joinpath(blocked, "settings.toml")))
                @test read(blocked, String) == "keep this file"
            end
        end
    end
end

@testset "Monitor hints and observation on the headless backend" begin
    with_test_app_state() do
        glfw = RocketPlumber.GLFW
        state = RocketPlumber.app_state()
        monitor = glfw.GetPrimaryMonitor()
        glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
        window = glfw.CreateWindow(640, 480, "Monitor hints and observation")
        try
            restored = RocketPlumber.restore_last_monitor!(window, glfw.GetMonitorName(monitor))
            @test restored.handle == monitor.handle
            @test !RocketPlumber.window_is_fullscreen(window)
            @test isnothing(RocketPlumber.restore_last_monitor!(window, "Unavailable display"))
            @test RocketPlumber.window_monitor(window).handle == monitor.handle

            @test RocketPlumber.apply_fullscreen!(state.window_mode, window, true, restored)
            RocketPlumber.remember_last_monitor!(window)
            @test state.settings == RocketPlumber.AppSettings(last_monitor = glfw.GetMonitorName(monitor))
            @test isnothing(state.pending_settings)

            # The null backend cannot locate windowed displays; retain the observed name.
            glfw.SetWindowMonitor(window, glfw.Monitor(C_NULL), 0, 0, 640, 480, glfw.DONT_CARE)
            settings = state.settings
            RocketPlumber.remember_last_monitor!(window)
            @test state.settings == settings
        finally
            glfw.DestroyWindow(window)
            glfw.DefaultWindowHints()
        end
    end
end

@testset "Fullscreen restores the current windowed geometry" begin
    glfw = RocketPlumber.GLFW
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    window = glfw.CreateWindow(640, 480, "Fullscreen restoration")
    try
        mode = RocketPlumber.WindowModeState()
        for (x, y, width, height) in ((100, 150, 640, 480), (900, 250, 800, 600))
            glfw.SetWindowPos(window, x, y)
            glfw.SetWindowSize(window, width, height)
            @test RocketPlumber.apply_fullscreen!(mode, window, true)

            # Reapplying fullscreen must not overwrite the captured windowed geometry.
            @test RocketPlumber.apply_fullscreen!(mode, window, true)
            @test !RocketPlumber.apply_fullscreen!(mode, window, false)
            position = glfw.GetWindowPos(window)
            size = glfw.GetWindowSize(window)
            @test (position.x, position.y, size.width, size.height) == (x, y, width, height)
        end
    finally
        glfw.DestroyWindow(window)
        glfw.DefaultWindowHints()
    end
end

@testset "Settings defaults and staged changes" begin
    with_test_app_state() do
        state = RocketPlumber.app_state()
        defaults = state.settings
        @test defaults == RocketPlumber.AppSettings(ui_scale = RocketPlumber.UIScale133, fullscreen = false, vsync = true, background_dust = true)
        @test isnothing(state.pending_settings)
        @test isnothing(RocketPlumber.apply_pending_settings!())

        RocketPlumber.set_ui_scale!(RocketPlumber.UIScale200)
        RocketPlumber.set_fullscreen!(true)
        RocketPlumber.set_vsync!(false)
        RocketPlumber.set_background_dust!(false)
        @test state.settings == defaults
        @test RocketPlumber.requested_settings() == RocketPlumber.AppSettings(ui_scale = RocketPlumber.UIScale200, fullscreen = true, vsync = false, background_dust = false)

        # Revert the scale before committing: font changes require a live UI context.
        RocketPlumber.set_ui_scale!(defaults.ui_scale)
        expected = RocketPlumber.AppSettings(fullscreen = true, vsync = false, background_dust = false)
        @test RocketPlumber.requested_settings() == expected
        RocketPlumber.apply_pending_settings!()
        @test state.settings == expected
        @test isnothing(state.pending_settings)
        @test RocketPlumber.requested_settings() == expected
        RocketPlumber.set_fullscreen!(true)
        @test isnothing(state.pending_settings)

        RocketPlumber.initialise_app_state!()
        @test RocketPlumber.app_state().settings == defaults
    end
end

@testset "UI scale steps accumulate and clamp" begin
    with_test_app_state() do
        scales = instances(RocketPlumber.UIScale)
        RocketPlumber.set_fullscreen!(true)
        RocketPlumber.step_ui_scale!(-100)
        @test RocketPlumber.requested_settings().ui_scale == first(scales)
        RocketPlumber.step_ui_scale!(-1)
        @test RocketPlumber.requested_settings().ui_scale == first(scales)
        for scale in scales[2:end]
            RocketPlumber.step_ui_scale!(1)
            @test RocketPlumber.requested_settings().ui_scale == scale
        end
        RocketPlumber.step_ui_scale!(1)
        @test RocketPlumber.requested_settings().ui_scale == last(scales)
        RocketPlumber.step_ui_scale!(-1)
        @test RocketPlumber.requested_settings().ui_scale == scales[end - 1]
        @test RocketPlumber.requested_settings().fullscreen
        @test RocketPlumber.current_ui_scale() == RocketPlumber.UIScale133
    end
end

@testset "Settings survive session transitions" begin
    with_test_app_state() do
        state = RocketPlumber.app_state()
        state.settings = RocketPlumber.AppSettings(ui_scale = RocketPlumber.UIScale200)
        RocketPlumber.set_fullscreen!(true)
        RocketPlumber.set_vsync!(false)
        RocketPlumber.set_background_dust!(false)
        RocketPlumber.apply_pending_settings!()
        settings = state.settings
        bundle = RocketPlumber.GameMapBundle(GameMap())
        session = RocketPlumber.MapSession(bundle)

        restarted = RocketPlumber.next_session(session, RocketPlumber.GameLoopResult(exit_reason = EXIT_RESTART, saved_bundle = bundle))
        tutorial = RocketPlumber.next_session(restarted, RocketPlumber.GameLoopResult(exit_reason = EXIT_SANDBOX_STARTED, tutorial_id = :teaser, saved_bundle = bundle))
        resumed = RocketPlumber.next_session(tutorial, RocketPlumber.GameLoopResult(exit_reason = EXIT_MENU, saved_bundle = bundle))
        @test resumed isa RocketPlumber.MapSession
        @test isnothing(RocketPlumber.next_session(resumed, RocketPlumber.GameLoopResult(exit_reason = EXIT_MENU, saved_bundle = bundle)))
        RocketPlumber.StartMenuState()
        InputState()
        @test RocketPlumber.app_state().settings == settings
        @test isnothing(RocketPlumber.app_state().pending_settings)
    end
end
