module HexFluids

using Base.Threads: Atomic, atomic_xchg!

# Type Exports
export FluidType, FluidConstraint
export FluidSource, FluidTypeRule, FluidConstraintRule, FluidDeclaration

# Function Exports
export check_constraint, is_gas, is_liquid
export fluid_type_label, fluid_constraint_label
export get_default_temperature
export THERMAL_AMBIENT_TEMPERATURE_K
export lookup_fluid_exhaust_velocity, lookup_fluid_density
export set_fluid_exhaust_velocity!, set_fluid_density!
export get_fluid_exhaust_velocities, get_fluid_densities
export lookup_fluid_reference_temperature, set_fluid_reference_temperature!
export get_fluid_reference_temperatures

# ===============================================================
# Fluid Types and Constraints
# ===============================================================

#= ---------- Encoding ----------- =#
# UInt32 layout: upper 16 bits = constraint flags (one-hot), lower 16 bits = unique ID.
# FluidType values carry their constraint membership in the upper bits.
# FluidConstraint values are pure flag masks with zero lower bits.

const IS_GAS_BIT    = 0x00010000
const IS_LIQUID_BIT = 0x00020000

@enum FluidType::UInt32 begin
    COLD_GAS        = IS_GAS_BIT    | 0x0001   # 0x00010001
    MONOPROP_LIQUID = IS_LIQUID_BIT | 0x0002   # 0x00020002
    MONOPROP_GAS    = IS_GAS_BIT    | 0x0003   # 0x00010003
    FUEL_LIQUID     = IS_LIQUID_BIT | 0x0004   # 0x00020004
    OXIDISER_LIQUID = IS_LIQUID_BIT | 0x0005   # 0x00020005
    BIPROP_EXHAUST  = IS_GAS_BIT    | 0x0006   # 0x00010006
end

@enum FluidConstraint::UInt32 begin
    IS_GAS    = IS_GAS_BIT       # 0x00010000
    IS_LIQUID = IS_LIQUID_BIT    # 0x00020000
end

# ===============================================================
# Classification and Constraint Checking
# ===============================================================

"Check if a fluid type satisfies a constraint (bitmask test)"
check_constraint(fluid::FluidType, constraint::FluidConstraint) = UInt32(fluid) & UInt32(constraint) != 0

"Check if a fluid type matches another (must be identical)"
check_constraint(fluid::FluidType, other::FluidType) = fluid === other

"Check if fluid type is a gas (bitmask test)"
is_gas(fluid::FluidType)::Bool = UInt32(fluid) & IS_GAS_BIT != 0
is_gas(::Nothing)::Bool = false

"Check if fluid type is a liquid (bitmask test)"
is_liquid(fluid::FluidType)::Bool = UInt32(fluid) & IS_LIQUID_BIT != 0
is_liquid(::Nothing)::Bool = false

# ===============================================================
# Fluid Declaration Types (isbits)
# ===============================================================

"A fluid source: injects a concrete fluid at a specific temperature"
struct FluidSource
    fluid_type::FluidType
    temperature::Float64
end

"A type rule: this node must carry exactly this fluid type (no temperature contribution)"
struct FluidTypeRule
    fluid_type::FluidType
end

"A constraint rule: this node must carry a fluid satisfying this constraint"
struct FluidConstraintRule
    constraint::FluidConstraint
end

"Union of all fluid declaration variants. isbitsunion-safe (3 isbits types, max 2 fields)."
const FluidDeclaration = Union{FluidSource, FluidTypeRule, FluidConstraintRule}

# ===============================================================
# Default Temperatures
# ===============================================================

const THERMAL_AMBIENT_TEMPERATURE_K = 300.0

"Default temperature for a fluid type. Returns `nothing` if no default (e.g. MONOPROP_GAS is derived from decomp chamber)."
get_default_temperature(::Val{COLD_GAS})        = THERMAL_AMBIENT_TEMPERATURE_K
get_default_temperature(::Val{MONOPROP_LIQUID})  = THERMAL_AMBIENT_TEMPERATURE_K
get_default_temperature(::Val{FUEL_LIQUID})      = THERMAL_AMBIENT_TEMPERATURE_K
get_default_temperature(::Val{OXIDISER_LIQUID})  = THERMAL_AMBIENT_TEMPERATURE_K
get_default_temperature(::Val{T}) where {T}     = nothing

"Default temperature for a runtime fluid type with fallback. Returns the fluid's default temperature if available, otherwise the provided fallback."
function get_default_temperature(fluid::FluidType, fallback::Real)::Float64
    temp = get_default_temperature(Val(fluid))
    return isnothing(temp) ? Float64(fallback) : temp
end

# ===============================================================
# Fluid Physical Properties
# ===============================================================

"Exhaust velocities for concrete gas fluids, with per-value atomic storage for thread-safe runtime tuning."
const _fluid_exhaust_velocities = Dict{FluidType, Atomic{Float64}}(
    COLD_GAS     => Atomic{Float64}(500.0),
    MONOPROP_GAS => Atomic{Float64}(1500.0),
    BIPROP_EXHAUST => Atomic{Float64}(3200.0),
)

"Fluid densities for concrete fluids, with per-value atomic storage for thread-safe runtime tuning."
const _fluid_densities = Dict{FluidType, Atomic{Float64}}(
    COLD_GAS        => Atomic{Float64}(1.0),
    MONOPROP_LIQUID => Atomic{Float64}(5.0),
    MONOPROP_GAS    => Atomic{Float64}(1.0),
    FUEL_LIQUID     => Atomic{Float64}(5.0),
    OXIDISER_LIQUID => Atomic{Float64}(5.0),
    BIPROP_EXHAUST  => Atomic{Float64}(1.0),
)

"Reference temperatures for exhaust velocity scaling v_e(T) = v_e_ref x √(T / T_ref)."
const _fluid_reference_temperatures = Dict{FluidType, Atomic{Float64}}(
    COLD_GAS     => Atomic{Float64}(300.0),
    MONOPROP_GAS => Atomic{Float64}(800.0),
    BIPROP_EXHAUST => Atomic{Float64}(2300.0),
)

#= ---------- Lookups ----------- =#

"Look up the exhaust velocity for a fluid type. Returns `nothing` if not defined."
function lookup_fluid_exhaust_velocity(fluid::FluidType)::Union{Float64, Nothing}
    ref = get(_fluid_exhaust_velocities, fluid, nothing)
    return isnothing(ref) ? nothing : ref[]
end

"Look up the temperature-scaled exhaust velocity for a fluid type, clamped to its reference-temperature maximum."
function lookup_fluid_exhaust_velocity(fluid::FluidType, temperature_k::Real)::Union{Float64, Nothing}
    reference_exhaust_velocity = lookup_fluid_exhaust_velocity(fluid)
    reference_temperature_k = lookup_fluid_reference_temperature(fluid)
    if isnothing(reference_exhaust_velocity) || isnothing(reference_temperature_k)
        return nothing
    end

    temperature_ratio = max(Float64(temperature_k), 0.0) / reference_temperature_k
    temperature_scale = sqrt(temperature_ratio)
    return min(reference_exhaust_velocity * temperature_scale, reference_exhaust_velocity)
end

"Look up the density for a fluid type. Returns `nothing` if not defined."
function lookup_fluid_density(fluid::FluidType)::Union{Float64, Nothing}
    ref = get(_fluid_densities, fluid, nothing)
    return isnothing(ref) ? nothing : ref[]
end

"Look up the reference temperature for exhaust velocity scaling. Returns `nothing` if not defined."
function lookup_fluid_reference_temperature(fluid::FluidType)::Union{Float64, Nothing}
    ref = get(_fluid_reference_temperatures, fluid, nothing)
    return isnothing(ref) ? nothing : ref[]
end

#= ---------- Setters ----------- =#

"Set the exhaust velocity for a fluid type. Use for runtime tuning."
function set_fluid_exhaust_velocity!(fluid::FluidType, value::Float64)
    ref = get(_fluid_exhaust_velocities, fluid, nothing)
    isnothing(ref) && error("No exhaust velocity configured for fluid type $(fluid)")
    atomic_xchg!(ref, value)
    return nothing
end

"Set the density for a fluid type. Use for runtime tuning."
function set_fluid_density!(fluid::FluidType, value::Float64)
    ref = get(_fluid_densities, fluid, nothing)
    isnothing(ref) && error("No density configured for fluid type $(fluid)")
    atomic_xchg!(ref, value)
    return nothing
end

"Set the reference temperature for exhaust velocity scaling. Use for runtime tuning."
function set_fluid_reference_temperature!(fluid::FluidType, value::Float64)
    ref = get(_fluid_reference_temperatures, fluid, nothing)
    isnothing(ref) && error("No reference temperature configured for fluid type $(fluid)")
    atomic_xchg!(ref, value)
    return nothing
end

#= ---------- Snapshots ----------- =#

"Return a snapshot of exhaust velocities for UI enumeration."
get_fluid_exhaust_velocities()::Dict{FluidType, Float64} =
    Dict(k => v[] for (k, v) in _fluid_exhaust_velocities)

"Return a snapshot of fluid densities for UI enumeration."
get_fluid_densities()::Dict{FluidType, Float64} =
    Dict(k => v[] for (k, v) in _fluid_densities)

"Return a snapshot of reference temperatures for UI enumeration."
get_fluid_reference_temperatures()::Dict{FluidType, Float64} =
    Dict(k => v[] for (k, v) in _fluid_reference_temperatures)

# ===============================================================
# Display
# ===============================================================

"Human-readable label for a `FluidType` value."
function fluid_type_label(ft::FluidType)::String
    ft == COLD_GAS        && return "Cold Gas"
    ft == MONOPROP_LIQUID && return "Monopropellant"
    ft == MONOPROP_GAS    && return "Monopropellant Gas"
    ft == FUEL_LIQUID     && return "Fuel"
    ft == OXIDISER_LIQUID && return "Oxidiser"
    ft == BIPROP_EXHAUST  && return "Bipropellant Exhaust"
    return "Unknown ($(string(ft)))"
end

fluid_type_label(::Nothing) = nothing

"Human-readable label for a `FluidConstraint` value."
function fluid_constraint_label(fc::FluidConstraint)::String
    fc == IS_GAS    && return "Gas (any)"
    fc == IS_LIQUID && return "Liquid (any)"
    return "Unknown ($(string(fc)))"
end

end # module HexFluids
