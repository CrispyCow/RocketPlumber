#=
Scope: Application settings persistence, staged updates, and window-mode ownership
Formatter: Runic
=#

"Persistent application settings shared across menus and game sessions."
@kwdef struct AppSettings
    ui_scale::UIScale = UIScale133
    fullscreen::Bool = false
    vsync::Bool = true
    background_dust::Bool = true
    last_monitor::Union{Nothing, String} = nothing # Last observed display, used only as a startup hint
end

"Settings and transient state shared across all menus and game sessions."
@kwdef mutable struct AppState
    settings::AppSettings = AppSettings()
    pending_settings::Union{Nothing, AppSettings} = nothing
    window_mode::WindowModeState = WindowModeState()
    shortcut_keystates::Dict{GLFW.Key, Bool} = Dict{GLFW.Key, Bool}()
end

const _APP_STATE = Ref{AppState}(AppState())

app_state() = _APP_STATE[]
current_ui_scale() = app_state().settings.ui_scale

"Return the latest requested preferences, including changes staged during this frame."
requested_settings() = something(app_state().pending_settings, app_state().settings)

"Start a fresh application lifetime before creating the window and UI context."
function initialise_app_state!()
    _APP_STATE[] = AppState()
    return nothing
end

"Resolve the preferences file without creating its parent directory."
settings_path() = joinpath(output_dir(), "settings.toml")

"Read a boolean preference, warning and retaining its default for invalid values."
function settings_bool(values::Dict{String, Any}, key::String, default::Bool)
    value = get(values, key, default)
    value isa Bool && return value
    @warn "Invalid application setting; using default" key value default
    return default
end

"Read an enum preference by name, warning and retaining its default for invalid values."
function settings_enum(values::Dict{String, Any}, key::String, ::Type{T}, default::T) where {T <: Enum}
    value = get(values, key, string(default))
    for option in instances(T)
        string(option) == value && return option
    end
    @warn "Invalid application setting; using default" key value default
    return default
end

"Load committed preferences; return false if an unreadable or malformed file must be preserved."
function load_app_settings!(path::String = settings_path())
    state = app_state()
    defaults = AppSettings()
    state.settings = defaults
    state.pending_settings = nothing

    # Load values from file
    values = try
        ispath(path) || return true
        TOML.parsefile(path)
    catch err
        err isa InterruptException && rethrow()
        @warn "Could not load application settings; using defaults and skipping save" path exception = (err, catch_backtrace())
        return false
    end

    # Get monitor string from values
    last_monitor = get(values, "last_monitor", defaults.last_monitor)
    if !isnothing(last_monitor) && !(last_monitor isa String)
        @warn "Invalid application setting; using default" key = "last_monitor" value = last_monitor default = defaults.last_monitor
        last_monitor = defaults.last_monitor
    end

    state.settings = AppSettings(
        ui_scale = settings_enum(values, "ui_scale", UIScale, defaults.ui_scale),
        fullscreen = settings_bool(values, "fullscreen", defaults.fullscreen),
        vsync = settings_bool(values, "vsync", defaults.vsync),
        background_dust = settings_bool(values, "background_dust", defaults.background_dust),
        last_monitor = last_monitor,
    )
    return true
end

"Save only committed preferences, creating the output directory when needed."
function save_app_settings(path::String = settings_path())
    settings = app_state().settings
    values = Dict(
        "ui_scale" => string(settings.ui_scale),
        "fullscreen" => settings.fullscreen,
        "vsync" => settings.vsync,
        "background_dust" => settings.background_dust,
    )
    if !isnothing(settings.last_monitor)
        values["last_monitor"] = settings.last_monitor
    end
    try
        mkpath(dirname(path))
        open(path, "w") do io
            TOML.print(io, values; sorted = true)
        end
    catch err
        err isa InterruptException && rethrow()
        @warn "Could not save application settings" path exception = (err, catch_backtrace())
    end
    return nothing
end

"Stage a UI scale change, preserving any other changes already requested this frame."
function set_ui_scale!(scale::UIScale)
    settings = requested_settings()
    scale == settings.ui_scale && return nothing
    app_state().pending_settings = @set settings.ui_scale = scale
    return nothing
end

"Step through the existing scale levels from the latest request, clamping at either end."
function step_ui_scale!(direction::Int)
    scales = instances(UIScale)
    index = clamp(Int(requested_settings().ui_scale) + direction, 1, length(scales))
    set_ui_scale!(scales[index])
    return nothing
end

"Stage native fullscreen through the same path used by the settings menu and F11."
function set_fullscreen!(enabled::Bool)
    settings = requested_settings()
    enabled == settings.fullscreen && return nothing
    app_state().pending_settings = @set settings.fullscreen = enabled
    return nothing
end

"Stage vertical synchronisation for the current application window."
function set_vsync!(enabled::Bool)
    settings = requested_settings()
    enabled == settings.vsync && return nothing
    app_state().pending_settings = @set settings.vsync = enabled
    return nothing
end

"Stage background dust visibility without affecting component particles."
function set_background_dust!(enabled::Bool)
    settings = requested_settings()
    enabled == settings.background_dust && return nothing
    app_state().pending_settings = @set settings.background_dust = enabled
    return nothing
end

"Poll global shortcut edges and refresh tracked states, even while typing."
function poll_application_shortcuts!(window::GLFW.Window)
    states = app_state().shortcut_keystates
    fullscreen = get_inrising!(states, GLFW.KEY_F11, window)
    increase = get_inrising!(states, GLFW.KEY_KP_ADD, window)
    decrease = get_inrising!(states, GLFW.KEY_KP_SUBTRACT, window)
    update_lastinstate!(states, window)

    fullscreen && set_fullscreen!(!requested_settings().fullscreen)
    unsafe_load(CImGui.GetIO().WantTextInput) && return nothing

    if increase
        step_ui_scale!(1)
    elseif decrease
        step_ui_scale!(-1)
    end
    return nothing
end

"Commit after presentation; omit the window only before window creation or in headless tests."
function apply_pending_settings!(window::Union{Nothing, GLFW.Window} = nothing)
    state = app_state()
    pending = state.pending_settings
    isnothing(pending) && return nothing

    if !isnothing(window)
        transition = pending.fullscreen != window_is_fullscreen(window)
        if transition
            actual = apply_fullscreen!(state.window_mode, window, pending.fullscreen)
            pending = @set pending.fullscreen = actual
        end
        if transition || pending.vsync != state.settings.vsync
            apply_vsync!(pending.vsync)
        end
    end
    if pending.ui_scale != state.settings.ui_scale
        apply_ui_scale!(pending.ui_scale)
    end
    state.settings = pending
    state.pending_settings = nothing
    return nothing
end
