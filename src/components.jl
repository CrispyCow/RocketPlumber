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

# Edge-based pipes
const ScrapPipe = ScrapPipeBehav()

const BigPipe = BigPipeBehav()

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
