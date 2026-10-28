#=
Scope: Application settings defaults, staging, scale steps, and session lifetime
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
