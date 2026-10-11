#=
Scope: JLD2 conversions and typemap for previous-release saves
Formatter: Runic
=#

# Rocket Plumber aims to support saves from the previous public release. Its single
# frozen save is the primary end-to-end compatibility regression test. When a changed
# persisted type or state is not represented by that fixture, add a small targeted
# historical migration test. Development/prerelease saves remain best-effort.
# The sole provisional teaser_0.1.0-dev.jld2 baseline in test/fixtures is replaced
# by a final-release save at 0.1.0, rather than accumulated alongside it.
#
# Add release migrations here as rconvert(::Type{CurrentType}, old::NamedTuple)
# methods and entries in the typemap below. Parameter-dependent conversions use
# the callback to retain historical variant identities.

"Build the JLD2 typemap for release compatibility migrations."
function _build_map_typemap()
    upgrades = Dict{String, Any}(
        "HexFlowBasicComponents.BinaryStateBehavFrag" => JLD2.Upgrade(Bool),
        "HexFlowBasicComponents.FloatStateBehavFrag" => JLD2.Upgrade(Float64),
        "HexFlowBasicComponents.AutoDeactivationBehavFrag" => JLD2.Upgrade(AutoDeactivationState),
        "HexFlowBasicComponents.StallBehavFrag" => JLD2.Upgrade(StallStateBehavFrag),
        "HexFlowBasicComponents.ComponentTemperatureBehavFrag" => JLD2.Upgrade(ComponentTemperatureState),
        "HexFlowBasicComponents.DamageStateBehavFrag" => JLD2.Upgrade(DamageStateBehavFrag),
        "HexFlowTankComponents.FixedFluidBehavFrag" => JLD2.Upgrade(FixedFluid),
        "HexFlowTankComponents.StoredFluidBehavFrag" => JLD2.Upgrade(StoredFluidState),
        "HexFlowTankComponents.StoredFluidState" => JLD2.Upgrade(StoredFluidState),
        "HexFlowTankComponents.SealStateBehavFrag" => JLD2.Upgrade(SealState),
        "HexFlowNozzleComponents.BipropChamberState" => JLD2.Upgrade(HexFlowNozzleComponents.BipropChamberState),
        "HexFlowPumpComponents.RotorStateBehavFrag" => JLD2.Upgrade(Rotor),
        "HexFlowPumpComponents.DelayedDriveBehavFrag" => JLD2.Upgrade(DelayedDrive),
        "HexFlowPumpComponents.EnergyStoreBehavFrag" => JLD2.Upgrade(EnergyStore),
        "HexFlowBasicComponents.PlainSpriteBehavFrag" => JLD2.Upgrade(NamedTuple),
        "HexFlowSwitchComponents.TinyValve" => Val{TINY_VALVE},
        "HexFlowSwitchComponents.LargeValve" => Val{LARGE_VALVE},
        "HexFlowPumpComponents.ElectricTurboPump" => Val{ELECTRIC_TURBO_PUMP},
        "HexFlowPumpComponents.ElectricTransferPump" => Val{ELECTRIC_TRANSFER_PUMP},
        "HexFlowPumpComponents.ElectricPumpType" => ElectricPumpVariant,
    )
    return (file, typepath, params) -> _map_saved_type(file, typepath, params, upgrades)
end

# Primitive wrappers in older saves become ordinary fields in semantic value types.
rconvert(::Type{Bool}, old::NamedTuple) = old.state
rconvert(::Type{Float64}, old::NamedTuple) = old.state
rconvert(::Type{AutoDeactivationState}, old::NamedTuple) = AutoDeactivationState(old.inactive_state)
rconvert(::Type{StallStateBehavFrag}, old::NamedTuple) = StallStateBehavFrag(old.stall_state)
rconvert(::Type{SealState}, old::NamedTuple) = SealState(old.seal_state)
rconvert(::Type{ComponentTemperatureState}, old::NamedTuple) = ComponentTemperatureState(old.temperature_state)

# Damage retains its type name, so both historical and current layouts pass here.
rconvert(::Type{DamageStateBehavFrag}, old::NamedTuple) = DamageStateBehavFrag(hasproperty(old, :damaged) ? old.damaged : old.damage_state)

# Reconstruct from runtime values, preserving overspeed rather than using initial-state constructors.
rconvert(::Type{Rotor}, old::NamedTuple) = Rotor(RotorState(old.rpm), old.max_rpm, old.rotor_inertia, old.friction_coefficient)
rconvert(::Type{DelayedDrive}, old::NamedTuple) = DelayedDrive(DelayedDriveState(old.power), old.time_constant)
rconvert(::Type{EnergyStore}, old::NamedTuple) = EnergyStore(EnergyStoreState(old.stored_energy), old.max_energy)

rconvert(::Type{FixedFluid}, old::NamedTuple) = FixedFluid(old.fluid)
"Preserve optional fluid identity across wrapper, union-field and concrete-field layouts."
function rconvert(::Type{StoredFluidState}, old::NamedTuple)
    hasproperty(old, :state) && return old.state
    hasproperty(old, :fluid) && return StoredFluidState(old.fluid)
    return StoredFluidState(old.fluid_value, old.has_fluid)
end

"Preserve chamber temperature and auto-deactivation across the temperature-field rename."
function rconvert(::Type{HexFlowNozzleComponents.BipropChamberState}, old::NamedTuple)
    temperature = hasproperty(old, :output_temperature_k) ? old.output_temperature_k : old.output_temperature_state
    return HexFlowNozzleComponents.BipropChamberState(temperature, old.auto_deactivation)
end

# Historical size/variant parameters are absent from the saved fields. Carry them
# to rconvert in a union target; the returned value is always the current behaviour,
# never the Val tag. No migration tags enter current saves or the live map.
"Map persisted component types, retaining historical parameters needed for conversion."
function _map_saved_type(file::JLD2.JLDFile, typepath::String, params::Vector, upgrades::Dict{String, Any})
    haskey(upgrades, typepath) && return upgrades[typepath]
    if typepath == "HexFlowBasicComponents.BasicCompBehav" && length(params) == 1
        return JLD2.Upgrade(BasicCompBehav{params[1]})
    elseif typepath == "HexFlowNozzleComponents.BasicNozzleCompBehav"
        return JLD2.Upgrade(BasicNozzleCompBehav)
    elseif typepath == "HexFlowSwitchComponents.StandardValveCompBehav" && length(params) == 2
        params[2] isa TypeVar && return StandardValveCompBehav{params[1]}
        return JLD2.Upgrade(Union{StandardValveCompBehav{params[1]}, params[2]})
    elseif typepath == "HexFlowPumpComponents.ElectricPumpCompBehav" && length(params) == 1
        params[1] isa TypeVar && return ElectricPumpCompBehav
        return JLD2.Upgrade(Union{ElectricPumpCompBehav, params[1]})
    elseif typepath == "HexComponentsAPI.PlacedComponent"
        # Infer the concrete parameter from the upgraded component, including its sprite.
        return JLD2.Upgrade(PlacedComponent)
    end
    return JLD2.default_typemap(file, typepath, params)
end

rconvert(::Type{BasicCompBehav{N}}, old::NamedTuple) where {N} = BasicCompBehav(elems = old.elems, sprite = old.sprite.sprite)
rconvert(::Type{Union{StandardValveCompBehav{S}, Val{SIZE}}}, old::NamedTuple) where {S, SIZE} = StandardValveCompBehav(old.switch, SIZE)
rconvert(::Type{Union{ElectricPumpCompBehav, Val{VARIANT}}}, old::NamedTuple) where {VARIANT} = ElectricPumpCompBehav(VARIANT, old.pump, old.energy, old.switch)
rconvert(::Type{PlacedComponent}, old::NamedTuple) = PlacedComponent(old.component, old.rotation, old.mirrored, old.ship)

"Recover a historical nozzle's sprite choice, rejecting unknown sprite identities."
function rconvert(::Type{BasicNozzleCompBehav}, old::NamedTuple)
    hasproperty(old, :sprite_variant) && return BasicNozzleCompBehav(old.nozzle, old.sprite_variant)
    sprite = old.sprite.sprite
    variant = if sprite === :AllNozzles_TinyNozzle
        TINY_NOZZLE_SPRITE
    elseif sprite === :AllNozzles_SmallNozzle
        SMALL_NOZZLE_SPRITE
    elseif sprite === :AllNozzles_MediumNozzle
        MEDIUM_NOZZLE_SPRITE
    else
        throw(ArgumentError("Unknown historical basic-nozzle sprite: $sprite"))
    end
    return BasicNozzleCompBehav(old.nozzle, variant)
end
