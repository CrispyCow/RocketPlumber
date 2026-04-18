# Custom Component Pacakges
using HexFlowBasicComponents
using HexFlowTankComponents
using HexFlowSwitchComponents
using HexFlowNozzleComponents
using HexFlowPumpComponents
using HexFlowPipeComponents
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
    growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS)
)

const TurboPump = TurboPumpCompBehav(
    max_pump_voltage = 50.0,
    series_conductance = 1.0,
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

const PressureFedLiquidTank = PressureFedTankCompBehav(
    PressureFedTankBehavFrag(
        initial_liquid_charge = 150.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        initial_gas_charge = 0.0,
        max_liquid_charge = 200.0 / HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID),
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    ),
    (HexFrame.NODE_Q_NEG,),
    5.0,
    HexFluids.COLD_GAS,
    HexFluids.MONOPROP_LIQUID,
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

# Edge-based pipes
const ScrapPipe = ScrapPipeBehav()

const BigPipe = BigPipeBehav()

# ===============================================================
# Component List
# ===============================================================

const component_list::Vector{ComponentBehavior} = ComponentBehavior[
    BasicDecompChamber,
    TurboPump,
    ElecTurboPump,
    ElecTransferPump,
    TinyNozzle,
    SmallNozzle,
    MediumNozzle,
    SwitchedTinyNozzle,
    TriGasTank,
    TriLiquidTank,
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

function roll_component(::Val{:TriLiquidTank_comp}, point, seed)
    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    initial_charge = max_charge * pick_from_range(0.25, 0.75, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = max_charge,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
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
    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    initial_charge = max_charge * pick_from_range(0.75, 1.0, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = max_charge,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
end

function roll_component(::Val{:PressureFedLiquidTank_comp}, point, seed)
    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    initial_charge = max_charge * pick_from_range(0.25, 0.75, get_noise(point, seed), seed)

    return PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = initial_charge,
            initial_gas_charge = 0.0,
            max_liquid_charge = max_charge,
            max_gas_pressure = pick_from_range(40.0, 60.0, point, seed),
            gas_node = HexFrame.NODE_Q_POS
        ),
        (HexFrame.NODE_Q_NEG,),
        pick_from_range(3.0, 7.0, point, seed),
        HexFluids.COLD_GAS,
        HexFluids.MONOPROP_LIQUID,
        NoRotationBehavFrag()
    )
end

function roll_component(::Val{:PressureFedLiquidTank_full_comp}, point, seed)
    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    max_charge = pick_from_range(150.0, 250.0, point, seed) / liquid_density
    initial_charge = max_charge * pick_from_range(0.75, 0.98, get_noise(point, seed), seed)

    return PressureFedTankCompBehav(
        PressureFedTankBehavFrag(
            initial_liquid_charge = initial_charge,
            initial_gas_charge = 0.0,
            max_liquid_charge = max_charge,
            max_gas_pressure = pick_from_range(40.0, 60.0, point, seed),
            gas_node = HexFrame.NODE_Q_POS
        ),
        (HexFrame.NODE_Q_NEG,),
        pick_from_range(3.0, 7.0, point, seed),
        HexFluids.COLD_GAS,
        HexFluids.MONOPROP_LIQUID,
        NoRotationBehavFrag()
    )
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

shipset_turbine_monoprop = ShipComponentSet(
    "Turbine Monoprop",
    [
        CompSpawnOptions(:TriLiquidTank_comp, [(1, 20.0), (2, 200.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:TinyOnOffValve_comp, [(1, 200.0), (2, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TinyAdjValve_comp, [(0, 200.0), (1, 200.0)], RANDOM_PLACE),
        CompSpawnOptions(:TurboPump_comp, [(1, 100.0),], RANDOM_PLACE),
        CompSpawnOptions(:BasicDecompChamber_comp, [(1, 100.0), (2, 20.0)], RANDOM_PLACE),
        CompSpawnOptions(:SmallNozzle_comp, [(2, 100.0), (3, 10.0)], NOZZLE_EDGE_PLACE),
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
compset_scrap_transfer_pump = ShipComponentSet("Scrap Transfer Pump", [
    CompSpawnOptions(:ElecTransferPump_comp, [(1, 1.0)], RANDOM_PLACE),
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

#= ---------- Encounter Class Configs ----------- =#

# Component pools by fuel type
_ship_coldgas_pool = WeightedComponentSet[
    WeightedComponentSet(shipset_simple_cold_gas, NoScaling(1.0)),
    WeightedComponentSet(compset_extra_gas_tanks, GatedLinearScaling(0.5, 0.0, 2.0)),
]

_ship_monoprop_pool = WeightedComponentSet[
    WeightedComponentSet(shipset_pressure_fed_monoprop, NoScaling(1.0)),
    WeightedComponentSet(shipset_turbine_monoprop, GatedLinearScaling(1.0, 0.2, 4.0)),
    WeightedComponentSet(compset_extra_liquid_tanks, GatedLinearScaling(0.3, 0.0, 2.0)),
]

_cache_coldgas_pool = WeightedComponentSet[
    WeightedComponentSet(compset_gas_cache, NoScaling(1.0)),
]

_cache_monoprop_pool = WeightedComponentSet[
    WeightedComponentSet(compset_liquid_cache, NoScaling(1.0)),
]

_scrap_pool = WeightedComponentSet[
    WeightedComponentSet(compset_scrap_tiny_nozzle, NoScaling(2.0)),
    WeightedComponentSet(compset_scrap_small_nozzle, GatedLinearScaling(2.6, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_medium_nozzle, GatedLinearScaling(0.8, 0.0, 2.0)),
    WeightedComponentSet(compset_scrap_switched_nozzle, NoScaling(0.8)),
    WeightedComponentSet(compset_scrap_transfer_pump, GatedLinearScaling(0.6, 0.0, 0.3)),
    WeightedComponentSet(compset_scrap_turbo_pump, GatedLinearScaling(0.3, 0.0, 2.0)),
    WeightedComponentSet(compset_scrap_large_adj_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_tiny_adj_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_large_onoff_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_tiny_onoff_valve, GatedLinearScaling(0.5, 0.0, 0.5)),
    WeightedComponentSet(compset_scrap_decomp, GatedLinearScaling(0.4, 0.0, 1.0)),
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
    Dict{FluidTags, FuelTagConfig}(
        HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), _ship_coldgas_pool),
        HexFluids.MONOPROP_LIQUID => FuelTagConfig(GatedLinearScaling(0.25, 0.4, 2.5), _ship_monoprop_pool),
    ),
    standard_pipeoptions,
)

fuel_cache_class_config = EncounterClassConfig(
    NoScaling(3.0),
    HullSizeConfig(LinearScaling(1.0, 0.3), LinearScaling(8.0, 10.0)),
    LinearScaling(2.0, 3.0),
    Dict{FluidTags, FuelTagConfig}(
        HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), _cache_coldgas_pool),
        HexFluids.MONOPROP_LIQUID => FuelTagConfig(GatedLinearScaling(0.25, 0.4, 2.5), _cache_monoprop_pool),
    ),
    fuel_cache_pipeoptions,
)

scrap_class_config = EncounterClassConfig(
    NoScaling(3.0),
    HullSizeConfig(LinearScaling(1.0, 0.8), LinearScaling(2.0, 2.0)),
    LinearScaling(0.0, 1.0),
    Dict{FluidTags, FuelTagConfig}(
        HexFluids.NONE => FuelTagConfig(NoScaling(1.0), _scrap_pool),
    ),
    standard_pipeoptions,
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

"Starter ships must include at least one nozzle and one cold-gas tank so the player can immediately fly."
function starter_ship_is_playable(shipmap::ShipMap)::Bool
    has_nozzle = false
    has_gas_tank = false

    for (_, component_on_tile) in get_all_components(shipmap)
        component = component_on_tile.component

        if component isa SwitchedNozzleCompBehav
            has_nozzle = true
        end

        if get_component_wet_mass(component; fluid = HexFluids.COLD_GAS) > 0.0
            has_gas_tank = true
        end

        if has_nozzle && has_gas_tank
            return true
        end
    end

    return false
end

"Generate the player's starting ship for explorer mode."
function generate_starter_ship(seed::UInt32)::ShipMap
    current_seed = seed

    while true
        shipmap = ShipMap()
        stacked_random_tile_walk!(get_all_surface_tiles(shipmap), TileCoord(0, 0), 2, 6, current_seed)

        gamemap = GameMap(shipmap)
        success, message = place_shipset!(gamemap, shipset_starter, current_seed)
        if !success
            @warn "Starter ship generation incomplete: $message"
        end

        place_pipeset!(gamemap, standard_pipeoptions, current_seed)
        if starter_ship_is_playable(shipmap)
            return shipmap
        end

        current_seed = get_noise((STARTER_SHIP_REROLL_SALT,), current_seed)
    end
end





