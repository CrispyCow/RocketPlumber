# Custom Component Pacakges
using HexFlowBasicComponents
using HexFlowTankComponents
using HexFlowSwitchComponents
using HexFlowNozzleComponents
using HexFlowPumpComponents
using HexFlowBasicPipes
using HexComponentsAPI

# ===============================================================
# Component Instantiations
# ===============================================================

const CONST_RESISTOR = HexElements.CONST_RESISTOR
const CONST_CURRENT = HexElements.CONST_CURRENT
const CONST_VOLTAGE = HexElements.CONST_VOLTAGE
const C_DEP_CURRENT = HexElements.C_DEP_CURRENT
const V_DEP_VOLTAGE = HexElements.V_DEP_VOLTAGE

const horizontal_element = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG)
const horizontal_grounded = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND)

const BasicDecompChamber = DecompChamberCompBehav()

const BasicBipropChamber = BipropChamberCompBehav(
    fuel_conductance = 0.4,
    oxid_conductance = 1.0
)

const TinyNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 0.2,
    sprite = Symbol("AllNozzles_TinyNozzle")
)

const SmallNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 0.5,
    sprite = Symbol("AllNozzles_SmallNozzle")
)

const MediumNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 1.5,
    sprite = Symbol("AllNozzles_MediumNozzle")
)

const SwitchedTinyNozzle = SwitchedNozzleCompBehav(
    throat_area = 0.2,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
    limit_temperature_k = 400.0,
)

const TurboPump = TurboPumpCompBehav(
    max_pump_voltage = 50.0,
    series_conductance = 1.0,
    thermal_mass = 2.0,
    heat_loss_factor = 0.05,
)

const ElecTurboPump = ElectricPumpCompBehav(
    ElectricTurboPump;
    pump_voltage = 50.0,
    max_energy = 100000.0,
    initial_energy = 100000.0,
    max_conductance = 1.0,  # using old series_conductance as max
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(1.0, 0.0, 1.0 / BASE_UPS)
)

const ElecTransferPump = ElectricPumpCompBehav(
    ElectricTransferPump;
    pump_voltage = 5.0,
    max_energy = 150000.0,
    initial_energy = 150000.0,
    max_conductance = 0.5,  # using old series_conductance as max
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(0.5, 0.0, 0.4 / BASE_UPS)
)

const TriGasTank = ThevininTankCompBehav(
    GasTankBehavFrag, 3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 50.0 / (HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64),
    max_voltage = 50,
    initial_charge = 40.0 / (HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64),
    series_conductance = 5.0
)

const TriLiquidTank = ThevininTankCompBehav(
    LiquidTankBehavFrag, 3;
    fluid = HexFluids.MONOPROP_LIQUID,
    max_charge = 200.0 / (HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64),
    max_voltage = 1,
    initial_charge = 150.0 / (HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64),
    series_conductance = 5.0
)

const TriFuelTank = ThevininTankCompBehav(
    LiquidTankBehavFrag, 3;
    fluid = HexFluids.FUEL_LIQUID,
    max_charge = 200.0 / (HexFluids.lookup_fluid_density(HexFluids.FUEL_LIQUID)::Float64),
    max_voltage = 1,
    initial_charge = 150.0 / (HexFluids.lookup_fluid_density(HexFluids.FUEL_LIQUID)::Float64),
    series_conductance = 5.0
)

const TriOxidiserTank = ThevininTankCompBehav(
    LiquidTankBehavFrag, 3;
    fluid = HexFluids.OXIDISER_LIQUID,
    max_charge = 200.0 / (HexFluids.lookup_fluid_density(HexFluids.OXIDISER_LIQUID)::Float64),
    max_voltage = 1,
    initial_charge = 150.0 / (HexFluids.lookup_fluid_density(HexFluids.OXIDISER_LIQUID)::Float64),
    series_conductance = 5.0
)

const PressureFedLiquidTank = PressureFedTankCompBehav(
    PressureFedTankBehavFrag(
        initial_liquid_charge = 150.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        initial_gas_charge = 0.0,
        max_liquid_charge = 200.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = HexFluids.MONOPROP_LIQUID
    ),
    (HexFrame.NODE_Q_NEG,),
    5.0,
    HexFluids.COLD_GAS,
    NoRotationBehavFrag()
)

const LargeAdjValve = StandardValveCompBehav(SteppedSwitchBehavFrag, LargeValve;
    max_conductance = 4.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(4.0, 0.0, 2.0 / BASE_UPS),
    percentage_step_size = 0.05
)

const TinyAdjValve = StandardValveCompBehav(SteppedSwitchBehavFrag, TinyValve;
    max_conductance = 1.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS),
    percentage_step_size = 0.05
)

const LargeOnOffValve = StandardValveCompBehav(BoolSwitchBehavFrag, LargeValve;
    max_conductance = 4.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(4.0, 0.0, 2.0 / BASE_UPS)
)

const TinyOnOffValve = StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
    max_conductance = 1.0,
    min_conductance = 0.0,
    growth_factor = calculate_growth_factor(1.0, 0.0, 2.0 / BASE_UPS)
)

# Pipe-segment behaviours
const ScrapPipe = ScrapPipeBehav()

const BigPipe = BigPipeBehav()

# ===============================================================
# Component List
# ===============================================================

const component_list::Vector{ComponentBehavior} = ComponentBehavior[
    BasicDecompChamber,
    BasicBipropChamber,
    TurboPump,
    ElecTurboPump,
    ElecTransferPump,
    TinyNozzle,
    SmallNozzle,
    MediumNozzle,
    SwitchedTinyNozzle,
    TriGasTank,
    TriLiquidTank,
    TriFuelTank,
    TriOxidiserTank,
    PressureFedLiquidTank,
    LargeAdjValve,
    TinyAdjValve,
    LargeOnOffValve,
    TinyOnOffValve,
]

# ==============================================================
# Component Procedural Generation Rules
# ==============================================================

# component roll functions
import HexFlowProcGen: roll_component
# Specializations for each component type
function roll_component(::Val{:TinyNozzle_comp}, point, seed)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = pick_from_range(0.15, 0.25, point, seed),
        sprite = :AllNozzles_TinyNozzle
    )
end

function roll_component(::Val{:SmallNozzle_comp}, point, seed)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = pick_from_range(0.4, 0.6, point, seed),
        sprite = :AllNozzles_SmallNozzle
    )
end

function roll_component(::Val{:MediumNozzle_comp}, point, seed)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = pick_from_range(1.3, 1.7, point, seed),
        sprite = :AllNozzles_MediumNozzle
    )
end

function roll_component(::Val{:SwitchedTinyNozzle_comp}, point, seed)
    max_c = pick_from_range(1.0, 3.0, point, seed)
    return SwitchedNozzleCompBehav(
        throat_area = pick_from_range(0.15, 0.25, point, seed),
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = max_c,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(max_c, 0.0,
            pick_from_range(6.0, 10.0, point, seed) / BASE_UPS)
    )
end

function roll_component(::Val{:TurboPump_comp}, point, seed)
    return TurboPumpCompBehav(
        max_pump_voltage = pick_from_range(45.0, 55.0, point, seed),
        series_conductance = pick_from_range(0.8, 1.2, point, seed),
    )
end

function roll_component(::Val{:ElecTurboPump_comp}, point, seed) # removed from procedural generation, but left in the game for potential future use
    energy = pick_from_range(200000.0, 500000.0, point, seed)
    max_c = pick_from_range(0.5, 2.0, point, seed)
    return ElectricPumpCompBehav(
        ElectricTurboPump;
        pump_voltage = pick_from_range(20.0, 50.0, point, seed),
        max_energy = energy,
        initial_energy = energy,
        max_conductance = max_c,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(max_c, 0.0, 1.0 / BASE_UPS)
    )
end

function roll_component(::Val{:ElecTransferPump_comp}, point, seed)
    energy = pick_from_range(150000.0, 200000.0, point, seed)
    max_c = pick_from_range(0.3, 1.0, point, seed)
    return ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = energy,
        initial_energy = energy,
        max_conductance = max_c,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(max_c, 0.0, 0.4 / BASE_UPS)
    )
end

function roll_component(::Val{:TriGasTank_comp}, point, seed)
    gas_density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    max_charge = pick_from_range(25.0, 75.0, point, seed) / gas_density
    initial_charge = max_charge * pick_from_range(0.25, 0.75, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = max_charge,
        max_voltage = 50.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
end

"Roll a Thevinin liquid tank for `fluid`; `fill_range` controls the initial fill fraction."
function _roll_tri_liquid_tank(fluid, fill_range::Tuple{Float64, Float64}, point, seed)
    liquid_density = HexFluids.lookup_fluid_density(fluid)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    fill_min, fill_max = fill_range
    initial_charge = max_charge * pick_from_range(fill_min, fill_max, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = fluid,
        max_charge = max_charge,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
end

"Roll a pressure-fed tank whose liquid side is `liquid_fluid` and whose pressurant remains cold gas."
function _roll_pressure_fed_tank(liquid_fluid, fill_range::Tuple{Float64, Float64}, point, seed)
    liquid_density = HexFluids.lookup_fluid_density(liquid_fluid)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    fill_min, fill_max = fill_range
    initial_charge = max_charge * pick_from_range(fill_min, fill_max, get_noise(point, seed), seed)

    return PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = initial_charge,
            initial_gas_charge = 0.0,
            max_liquid_charge = max_charge,
            max_gas_pressure = pick_from_range(40.0, 60.0, point, seed),
            gas_node = HexFrame.NODE_Q_POS,
            initial_liquid_fluid = liquid_fluid
        ),
        (HexFrame.NODE_Q_NEG,),
        pick_from_range(3.0, 7.0, point, seed),
        HexFluids.COLD_GAS,
        NoRotationBehavFrag()
    )
end

function roll_component(::Val{:TriLiquidTank_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.MONOPROP_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:TriFuelTank_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.FUEL_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:TriOxidiserTank_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.OXIDISER_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:TriGasTank_full_comp}, point, seed)
    gas_density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    max_charge = pick_from_range(25.0, 75.0, point, seed) / gas_density
    initial_charge = max_charge * pick_from_range(0.75, 1.0, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        GasTankBehavFrag, 3;
        fluid = HexFluids.COLD_GAS,
        max_charge = max_charge,
        max_voltage = 50.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
end

function roll_component(::Val{:TriLiquidTank_full_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.MONOPROP_LIQUID, (0.75, 1.0), point, seed)
end

function roll_component(::Val{:TriFuelTank_full_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.FUEL_LIQUID, (0.75, 1.0), point, seed)
end

function roll_component(::Val{:TriOxidiserTank_full_comp}, point, seed)
    return _roll_tri_liquid_tank(HexFluids.OXIDISER_LIQUID, (0.75, 1.0), point, seed)
end

function roll_component(::Val{:PressureFedLiquidTank_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.MONOPROP_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:PressureFedFuelTank_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.FUEL_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:PressureFedOxidiserTank_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.OXIDISER_LIQUID, (0.25, 0.75), point, seed)
end

function roll_component(::Val{:PressureFedLiquidTank_full_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.MONOPROP_LIQUID, (0.75, 0.98), point, seed)
end

function roll_component(::Val{:PressureFedFuelTank_full_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.FUEL_LIQUID, (0.75, 0.98), point, seed)
end

function roll_component(::Val{:PressureFedOxidiserTank_full_comp}, point, seed)
    return _roll_pressure_fed_tank(HexFluids.OXIDISER_LIQUID, (0.75, 0.98), point, seed)
end

function roll_component(::Val{:LargeAdjValve_comp}, point, seed)
    return StandardValveCompBehav(SteppedSwitchBehavFrag, LargeValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0,
            pick_from_range(1.0, 1.5, point, seed) / BASE_UPS),
        percentage_step_size = 0.05
    )
end

function roll_component(::Val{:TinyAdjValve_comp}, point, seed)
    return StandardValveCompBehav(SteppedSwitchBehavFrag, TinyValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0,
            pick_from_range(5.0, 7.0, point, seed) / BASE_UPS),
        percentage_step_size = 0.05
    )
end

function roll_component(::Val{:LargeOnOffValve_comp}, point, seed)
    return StandardValveCompBehav(BoolSwitchBehavFrag, LargeValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0,
            pick_from_range(1.0, 1.5, point, seed) / BASE_UPS)
    )
end

function roll_component(::Val{:TinyOnOffValve_comp}, point, seed)
    return StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0,
            pick_from_range(5.0, 7.0, point, seed) / BASE_UPS)
    )
end

function roll_component(::Val{:BasicDecompChamber_comp}, point, seed)
    return DecompChamberCompBehav()
end

function roll_component(::Val{:BasicBipropChamber_comp}, point, seed)
    return BipropChamberCompBehav(
        fuel_conductance = 0.4,
        oxid_conductance = 1.0
    )
end

# pipe roll functions
import HexFlowProcGen: roll_pipe
# Specializations for each pipe type
function roll_pipe(::Val{:ScrapPipe_pipe}, point, seed)
    return ScrapPipeBehav()
end

function roll_pipe(::Val{:BigPipe_pipe}, point, seed)
    return BigPipeBehav()
end

# Ship Component Sets

const NOZZLE_EDGE_PLACE = HexFlowProcGen.NOZZLE_EDGE_PLACE
const CLUSTERED_PLACE = HexFlowProcGen.CLUSTERED_PLACE
const RANDOM_PLACE = HexFlowProcGen.RANDOM_PLACE

shipset_starter = ShipComponentSet(
    "Starter Cold Gas",
    [
        CompSpawnOptions(:TriGasTank_full_comp, [(2, 100.0), (3, 200.0), (4, 100.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:SwitchedTinyNozzle_comp, [(3, 20.0), (4, 20.0)], NOZZLE_EDGE_PLACE),
    ]
)

shipset_simple_cold_gas = ShipComponentSet(
    "Simple Cold Gas",
    [
        CompSpawnOptions(:TriGasTank_comp, [(1, 100.0), (2, 200.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:SwitchedTinyNozzle_comp, [(1, 50.0), (2, 100.0), (3, 20.0), (4, 20.0)], NOZZLE_EDGE_PLACE),
        CompSpawnOptions(:TinyNozzle_comp, [(0, 80.0), (2, 10.0), (3, 10.0)], NOZZLE_EDGE_PLACE),
    ]
)

shipset_pressure_fed_monoprop = ShipComponentSet(
    "Pressure Fed Monoprop",
    [
        CompSpawnOptions(:PressureFedLiquidTank_full_comp, [(2, 100.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:TriGasTank_full_comp, [(1, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:BasicDecompChamber_comp, [(1, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyOnOffValve_comp, [(1, 200.0), (2, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyAdjValve_comp, [(0, 200.0), (1, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyNozzle_comp, [(1, 100.0), (2, 200.0)], NOZZLE_EDGE_PLACE),
        CompSpawnOptions(:SmallNozzle_comp, [(1, 100.0), (0, 200.0)], NOZZLE_EDGE_PLACE),
    ]
)

shipset_biprop_pressure_fed = ShipComponentSet(
    "Pressure Fed Biprop",
    [
        CompSpawnOptions(:PressureFedFuelTank_full_comp, [(1, 100.0), (2, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:PressureFedOxidiserTank_full_comp, [(1, 100.0), (2, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:TriGasTank_full_comp, [(1, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:BasicBipropChamber_comp, [(1, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyOnOffValve_comp, [(1, 200.0), (2, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyAdjValve_comp, [(0, 200.0), (1, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyNozzle_comp, [(1, 100.0), (2, 200.0)], NOZZLE_EDGE_PLACE),
        CompSpawnOptions(:SmallNozzle_comp, [(1, 100.0), (0, 200.0)], NOZZLE_EDGE_PLACE),
    ]
)

standard_pipeoptions::Vector{PipeSpawnOptions} = [
    PipeSpawnOptions(:BigPipe_pipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.05),
    PipeSpawnOptions(:ScrapPipe_pipe, HexFlowProcGen.RANDOM_PIPES, 0.03),
]

# ===============================================================
# Encounter Generation Configuration
# ===============================================================

# NOTE: The pools and weight vectors in this section are intentionally not
# declared `const` to allow rapid iteration via Revise during development.
# Once tuning is complete, they should be made `const` for performance.

#= ---------- Additional Component Sets ----------- =#

compset_gas_cache = ShipComponentSet(
    "Gas Tank Array",
    [
        CompSpawnOptions(:TriGasTank_full_comp, [(2, 100.0), (3, 200.0), (4, 100.0)], CLUSTERED_PLACE),
    ]
)

compset_liquid_cache = ShipComponentSet(
    "Liquid Tank Array",
    [
        CompSpawnOptions(:TriLiquidTank_full_comp, [(2, 100.0), (3, 200.0), (4, 100.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:ElecTransferPump_comp, [(0, 50.0), (1, 100.0)], RANDOM_PLACE),
    ]
)

compset_fuel_cache = ShipComponentSet(
    "Fuel Tank Array",
    [
        CompSpawnOptions(:TriFuelTank_full_comp, [(2, 100.0), (3, 200.0), (4, 100.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:ElecTransferPump_comp, [(0, 50.0), (1, 100.0)], RANDOM_PLACE),
    ]
)

compset_oxidiser_cache = ShipComponentSet(
    "Oxidiser Tank Array",
    [
        CompSpawnOptions(:TriOxidiserTank_full_comp, [(2, 100.0), (3, 200.0), (4, 100.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:ElecTransferPump_comp, [(0, 50.0), (1, 100.0)], RANDOM_PLACE),
    ]
)

compset_extra_gas_tanks = ShipComponentSet(
    "Extra Gas Tanks",
    [
        CompSpawnOptions(:TriGasTank_comp, [(1, 50.0), (2, 100.0), (3, 150.0), (4, 100.0), (5, 50.0)], CLUSTERED_PLACE),
    ]
)

compset_extra_liquid_tanks = ShipComponentSet(
    "Extra Liquid Tanks",
    [
        CompSpawnOptions(:TriLiquidTank_comp, [(1, 50.0), (2, 100.0), (3, 150.0), (4, 100.0), (5, 50.0)], CLUSTERED_PLACE),
    ]
)

compset_extra_fuel_tanks = ShipComponentSet(
    "Extra Fuel Tanks",
    [
        CompSpawnOptions(:TriFuelTank_comp, [(1, 50.0), (2, 100.0), (3, 150.0), (4, 100.0), (5, 50.0)], CLUSTERED_PLACE),
    ]
)

compset_extra_oxidiser_tanks = ShipComponentSet(
    "Extra Oxidiser Tanks",
    [
        CompSpawnOptions(:TriOxidiserTank_comp, [(1, 50.0), (2, 100.0), (3, 150.0), (4, 100.0), (5, 50.0)], CLUSTERED_PLACE),
    ]
)

compset_scrap_tiny_nozzle = ShipComponentSet("Scrap Tiny Nozzle", [
    CompSpawnOptions(:TinyNozzle_comp, [(1, 1.0)], NOZZLE_EDGE_PLACE),
])
compset_scrap_small_nozzle = ShipComponentSet("Scrap Small Nozzle", [
    CompSpawnOptions(:SmallNozzle_comp, [(1, 1.0)], NOZZLE_EDGE_PLACE),
])
compset_scrap_medium_nozzle = ShipComponentSet("Scrap Medium Nozzle", [
    CompSpawnOptions(:MediumNozzle_comp, [(1, 1.0)], NOZZLE_EDGE_PLACE),
])
compset_scrap_switched_nozzle = ShipComponentSet("Scrap Switched Nozzle", [
    CompSpawnOptions(:SwitchedTinyNozzle_comp, [(1, 1.0)], NOZZLE_EDGE_PLACE),
])
compset_scrap_turbo_pump = ShipComponentSet("Scrap Turbo Pump", [
    CompSpawnOptions(:TurboPump_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_large_adj_valve = ShipComponentSet("Scrap Large Adj Valve", [
    CompSpawnOptions(:LargeAdjValve_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_tiny_adj_valve = ShipComponentSet("Scrap Tiny Adj Valve", [
    CompSpawnOptions(:TinyAdjValve_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_large_onoff_valve = ShipComponentSet("Scrap Large OnOff Valve", [
    CompSpawnOptions(:LargeOnOffValve_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_tiny_onoff_valve = ShipComponentSet("Scrap Tiny OnOff Valve", [
    CompSpawnOptions(:TinyOnOffValve_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_decomp = ShipComponentSet("Scrap Decomp Chamber", [
    CompSpawnOptions(:BasicDecompChamber_comp, [(1, 1.0)], RANDOM_PLACE),
])
compset_scrap_biprop = ShipComponentSet("Scrap Biprop Chamber", [
    CompSpawnOptions(:BasicBipropChamber_comp, [(1, 1.0)], RANDOM_PLACE),
])

#= ---------- Encounter Class Configs ----------- =#

# Component pools by fuel type
_ship_coldgas_pool = WeightedComponentSet[
    WeightedComponentSet(shipset_simple_cold_gas, NoScaling(1.0)),
    WeightedComponentSet(compset_extra_gas_tanks, GatedLinearScaling(0.5, 0.0, 2.0)),
]

_ship_monoprop_pool = WeightedComponentSet[
    WeightedComponentSet(shipset_pressure_fed_monoprop, NoScaling(1.0)),
    WeightedComponentSet(compset_extra_liquid_tanks, GatedLinearScaling(0.3, 0.0, 2.0)),
]

_ship_biprop_pool = WeightedComponentSet[
    WeightedComponentSet(shipset_biprop_pressure_fed, NoScaling(1.0)),
    WeightedComponentSet(compset_extra_fuel_tanks, GatedLinearScaling(0.3, 0.0, 4.0)),
    WeightedComponentSet(compset_extra_oxidiser_tanks, GatedLinearScaling(0.3, 0.0, 4.0)),
]

_cache_coldgas_pool = WeightedComponentSet[
    WeightedComponentSet(compset_gas_cache, NoScaling(1.0)),
]

_cache_monoprop_pool = WeightedComponentSet[
    WeightedComponentSet(compset_liquid_cache, NoScaling(1.0)),
]

_cache_fuel_pool = WeightedComponentSet[
    WeightedComponentSet(compset_fuel_cache, NoScaling(1.0)),
]

_cache_oxidiser_pool = WeightedComponentSet[
    WeightedComponentSet(compset_oxidiser_cache, NoScaling(1.0)),
]

_scrap_pool = WeightedComponentSet[
    WeightedComponentSet(compset_scrap_tiny_nozzle, NoScaling(2.0)),
    WeightedComponentSet(compset_scrap_small_nozzle, GatedLinearScaling(2.6, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_medium_nozzle, GatedLinearScaling(0.8, 0.0, 2.0)),
    WeightedComponentSet(compset_scrap_switched_nozzle, NoScaling(0.8)),
    WeightedComponentSet(compset_scrap_turbo_pump, GatedLinearScaling(1.2, 1.0, 2.0)),
    WeightedComponentSet(compset_scrap_large_adj_valve, GatedLinearScaling(1.0, 0.0, 1.0)),
    WeightedComponentSet(compset_scrap_tiny_adj_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_large_onoff_valve, GatedLinearScaling(1.0, 0.0, 1.0)),
    WeightedComponentSet(compset_scrap_tiny_onoff_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_decomp, GatedLinearScaling(0.4, 0.0, 1.0)),
    WeightedComponentSet(compset_scrap_biprop, GatedLinearScaling(0.4, 0.0, 1.0)),
]

# Pipe options per class
fuel_cache_pipeoptions = PipeSpawnOptions[
    PipeSpawnOptions(:ScrapPipe_pipe, HexFlowProcGen.RANDOM_PIPES, 0.02),
    PipeSpawnOptions(:ScrapPipe_pipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.02),
]

# Per-class encounter generation configs
ship_class_config = EncounterClassConfig(
    NoScaling(3.0),
    HullSizeConfig(LinearScaling(1.0, 0.6), LinearScaling(2.0, 8.0)),
    LinearScaling(1.0, 2.0),
    FluidTaggedEncounterComponents(Dict{FluidType, FuelTagConfig}(
        HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), _ship_coldgas_pool),
        HexFluids.MONOPROP_LIQUID => FuelTagConfig(GatedLinearScaling(0.25, 0.4, 3.0), _ship_monoprop_pool),
        HexFluids.FUEL_LIQUID => FuelTagConfig(GatedLinearScaling(0.25, 0.6, 5.0), _ship_biprop_pool),
    )),
    standard_pipeoptions,
    NoScaling(1.0),
)

fuel_cache_class_config = EncounterClassConfig(
    NoScaling(3.0),
    HullSizeConfig(LinearScaling(1.0, 0.8), LinearScaling(8.0, 10.0)),
    LinearScaling(2.0, 3.0),
    FluidTaggedEncounterComponents(Dict{FluidType, FuelTagConfig}(
        HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), _cache_coldgas_pool),
        HexFluids.MONOPROP_LIQUID => FuelTagConfig(GatedLinearScaling(0.25, 0.4, 4.0), _cache_monoprop_pool),
        HexFluids.FUEL_LIQUID => FuelTagConfig(GatedLinearScaling(0.3, 0.6, 5.5), _cache_fuel_pool),
        HexFluids.OXIDISER_LIQUID => FuelTagConfig(GatedLinearScaling(0.3, 0.6, 5.5), _cache_oxidiser_pool),
    )),
    fuel_cache_pipeoptions,
    LinearScaling(0.8, 0.35),
)

scrap_class_config = EncounterClassConfig(
    NoScaling(3.0),
    HullSizeConfig(LinearScaling(1.0, 0.8), LinearScaling(2.0, 2.0)),
    LinearScaling(0.0, 1.0),
    DirectEncounterComponents(_scrap_pool),
    standard_pipeoptions,
    NoScaling(1.0),
)

encounter_class_configs = Dict{EncounterClass, EncounterClassConfig}(
    ENCOUNTER_SHIP => ship_class_config,
    ENCOUNTER_FUEL_CACHE => fuel_cache_class_config,
    ENCOUNTER_SCRAP => scrap_class_config,
)

const encounter_system_config = EncounterSystemConfig(
    n_points = 120,
    min_base_velocity = 30.0,
    viewport_half_width = 300.0,
    viewport_half_height = 200.0,
    spawn_box_offset = 50.0,
    disappear_box_offset = 100.0,
    encounter_class_configs = encounter_class_configs
)

#= ---------- Starter Ship ----------- =#

const STARTER_SHIP_REROLL_SALT::Int32 = Int32(0x53544152)

"Starter ships must include at least one thruster and one tank (tank with COLD_GAS) so the player can immediately fly."
function starter_ship_is_playable(blueprint::ShipBlueprint)::Bool
    has_thruster = false
    has_tank = false

    for (_, placed_component) in blueprint.components
        component = placed_component.component

        # Check for thruster components (nozzles)
        if component isa BasicNozzleCompBehav || component isa SwitchedNozzleCompBehav || component isa DecompChamberCompBehav
            has_thruster = true
        end

        # Check for tank components with COLD_GAS
        if (component isa ThevininTankCompBehav || component isa PressureFedTankCompBehav) &&
           get_component_wet_mass(component; fluid = HexFluids.COLD_GAS) > 0.0
            has_tank = true
        end

        if has_thruster && has_tank
            return true
        end
    end

    return false
end

"Generate the player's starting ship for explorer mode."
function generate_starter_ship(seed::UInt32)::ShipBlueprint
    current_seed = seed

    while true
        temp_tiles = Set{TileCoord}()
        stacked_random_tile_walk!(temp_tiles, TileCoord(0, 0), 2, 6, current_seed)

        temp_gm = GameMap()
        set_surface_tile!(temp_gm, temp_tiles; ship_name = :primary)
        success, message = place_shipset!(temp_gm, shipset_starter, current_seed)
        if !success
            @warn "Starter ship generation incomplete: $message"
        end

        place_pipeset!(temp_gm, standard_pipeoptions, current_seed)

        blueprint = get_ship_blueprint(temp_gm, :primary)

        if starter_ship_is_playable(blueprint)
            return blueprint
        end

        current_seed = get_noise((STARTER_SHIP_REROLL_SALT,), current_seed)
    end
end





