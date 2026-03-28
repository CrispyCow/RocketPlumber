# ===============================================================
# UI Common Helpers
# ===============================================================

# Lightweight usings to help editor intellisense; main launch scripts provide full usings
import CImGui
using CImGui: ImVec2, ImVec4, IM_COL32, ImU32
using Printf
using HexFrame, FlowEngine, FlowMap, HexComponentsAPI
using HexFlowCalculator

#= ---------- UI Layout Constants ---------- =#

const toolbarheight = 200.0
const propertyboxwidth = 350.0

#= ---------- Window Configuration ---------- =#

const DEFAULT_WINDOW_FLAGS = CImGui.ImGuiWindowFlags_NoTitleBar |
    CImGui.ImGuiWindowFlags_NoResize |
    CImGui.ImGuiWindowFlags_NoMove


#= ---------- Helper Functions ---------- =#
"Convert a NamedTuple of numeric values to Float64."
function to_float(nt::NamedTuple)
    return NamedTuple{keys(nt)}(Float64.(values(nt)))
end

"Set up and begin a CImGui window with the given position, size, and flags."
function ui_window_setup(title::String, pos, size, flags)
    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize(size, CImGui.ImGuiCond_Always)
    return CImGui.Begin(title, C_NULL, flags)
end

"Begin a CImGui window with default flags."
function ui_window(title::String, pos, size; flags = DEFAULT_WINDOW_FLAGS)
    return ui_window_setup(title, pos, size, flags)
end

"""
Create a button that supports a disabled state and an optional tooltip when disabled.
Returns `true` when the (enabled) button is clicked. When `disabled==true` the
button is rendered disabled and `tooltip` is shown while hovering.
"""
function button_with_disable(label::AbstractString, size::ImVec2, disabled::Bool; tooltip::Union{Nothing, String} = nothing)::Bool
    if disabled
        CImGui.BeginDisabled()
    end
    clicked = CImGui.Button(label, size)
    if disabled
        CImGui.EndDisabled()
        if tooltip !== nothing && CImGui.IsItemHovered(CImGui.ImGuiHoveredFlags_AllowWhenDisabled)
            CImGui.SetTooltip(tooltip)
        end
    end
    return clicked
end

# Overload that accepts a (blocked::Bool, reason::String) tuple and delegates
function button_with_disable(label::AbstractString, size::ImVec2, blocked::Tuple{Bool, String})::Bool
    is_blocked, reason = blocked
    return button_with_disable(label, size, is_blocked; tooltip = is_blocked ? reason : nothing)
end

"""
Return (blocked::Bool, reason::String) for whether time-warping should be blocked.
- Blocks if the ship is producing thrust above the manoeuvre threshold.
- Blocks if an active manoeuvre is currently in a burn phase (approach or capture).
"""
function is_timewarp_blocked(gamemap::GameMap, gamestate::GameState)::Tuple{Bool, String}
    # Thrust-based blocker
    if norm(gamestate.thrust) > MANOEUVRE_THRUST_THRESHOLD
        return (true, "Cannot time-warp while engines are firing.")
    end

    # Active manoeuvre burn-phase blocker
    if has_active_manoeuvre(gamemap)
        man = get_active_manoeuvre(gamemap)
        if man.phase == PHASE_APPROACH_BURN || man.phase == PHASE_CAPTURE_BURN
            return (true, "Cannot time-warp during a manoeuvre burn; complete the burn or cancel the manoeuvre first.")
        end
    end

    return (false, "")
end

#= ---------- Dict-based GUI input helpers ---------- =#

"Read/write a `UInt32` scalar from `inputs[key]` via an ImGui input widget."
function gui_input_u32!(inputs::Dict{Symbol, Any}, key::Symbol, label::String, default::UInt32)
    one::UInt32 = UInt32(1)
    val::UInt32 = haskey(inputs, key) ? inputs[key] : default
    @cref CImGui.InputScalar(label, CImGui.ImGuiDataType_U32, &val, &one)
    inputs[key] = val
    return val
end

"Read/write an `Int64` scalar from `inputs[key]` via an ImGui input widget."
function gui_input_s64!(inputs::Dict{Symbol, Any}, key::Symbol, label::String, default::Int64)
    one::Int64 = Int64(1)
    val::Int64 = haskey(inputs, key) ? inputs[key] : default
    @cref CImGui.InputScalar(label, CImGui.ImGuiDataType_S64, &val, &one)
    inputs[key] = val
    return val
end

"Read/write a `Float64` value from `inputs[key]` via an ImGui input widget."
function gui_input_double!(inputs::Dict{Symbol, Any}, key::Symbol, label::String, default::Float64; step_small::Float64 = 0.01, step_fast::Float64 = 0.1, fmt::String = "%.3f")
    val::Float64 = haskey(inputs, key) ? inputs[key] : default
    @cref CImGui.InputDouble(label, &val, step_small, step_fast, fmt)
    inputs[key] = val
    return val
end

"Read/write an `Int32` listbox selection from `inputs[key]` via an ImGui listbox."
function gui_listbox_int!(inputs::Dict{Symbol, Any}, key::Symbol, label::String, names::Vector{String}, default::Int32)
    val::Int32 = haskey(inputs, key) ? inputs[key] : default
    @cref CImGui.ListBox(label, &val, names)
    inputs[key] = val
    return val
end

#= ---------- InputState convenience wrappers (delegate to dict core) ---------- =#

"Delegate to the `Dict` overload using `inputstate.gui_inputs`."
gui_input_u32!(inputstate::InputState, key::Symbol, label::String, default::UInt32) =
    gui_input_u32!(inputstate.gui_inputs, key, label, default)

"Delegate to the `Dict` overload using `inputstate.gui_inputs`."
gui_input_s64!(inputstate::InputState, key::Symbol, label::String, default::Int64) =
    gui_input_s64!(inputstate.gui_inputs, key, label, default)

"Delegate to the `Dict` overload using `inputstate.gui_inputs`."
gui_input_double!(inputstate::InputState, key::Symbol, label::String, default::Float64; step_small::Float64 = 0.01, step_fast::Float64 = 0.1, fmt::String = "%.3f") =
    gui_input_double!(inputstate.gui_inputs, key, label, default; step_small, step_fast, fmt)

"Delegate to the `Dict` overload using `inputstate.gui_inputs`."
gui_listbox_int!(inputstate::InputState, key::Symbol, label::String, names::Vector{String}, default::Int32) =
    gui_listbox_int!(inputstate.gui_inputs, key, label, names, default)

"Format a number with 6 significant figures, using scientific notation for extreme values."
function format_value(val::Float64)::String
    if !isfinite(val)
        return string(val)
    end

    abs_val = abs(val)

    if abs_val == 0.0
        return "0.00000"
    elseif abs_val >= 1.0e6 || abs_val < 1.0e-3
        # Use scientific notation for very large or very small numbers
        return @sprintf("%.5e", val)
    else
        # Determine decimal places needed for 6 sig figs
        # For values >= 1, we need 6 - floor(log10(abs_val)) - 1 decimal places
        # For values < 1, we need 5 + ceil(abs(log10(abs_val))) decimal places
        if abs_val >= 1.0
            sig_decimals = max(0, 6 - floor(Int, log10(abs_val)) - 1)
            return @sprintf("%.*f", sig_decimals, val)
        else
            sig_decimals = 5 + ceil(Int, abs(log10(abs_val)))
            return @sprintf("%.*f", sig_decimals, val)
        end
    end
end

"""
Return a display-safe string for a ship name symbol.
Strips leading `##` (ImGui ID separator) and replaces remaining `#` with `-`.
"""
function safe_ship_display_name(name::Symbol)::String
    s = String(name)
    if startswith(s, "##")
        s2 = lstrip(s, '#')              # "##ship#278" → "ship#278"
        s2 = replace(s2, '#' => '-')     # "ship#278" → "ship-278"
        return s2
    else
        return s
    end
end
