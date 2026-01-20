# Custom Component Pacakges
using HexFlowBasicComponents
using HexFlowTankComponents
using HexFlowSwitchComponents
using HexFlowNozzleComponents
using HexFlowPumpComponents
using HexFlowPipeComponents
using HexFlowBasicPipes
using HexComponentsAPI

const BIGPRIME::Int32 = Int32(357239)

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

const BasicDecompChamber = DecompChamberCompBehav(expansion_factor = 5.0)

const TinyNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 0.1,
    sprite = Symbol("AllNozzles_TinyNozzle")
)

const SmallNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 0.3,
    sprite = Symbol("AllNozzles_SmallNozzle")
)

const MediumNozzle = BasicNozzleCompBehav(
    connected_node = HexFrame.NODE_Q_POS,
    throat_area = 1.0,
    sprite = Symbol("AllNozzles_MediumNozzle")
)

const SwitchedTinyNozzle = SwitchedNozzleCompBehav(
    throat_area = 0.1,
    connected_node = HexFrame.NODE_Q_POS,
    max_conductance = 2.0,
    min_conductance = 0.0,
    change_rate = 6.0 / 60
)

const TurboPump = TurboPumpCompBehav(
    pump_voltage = 50.0,
    series_conductance = 1.0,
    turbine_gain = -0.2,
)

const ElecTurboPump = ElectricPumpCompBehav(
    ElectricTurboPump;
    pump_voltage = 50.0,
    max_energy = 100000.0,
    initial_energy = 100000.0,
    max_conductance = 1.0,  # using old series_conductance as max
    min_conductance = 0.0,
    change_rate = 1.0 / 60  # takes about 1 second to switch (1.0/1.0)
)

const ElecTransferPump = ElectricPumpCompBehav(
    ElectricTransferPump;
    pump_voltage = 5.0,
    max_energy = 1000000.0,
    initial_energy = 1000000.0,
    max_conductance = 0.5,  # using old series_conductance as max
    min_conductance = 0.0,
    change_rate = 0.4 / 60  # takes about 0.5 seconds to switch (0.2/0.4)
)

const TriGasTank = ThevininTankCompBehav(
    GasTankBehavFrag, 3;
    fluid = HexFluids.COLD_GAS,
    max_charge = 200,
    max_voltage = 50,
    initial_charge = 150,
    series_conductance = 5.0
)

const TriLiquidTank = ThevininTankCompBehav(
    LiquidTankBehavFrag, 3;
    fluid = HexFluids.MONOPROP_LIQUID,
    max_charge = 200,
    max_voltage = 1,
    initial_charge = 150,
    series_conductance = 5.0
)

const BigAdjustableValve = BigAdjustableValveCompBehav(
    max_conductance = 2.0,
    min_conductance = 0.0,
    percentage_step_size = 0.05,  # 5% steps in log space
    change_rate = 0.25 / 60
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
    BigAdjustableValve,
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
        throat_area = pick_from_range(0.05, 0.15, point, seed),
        sprite = :AllNozzles_TinyNozzle
    )
end

function roll_component(::Val{:SmallNozzle_comp}, point, seed)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = pick_from_range(0.2, 0.4, point, seed),
        sprite = :AllNozzles_SmallNozzle
    )
end

function roll_component(::Val{:MediumNozzle_comp}, point, seed)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = pick_from_range(0.8, 1.2, point, seed),
        sprite = :AllNozzles_MediumNozzle
    )
end

function roll_component(::Val{:SwitchedTinyNozzle_comp}, point, seed)
    return SwitchedNozzleCompBehav(
        throat_area = pick_from_range(0.05, 0.15, point, seed),
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = pick_from_range(1.0, 3.0, point, seed),
        min_conductance = 0.0,
        change_rate = pick_from_range(6.0 / 60, 10.0 / 60, point, seed)
    )
end

function roll_component(::Val{:TurboPump_comp}, point, seed)
    return TurboPumpCompBehav(
        pump_voltage = pick_from_range(30.0, 70.0, point, seed),
        series_conductance = pick_from_range(0.5, 2.0, point, seed),
        turbine_gain = pick_from_range(-0.3, -0.1, point, seed),
    )
end

function roll_component(::Val{:ElecTurboPump_comp}, point, seed)
    energy = pick_from_range(100000.0, 500000.0, point, seed)
    return ElectricPumpCompBehav(
        ElectricTurboPump;
        pump_voltage = pick_from_range(20.0, 50.0, point, seed),
        max_energy = energy,
        initial_energy = energy,
        max_conductance = pick_from_range(0.5, 2.0, point, seed),
        min_conductance = 0.0,
        change_rate = 1.0 / 60
    )
end

function roll_component(::Val{:ElecTransferPump_comp}, point, seed)
    energy = pick_from_range(500000.0, 2000000.0, point, seed)
    return ElectricPumpCompBehav(
        ElectricTransferPump;
        pump_voltage = 5.0,
        max_energy = energy,
        initial_energy = energy,
        max_conductance = pick_from_range(0.3, 1.0, point, seed),
        min_conductance = 0.0,
        change_rate = 0.4 / 60
    )
end

function roll_component(::Val{:TriGasTank_comp}, point, seed)
    max_charge = pick_from_range(100.0, 500.0, point, seed)
    initial_charge = max_charge * pick_from_range(0.3, 1.0, get_noise(point, seed), seed)

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
    max_charge = pick_from_range(100.0, 500.0, point, seed)
    initial_charge = max_charge * pick_from_range(0.3, 1.0, get_noise(point, seed), seed)

    return ThevininTankCompBehav(
        LiquidTankBehavFrag, 3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = max_charge,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = pick_from_range(4.0, 6.0, point, seed)
    )
end

function roll_component(::Val{:BigAdjustableValve_comp}, point, seed)
    return BigAdjustableValveCompBehav(
        max_conductance = 2.0,
        min_conductance = 0.0,
        percentage_step_size = 0.05,  # 5% steps in log space
        change_rate = pick_from_range(0.25 / 60, 0.5 / 60, point, seed)
    )
end

function roll_component(::Val{:BasicDecompChamber_comp}, point, seed)
    return DecompChamberCompBehav(
        expansion_factor = pick_from_range(4.5, 5.5, point, seed)
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

const shipset_simple_cold_gas = ShipComponentSet(
    "Simple Cold Gas",
    [
        CompSpawnOptions(:TriGasTank_comp, [(1, 100.0), (2, 200.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:SwitchedTinyNozzle_comp, [(1, 50.0), (2, 100.0), (3, 20.0), (4, 20.0)], NOZZLE_EDGE_PLACE),
        CompSpawnOptions(:TinyNozzle_comp, [(0, 80.0), (2, 10.0), (3, 10.0)], NOZZLE_EDGE_PLACE),
    ]
)

const shipset_electric_monoprop = ShipComponentSet(
    "Electric Monoprop",
    [
        CompSpawnOptions(:TriLiquidTank_comp, [(1, 100.0), (2, 200.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:ElecTurboPump_comp, [(1, 100.0), (2, 100.0)], RANDOM_PLACE),
        CompSpawnOptions(:BasicDecompChamber_comp, [(1, 100.0), (2, 20.0)], RANDOM_PLACE),
        CompSpawnOptions(:SmallNozzle_comp, [(1, 100.0), (2, 10.0)], NOZZLE_EDGE_PLACE),
    ]
)

const shipset_turbine_monoprop = ShipComponentSet(
    "Turbine Monoprop",
    [
        CompSpawnOptions(:TriLiquidTank_comp, [(1, 20.0), (2, 200.0), (3, 200.0)], CLUSTERED_PLACE),
        CompSpawnOptions(:BigAdjustableValve_comp, [(1, 100.0)], RANDOM_PLACE),
        CompSpawnOptions(:TurboPump_comp, [(1, 100.0),], RANDOM_PLACE),
        CompSpawnOptions(:BasicDecompChamber_comp, [(1, 100.0), (2, 20.0)], RANDOM_PLACE),
        CompSpawnOptions(:SmallNozzle_comp, [(1, 100.0), (2, 10.0)], NOZZLE_EDGE_PLACE),
    ]
)

ship_gen_tilesets::Vector{ShipComponentSet} = [
    shipset_simple_cold_gas,
    shipset_electric_monoprop,
    shipset_turbine_monoprop,
]

standard_pipeoptions::Vector{PipeSpawnOptions} = [
    PipeSpawnOptions(:BigPipe_pipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.05),
    PipeSpawnOptions(:ScrapPipe_pipe, HexFlowProcGen.RANDOM_PIPES, 0.03),
]

# Ship Configurations
coldgas_micro_ship = ShipGenOptions(
    name = "Cold Gas Micro Ship",
    surface_gen_steps = 2,
    surface_gen_stacks = 10,
    component_sets = [shipset_simple_cold_gas],
    pipe_sets = standard_pipeoptions
)

monoprop_electric_mini_ship = ShipGenOptions(
    name = "Electric Monoprop Mini Ship",
    surface_gen_steps = 3,
    surface_gen_stacks = 17,
    component_sets = [shipset_electric_monoprop],
    pipe_sets = standard_pipeoptions
)
monoprop_turbine_mini_ship = ShipGenOptions(
    name = "Turbine Monoprop Mini Ship",
    surface_gen_steps = 3,
    surface_gen_stacks = 17,
    component_sets = [shipset_turbine_monoprop],
    pipe_sets = standard_pipeoptions
)

small_corvette_1 = ShipGenOptions(
    name = "Small Corvette 1",
    surface_gen_steps = 4,
    surface_gen_stacks = 20,
    component_sets = [shipset_turbine_monoprop, shipset_simple_cold_gas],
    pipe_sets = standard_pipeoptions
)

ship_gen_configs = [
    coldgas_micro_ship,
    monoprop_electric_mini_ship,
    monoprop_turbine_mini_ship,
    small_corvette_1,
]





