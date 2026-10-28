#=
Scope: Player inspection composition, snapshot readings, and selection integration
Formatter: Runic
=#

using Accessors
using HexComponentsAPI, HexElements, HexFluids
using HexFlowTankComponents, HexFlowPumpComponents, HexFlowNozzleComponents, HexFlowSwitchComponents
using HexFlowBasicComponents
using FlowEngine: MNA_StateSnapshot, solved_element_current

inspection_item(items::Tuple, label::String) = only(filter(item -> hasproperty(item, :label) && item.label == label, items))

@testset "Player inspection" begin
    tile = TileCoord(4, -2)
    derived = DerivedMapState()
    mna = MNA_StateSnapshot()

    @testset "Catalogue coverage and fragment composition" begin
        for comp in RocketPlumber.component_list
            placed = PlacedComponent(comp, HexFrame.S_NEG, true, :primary)
            items = get_inspection_items(placed; derivedmapstate = derived, mna_state = mna, tile)
            @test items isa Tuple
            @test !isempty(items)
            @test all(item -> item isa InspectionItem, items)
            @test first(items) == InspectionDivider("Operation")
            @test count(item -> item == InspectionDivider("Operation"), items) == 1
            @test get_inspection_items(comp; derivedmapstate = derived, mna_state = mna, tile, rotation = placed.rotation, mirrored = placed.mirrored) == items
        end

        valve, _ = do_action(RocketPlumber.LargeOnOffValve, :open_valve)
        items = get_inspection_items(valve; tile, mna_state = mna)
        @test inspection_item(items, "Opening").target == 100.0
        @test inspection_item(items, "Opening").value == 100 * get_switch_percentage(valve.switch)

        damaged = RocketPlumber.TinyNozzle
        damaged = @set damaged.nozzle.overheat.damage = damage(damaged.nozzle.overheat.damage)
        @test any(item -> item isa InspectionAlert && item.tone == INSPECTION_ERROR, get_inspection_items(PlacedComponent(damaged, HexFrame.Q_POS, :primary); tile, derivedmapstate = derived, mna_state = mna))
    end

    @testset "Physical presentation conversions and constructors" begin
        @test volume_to_litres(30) == 150.0
        @test flow_to_litres_per_second(2) == 10.0
        @test pressure_to_bar(50) == 50.0

        contents = inspection_volume_gauge_L("Contents", 30, 40)
        @test contents isa InspectionGauge
        @test (contents.value, contents.minimum, contents.maximum, contents.units) == (150.0, 0.0, 200.0, "L")
        flow = inspection_flow_Lps("Flow", -2)
        @test flow isa InspectionValue
        @test (flow.value, flow.units) == (-10.0, "L/s")
        pressure = inspection_pressure_bar("Pressure", 50)
        @test pressure isa InspectionValue
        @test (pressure.value, pressure.units) == (50.0, "bar")
        pressure_gauge = inspection_pressure_gauge_bar("Pressure", 60, 50)
        @test (pressure_gauge.value, pressure_gauge.minimum, pressure_gauge.maximum, pressure_gauge.units) == (60.0, 0.0, 50.0, "bar")
        @test RocketPlumber.inspection_fraction(pressure_gauge) == 1.0f0
        @test pressure_gauge.value == 60.0
        @test inspection_volume_gauge_L("Contents", -1, 40).value == -5.0
    end

    @testset "Liquid tank contents and runtime stored mass" begin
        tank = RocketPlumber.TriLiquidTank
        items = get_inspection_items(tank)
        contents = inspection_item(items, "Contents")
        @test contents.colour == get_fluid_colour(get_stored_fluid(tank))
        @test contents isa InspectionGauge
        @test (contents.value, contents.maximum, contents.units) == (150.0, 200.0, "L")
        @test all(item -> item.label != "Tank pressure", items)
        @test (inspection_item(items, "Stored mass").value, inspection_item(items, "Stored mass").units) == (150.0, "kg")
        @test inspection_item(items, "Fluid").value == HexFluids.MONOPROP_LIQUID

        # Empty and refill the same tank with a different-density runtime fluid
        live = MNA_State()
        source = first(produce_abs_elements(PlacedComponent(tank, HexFrame.Q_POS, :primary), tile))
        live.vsources[source.id] = source
        live.vsource_currents[source.id] = -tank.tank.tank.state.charge * BASE_UPS
        drained = update_flowbehav(tank; tile, mna_state = live)
        empty_items = get_inspection_items(drained)
        @test inspection_item(empty_items, "Stored mass").value == 0.0
        @test isnothing(inspection_item(empty_items, "Fluid").value)
        @test inspection_item(empty_items, "Contents").colour == ColourType(0.55, 0.55, 0.55, 1.0)
        @test inspection_item(empty_items, "Seal").value == "Unsealed"

        density = lookup_fluid_density(HexFluids.FUEL_LIQUID)
        try
            set_fluid_density!(HexFluids.FUEL_LIQUID, 2.0)
            refilled_derived = DerivedMapState()
            refilled_derived.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_INTERNAL_1)] = HexFluids.FUEL_LIQUID
            live.vsource_currents[source.id] = tank.tank.tank.state.charge * BASE_UPS
            refilled = update_flowbehav(drained; tile, mna_state = live, derivedmapstate = refilled_derived)
            refilled_items = get_inspection_items(refilled)
            @test inspection_item(refilled_items, "Fluid").value == HexFluids.FUEL_LIQUID
            @test inspection_item(refilled_items, "Contents").value == contents.value
            @test inspection_item(refilled_items, "Contents").colour == get_fluid_colour(HexFluids.FUEL_LIQUID)
            @test inspection_item(refilled_items, "Contents").colour != contents.colour
            @test inspection_item(refilled_items, "Stored mass").value == 60.0
            @test inspection_item(refilled_items, "Stored mass").value == get_component_wet_mass(refilled)
        finally
            set_fluid_density!(HexFluids.FUEL_LIQUID, density)
        end
        full = @set tank.tank.tank.state.charge = tank.tank.tank.max_charge
        @test inspection_item(get_inspection_items(full), "Seal").value == "Unsealed"
    end

    @testset "Gas tank pressure and stored mass" begin
        tank = RocketPlumber.TriGasTank
        items = get_inspection_items(tank)
        pressure = inspection_item(items, "Pressure")
        @test pressure isa InspectionGauge
        @test pressure.colour == get_fluid_colour(get_stored_fluid(tank))
        @test (pressure.value, pressure.maximum, pressure.units) == (40.0, tank.tank.tank.max_voltage, "bar")
        @test (inspection_item(items, "Stored mass").value, inspection_item(items, "Stored mass").units) == (40.0, "kg")
        @test inspection_item(items, "Fluid").value == HexFluids.COLD_GAS
        @test !any(item -> hasproperty(item, :label) && item.label == "Contents", items)
        changed = @set tank.tank.tank.state.charge = 20.0
        @test inspection_item(get_inspection_items(changed), "Pressure").value == 20.0
        @test inspection_item(get_inspection_items(changed), "Stored mass").value == 20.0
        sealed, _ = do_action(tank, :seal_tank)
        @test inspection_item(get_inspection_items(sealed), "Seal").value == "Sealed"
        @test inspection_item(items, "Seal").value == "Unsealed"
    end

    @testset "Pressure-fed liquid contents, feed pressure and separate masses" begin
        tank = RocketPlumber.PressureFedLiquidTank
        tank = @set tank.tank.gas_state.charge = 4.0
        items = get_inspection_items(tank)
        contents = inspection_item(items, "Contents")
        @test contents isa InspectionGauge
        @test (contents.value, contents.maximum, contents.units) == (150.0, 200.0, "L")
        pressure = inspection_item(items, "Feed pressure")
        @test pressure isa InspectionValue
        @test pressure.units == "bar"
        @test pressure.value == first(produce_rel_elements(tank.tank)).value
        @test pressure.value > HexFlowTankComponents.compute_gas_pressure(tank.tank)
        @test count(item -> item isa InspectionGauge, items) == 1
        @test !any(item -> item.units == "A·s", filter(item -> item isa Union{InspectionValue, InspectionGauge}, items))
        @test inspection_item(items, "Liquid").value == get_stored_fluid(tank)
        @test inspection_item(items, "Pressurant").value == tank.gas_fluid
        @test (inspection_item(items, "Stored liquid mass").value, inspection_item(items, "Stored liquid mass").units) == (150.0, "kg")
        @test (inspection_item(items, "Pressurant mass").value, inspection_item(items, "Pressurant mass").units) == (4.0, "kg")
        @test inspection_item(items, "Liquid seal").value == "Unsealed"
        @test inspection_item(items, "Gas seal").value == "Unsealed"
        sealed, _ = do_action(tank, :seal_both)
        @test inspection_item(get_inspection_items(sealed), "Liquid seal").value == "Sealed"
        @test inspection_item(get_inspection_items(sealed), "Gas seal").value == "Sealed"
        limited = @set tank.tank.gas_state.charge = 100.0
        @test any(item -> item isa InspectionAlert && item.message == "Pressurant pressure limit reached" && item.tone == INSPECTION_WARNING, get_inspection_items(limited))
        negative = @set tank.tank.gas_state.charge = -2.0
        @test inspection_item(get_inspection_items(negative), "Pressurant mass").value == 0.0
        empty_liquid = @set tank.tank.liquid_state.charge = 0.0
        empty_liquid = @set empty_liquid.tank.stored_liquid = StoredFluidState(nothing)
        @test inspection_item(get_inspection_items(empty_liquid), "Stored liquid mass").value == 0.0
        @test inspection_item(get_inspection_items(empty_liquid), "Pressurant mass").value == 4.0
    end

    @testset "Required keywords and incomplete solver state" begin
        nozzle = RocketPlumber.TinyNozzle
        required = (tile = tile, rotation = HexFrame.S_NEG, mna_state = mna, derivedmapstate = derived)
        for behaviour in (nozzle, nozzle.nozzle, RocketPlumber.SwitchedTinyNozzle)
            for key in keys(required)
                supplied = (; (name => value for (name, value) in pairs(required) if name != key)...)
                @test_throws UndefKeywordError get_inspection_items(behaviour; supplied...)
            end
        end
        for behaviour in (RocketPlumber.TurboPump, RocketPlumber.ElecTransferPump, RocketPlumber.BasicBipropChamber, RocketPlumber.BasicDecompChamber)
            @test_throws UndefKeywordError get_inspection_items(behaviour; tile)
            @test_throws UndefKeywordError get_inspection_items(behaviour; mna_state = mna)
            @test !isempty(get_inspection_items(behaviour; tile, rotation = HexFrame.Q_POS, mna_state = mna))
        end

        coord = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))
        pipe_required = (position = coord, mna_state = mna, derivedmapstate = derived)
        for key in keys(pipe_required)
            supplied = (; (name => value for (name, value) in pairs(pipe_required) if name != key)...)
            @test_throws UndefKeywordError get_inspection_items(BigPipeBehav(); supplied...)
        end
        @test isnothing(inspection_item(get_inspection_items(BigPipeBehav(); pipe_required...), "Pressure drop").value)
        @test_throws TypeError get_inspection_items(RocketPlumber.TurboPump; tile, rotation = HexFrame.Q_POS, mna_state = nothing)

        # A pruned flow path is zero; its missing pressure is still unavailable
        pump = RocketPlumber.ElecTransferPump
        pump = @set pump.switch.switch.state.current_conductance = pump.switch.switch.max_conductance
        items = get_inspection_items(pump; tile, rotation = HexFrame.Q_POS, mna_state = mna)
        @test inspection_item(items, "Energy") isa InspectionGauge
        @test inspection_item(items, "Pump flow").value == 0.0
        @test isnothing(inspection_item(items, "Pressure rise").value)
        source = first(produce_abs_elements(PlacedComponent(pump, HexFrame.Q_POS, :primary), tile))
        mna.vsources[source.id] = source
        mna.vsource_currents[source.id] = 0.0
        items = get_inspection_items(pump; tile, rotation = HexFrame.Q_POS, mna_state = mna)
        @test inspection_item(items, "Pump flow").value == 0.0
        @test isnothing(inspection_item(items, "Pressure rise").value)
        empty!(mna.vsources)
        empty!(mna.vsource_currents)

        # Partial inlet results must not trigger the physics helper's invalid-fluid error
        element = first(produce_abs_elements(PlacedComponent(nozzle, required.rotation, :primary), tile))
        mna.resistors[element.id] = element
        inlet = map_element(nozzle.nozzle.connected_node, tile, required.rotation)
        @test isnothing(inspection_item(get_inspection_items(nozzle; required...), "Thrust").value)
        mna.node_voltages[inlet] = 10.0
        @test isnothing(inspection_item(get_inspection_items(nozzle; required...), "Thrust").value)
        derived.nodeactualfluids[inlet] = HexFluids.COLD_GAS
        @test isnothing(inspection_item(get_inspection_items(nozzle; required...), "Thrust").value)
        derived.node_temperatures[inlet] = 300.0
        @test inspection_item(get_inspection_items(nozzle; required...), "Thrust").value > 0.0
        derived.nodeactualfluids[inlet] = HexFluids.MONOPROP_LIQUID # No exhaust properties
        @test isnothing(inspection_item(get_inspection_items(nozzle; required...), "Thrust").value)
        empty!(mna.resistors)
        empty!(mna.node_voltages)
        empty!(derived.nodeactualfluids)
        empty!(derived.node_temperatures)
    end

    @testset "Derived readings use solved identities and placed orientation" begin
        placed = PlacedComponent(RocketPlumber.BasicBipropChamber, HexFrame.R_POS, true, :primary)
        fuel, oxidiser = produce_abs_elements(placed, tile)[1:2]
        mna.vsources[fuel.id] = fuel
        mna.vsources[oxidiser.id] = oxidiser
        mna.vsource_currents[fuel.id] = 2.0
        mna.vsource_currents[oxidiser.id] = 5.0
        items = get_inspection_items(placed; derivedmapstate = derived, mna_state = mna, tile)
        @test inspection_item(items, "Propellant flow").value == 35.0
        @test inspection_item(items, "Propellant flow").units == "L/s"
        @test solved_element_current(mna, fuel.id) == 2.0
        @test solved_element_current(mna, oxidiser.id) == 5.0
        @test inspection_item(items, "Oxidiser / fuel").value == 2.5
        empty!(mna.vsources)
        @test isnothing(solved_element_current(mna, fuel.id)) # Stale MNA entry must not leak through pruning
        @test inspection_item(get_inspection_items(placed; derivedmapstate = derived, mna_state = mna, tile), "Propellant flow").value == 0.0

        nozzle = PlacedComponent(RocketPlumber.TinyNozzle, HexFrame.S_NEG, :primary)
        element = first(produce_abs_elements(nozzle, tile))
        mna.resistors[element.id] = element
        inlet = map_element(nozzle.component.nozzle.connected_node, tile, nozzle.rotation)
        derived.nodeactualfluids[inlet] = HexFluids.COLD_GAS
        derived.node_temperatures[inlet] = 300.0
        mna.node_voltages[inlet] = 10.0
        live = MNA_State()
        live.resistors[element.id] = element
        live.node_voltages[inlet] = 10.0
        expected = norm(get_thrust(nozzle; tile, mna_state = live, derivedmapstate = derived))
        @test inspection_item(get_inspection_items(nozzle; derivedmapstate = derived, mna_state = mna, tile), "Thrust").value ≈ expected
        @test expected > 0.0
        @test mna.node_voltages[inlet] == 10.0

        # Pruning the nozzle must yield zero thrust even while its inlet remains solved
        delete!(mna.resistors, element.id)
        items = get_inspection_items(nozzle; derivedmapstate = derived, mna_state = mna, tile)
        @test inspection_item(items, "Thrust").value == 0.0
        @test inspection_item(items, "Inlet pressure").value == 10.0
        @test inspection_item(items, "Nozzle temp") isa InspectionGauge

        for fragment in (deactivate(nozzle.component.nozzle), damage(nozzle.component.nozzle))
            @test !only(produce_rel_elements(fragment)).active
            items = get_inspection_items(fragment; derivedmapstate = derived, mna_state = mna, tile, rotation = nozzle.rotation)
            @test inspection_item(items, "Thrust").value == 0.0
            @test inspection_item(items, "Flow rate").value == 0.0
            @test inspection_item(items, "Nozzle temp") isa InspectionGauge

            # A retained solved element must still respect the physics helper's state guard
            mna.resistors[element.id] = element
            items = get_inspection_items(fragment; derivedmapstate = derived, mna_state = mna, tile, rotation = nozzle.rotation)
            @test inspection_item(items, "Thrust").value == 0.0
            delete!(mna.resistors, element.id)
        end

        # A surviving zero-flow nozzle needs no fluid or thermal state for zero thrust
        empty!(derived.nodeactualfluids)
        empty!(derived.node_temperatures)
        mna.resistors[element.id] = element
        mna.node_voltages[inlet] = 0.0
        @test solved_element_current(mna, element.id) === 0.0
        @test inspection_item(get_inspection_items(nozzle; derivedmapstate = derived, mna_state = mna, tile), "Thrust").value == 0.0
        delete!(mna.resistors, element.id)
        @test isnothing(solved_element_current(mna, element.id))
        @test inspection_item(get_inspection_items(nozzle; derivedmapstate = derived, mna_state = mna, tile), "Thrust").value == 0.0

        coord = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))
        pipe = PlacedPipe(BigPipeBehav(), :primary)
        element = only(produce_abs_elements(pipe, coord))
        mna.resistors[element.id] = element
        mna.node_voltages[element.connections.v1] = 4.0
        mna.node_voltages[element.connections.v2] = 1.0
        derived.nodeactualfluids[element.connections.v1] = HexFluids.MONOPROP_LIQUID
        derived.nodeactualfluids[element.connections.v2] = HexFluids.MONOPROP_LIQUID
        changed = set_pipe_tunables(pipe, (99.0,))
        items = get_inspection_items(changed; derivedmapstate = derived, mna_state = mna, position = coord)
        @test inspection_item(items, "Flow rate").value == 150.0 # Use solved conductance, not 99
        @test inspection_item(items, "Flow rate").units == "L/s"
        @test solved_element_current(mna, element.id) == 30.0
        @test inspection_item(items, "Fluid").value == HexFluids.MONOPROP_LIQUID
        @test inspection_item(items, "Pressure drop").value == 3.0
        @test inspection_item(items, "Pressure drop").units == "bar"
        mna.node_voltages[element.connections.v2] = 7.0
        @test inspection_item(get_inspection_items(changed; derivedmapstate = derived, mna_state = mna, position = coord), "Flow rate").value == 150.0
        mna.node_voltages[element.connections.v2] = 4.0
        @test inspection_item(get_inspection_items(changed; derivedmapstate = derived, mna_state = mna, position = coord), "Flow rate").value === 0.0
        delete!(mna.node_voltages, element.connections.v2)
        @test isnothing(inspection_item(get_inspection_items(changed; derivedmapstate = derived, mna_state = mna, position = coord), "Flow rate").value)
    end

    @testset "Pipe family magnitudes and ambiguous fluids" begin
        coord = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG))
        for pipe in (ScrapPipeBehav(), BigPipeBehav())
            placed = PlacedPipe(pipe, :primary)
            element = only(produce_abs_elements(placed, coord))
            solved, fluids = MNA_StateSnapshot(), DerivedMapState()
            solved.resistors[element.id] = element
            solved.node_voltages[element.connections.v1] = 1.0
            solved.node_voltages[element.connections.v2] = 4.0
            fluids.nodeactualfluids[element.connections.v1] = HexFluids.FUEL_LIQUID
            fluids.nodeactualfluids[element.connections.v2] = HexFluids.OXIDISER_LIQUID
            readings() = get_inspection_items(placed; position = coord, mna_state = solved, derivedmapstate = fluids)
            @test Tuple(item.label for item in readings()) == ("Operation", "Flow rate", "Pressure drop", "Fluid")
            @test inspection_item(readings(), "Flow rate").value ≈ abs(solved_element_current(solved, element.id)) * 5
            @test inspection_item(readings(), "Pressure drop").value == 3.0
            @test isnothing(inspection_item(readings(), "Fluid").value)
            empty!(solved.resistors)
            @test inspection_item(readings(), "Flow rate").value == 0.0
            delete!(solved.node_voltages, element.connections.v1)
            @test isnothing(inspection_item(readings(), "Pressure drop").value)
        end
    end

    @testset "Pump and decomposition chamber solved flows" begin
        for comp in (RocketPlumber.ElecTransferPump, RocketPlumber.ElecTurboPump, RocketPlumber.TurboPump)
            placed = PlacedComponent(comp, HexFrame.R_POS, true, :primary)
            source = first(produce_abs_elements(placed, tile))
            solved = MNA_StateSnapshot()
            solved.vsources[source.id] = source
            inlet = map_element(HexFrame.NODE_Q_POS, tile, placed.rotation, placed.mirrored)
            outlet = map_element(HexFrame.NODE_Q_NEG, tile, placed.rotation, placed.mirrored)
            solved.node_voltages[inlet] = 3.0
            solved.node_voltages[outlet] = 11.0
            for current in (-2.0, 0.0, 2.0)
                solved.vsource_currents[source.id] = current
                items = get_inspection_items(placed; tile, mna_state = solved)
                @test (inspection_item(items, "Pump flow").value, inspection_item(items, "Pump flow").units) == (-current * 5.0, "L/s")
                @test (inspection_item(items, "Pressure rise").value, inspection_item(items, "Pressure rise").units) == (8.0, "bar")
                @test solved_element_current(solved, source.id) == current
            end
            solved.node_voltages[outlet] = 1.0
            @test inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Pressure rise").value == -2.0
            delete!(solved.node_voltages, inlet)
            @test isnothing(inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Pressure rise").value)
            empty!(solved.vsource_currents)
            @test isnothing(inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Pump flow").value)
            solved.vsource_currents[source.id] = -2.0
            empty!(solved.vsources)
            @test inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Pump flow").value == 0.0
        end

        chamber = PlacedComponent(RocketPlumber.BasicDecompChamber, HexFrame.R_NEG, :primary)
        source = first(produce_abs_elements(chamber, tile))
        solved = MNA_StateSnapshot()
        solved.vsources[source.id] = source
        for current in (2.0, 0.0, -2.0)
            solved.vsource_currents[source.id] = current
            items = get_inspection_items(chamber; tile, mna_state = solved)
            @test (inspection_item(items, "Propellant flow").value, inspection_item(items, "Propellant flow").units) == (current * 5.0, "L/s")
            temperature = inspection_item(items, "Output temp")
            @test temperature isa InspectionValue
            @test (temperature.value, temperature.units) == (chamber.component.output_temperature, "K")
            @test solved_element_current(solved, source.id) == current
        end
        empty!(solved.vsources)
        @test inspection_item(get_inspection_items(chamber; tile, mna_state = solved), "Propellant flow").value == 0.0
    end

    @testset "Family ordering, controls and condition sections" begin
        labels(items) = Tuple(item.label for item in items if hasproperty(item, :label))
        readouts(comp) = get_inspection_items(PlacedComponent(comp, HexFrame.R_NEG, true, :primary); tile, mna_state = mna, derivedmapstate = derived)
        items = readouts(RocketPlumber.SmallNozzle)
        @test labels(items) == ("Operation", "Thrust", "Flow rate", "Inlet pressure", "Condition", "Nozzle temp")
        @test first(items) isa InspectionDivider
        @test inspection_item(items, "Condition") isa InspectionDivider
        temperature = inspection_item(items, "Nozzle temp")
        @test temperature isa InspectionGauge
        overheat = RocketPlumber.SmallNozzle.nozzle.overheat
        @test (temperature.value, temperature.minimum, temperature.maximum, temperature.units, temperature.colour) ==
            (get_component_temperature(overheat), 0.0, get_overheat_limit_temperature(overheat), "K", get_overheat_tint(overheat))
        @test first(get_inspection_items(overheat)).label == "Temperature"
        @test inspection_item(items, "Thrust").value == 0.0
        @test inspection_item(items, "Flow rate").value == 0.0
        @test isnothing(inspection_item(items, "Inlet pressure").value)
        @test !any(item -> item isa InspectionStatus, items)
        switched, _ = do_action(RocketPlumber.SwitchedTinyNozzle, :open_valve)
        @test labels(readouts(switched)) == ("Operation", "Thrust", "Flow rate", "Inlet pressure", "Opening", "Condition", "Nozzle temp")
        opening = inspection_item(readouts(switched), "Opening")
        @test opening.target == 100.0
        @test opening.value == 100get_switch_percentage(RocketPlumber.SwitchedTinyNozzle.switch)
        @test opening.value != opening.target
        for valve in (RocketPlumber.LargeAdjValve, RocketPlumber.LargeOnOffValve)
            @test labels(readouts(valve)) == ("Operation", "Flow rate", "Opening")
            for key in (:tile, :mna_state)
                supplied = key == :tile ? (mna_state = mna,) : (tile = tile,)
                @test_throws UndefKeywordError get_inspection_items(valve; supplied...)
            end
            placed = PlacedComponent(valve, HexFrame.S_POS, true, :primary)
            element = only(produce_abs_elements(placed, tile))
            solved = MNA_StateSnapshot()
            solved.resistors[element.id] = element
            solved.node_voltages[element.connections.v1] = 2.0
            solved.node_voltages[element.connections.v2] = 5.0
            items = get_inspection_items(placed; tile, mna_state = solved)
            @test inspection_item(items, "Flow rate").value ≈ abs(solved_element_current(solved, element.id)) * 5
            delete!(solved.node_voltages, element.connections.v2)
            @test isnothing(inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Flow rate").value)
            empty!(solved.resistors)
            @test inspection_item(get_inspection_items(placed; tile, mna_state = solved), "Flow rate").value == 0.0
        end
        for pump in (RocketPlumber.ElecTurboPump, RocketPlumber.ElecTransferPump)
            @test labels(readouts(pump)) == ("Operation", "Pump flow", "Pressure rise", "Pump setting", "Energy")
            commanded, _ = do_action(pump, :pump_on)
            setting = inspection_item(readouts(commanded), "Pump setting")
            @test setting.target == 100.0
            @test setting.value == inspection_item(readouts(pump), "Pump setting").value
            @test setting.value != setting.target
            depleted = @set pump.energy.state.stored_energy = 0.0
            @test labels(readouts(depleted)) == ("Operation", "Pump flow", "Pressure rise", "Pump setting", "Energy", "Condition")
            @test last(readouts(depleted)).tone == INSPECTION_WARNING
        end
        turbo = RocketPlumber.TurboPump
        turbo = @set turbo.rotor.state.rpm = 1.1 * turbo.rotor.max_rpm
        turbo = @set turbo.overheat = damage(turbo.overheat)
        items = readouts(turbo)
        @test labels(items) == ("Operation", "Pump flow", "Pressure rise", "Rotor speed", "Condition", "Turbine temp")
        @test first(items) isa InspectionDivider
        @test inspection_item(items, "Condition") isa InspectionDivider
        temperature = inspection_item(items, "Turbine temp")
        @test temperature isa InspectionGauge
        @test (temperature.value, temperature.minimum, temperature.maximum, temperature.units) ==
            (get_component_temperature(turbo), 0.0, get_overheat_limit_temperature(turbo.overheat), "K")
        @test Tuple(item.tone for item in items if item isa InspectionAlert) == (INSPECTION_WARNING, INSPECTION_ERROR)
        @test inspection_item(items, "Rotor speed").value > inspection_item(items, "Rotor speed").maximum
        @test labels(readouts(RocketPlumber.BasicDecompChamber)) == ("Operation", "Propellant flow", "Output temp")
        for tank in (RocketPlumber.TriLiquidTank, RocketPlumber.TriFuelTank, RocketPlumber.TriOxidiserTank)
            @test labels(readouts(tank)) == ("Operation", "Fluid", "Contents", "Stored mass", "Seal")
        end
        @test labels(readouts(RocketPlumber.TriGasTank)) == ("Operation", "Fluid", "Pressure", "Stored mass", "Seal")
        @test labels(readouts(RocketPlumber.PressureFedLiquidTank)) == ("Operation", "Liquid", "Contents", "Stored liquid mass", "Feed pressure", "Pressurant", "Pressurant mass", "Liquid seal", "Gas seal")
        tank = RocketPlumber.PressureFedLiquidTank
        # Gas pressure is linear in charge at fixed headspace; exercise the exact boundary
        tank = @set tank.tank.gas_state.charge = 1.0
        charge_at_limit = tank.tank.gas_state.charge * tank.tank.max_gas_pressure / HexFlowTankComponents.compute_gas_pressure(tank.tank)
        for multiplier in (1.0, 1.1), sealed in (false, true)
            limited = @set tank.tank.gas_state.charge = charge_at_limit * multiplier
            if sealed
                limited, _ = do_action(limited, :seal_both)
            end
            items = readouts(limited)
            @test last(items) isa InspectionAlert
            @test last(items).tone == INSPECTION_WARNING
            @test items[end - 1] isa InspectionDivider
            @test count(item -> item isa InspectionDivider, items) == 2
            @test items[end - 1].label == "Condition"
        end
    end

    @testset "Combustion forward volumetric inputs and unavailable results" begin
        comp = PlacedComponent(RocketPlumber.BasicBipropChamber, HexFrame.S_NEG, true, :primary)
        fuel, oxidiser = produce_abs_elements(comp, tile)[1:2]
        solved = MNA_StateSnapshot()
        solved.vsources[fuel.id], solved.vsources[oxidiser.id] = fuel, oxidiser
        readings() = get_inspection_items(comp; tile, mna_state = solved)
        items = readings()
        @test Tuple(item.label for item in items) == ("Operation", "Output temp", "Propellant flow", "Oxidiser / fuel", "Target ratio")
        @test inspection_item(items, "Output temp").maximum == lookup_fluid_reference_temperature(HexFluids.BIPROP_EXHAUST)
        @test inspection_item(items, "Target ratio").value == comp.component.r_optimal
        @test isnothing(inspection_item(items, "Propellant flow").value)
        for (fuel_flow, oxidiser_flow, total, ratio) in ((2.0, 5.0, 35.0, 2.5), (2.0, -5.0, 10.0, 0.0), (0.0, 5.0, 25.0, nothing), (-2.0, -5.0, 0.0, nothing))
            solved.vsource_currents[fuel.id], solved.vsource_currents[oxidiser.id] = fuel_flow, oxidiser_flow
            @test inspection_item(readings(), "Propellant flow").value == total
            @test inspection_item(readings(), "Oxidiser / fuel").value === ratio
        end
        reference = lookup_fluid_reference_temperature(HexFluids.BIPROP_EXHAUST)
        try
            for invalid in (0.0, NaN, Inf)
                set_fluid_reference_temperature!(HexFluids.BIPROP_EXHAUST, invalid)
                @test inspection_item(readings(), "Output temp") isa InspectionValue
            end
        finally
            set_fluid_reference_temperature!(HexFluids.BIPROP_EXHAUST, reference)
        end
        delete!(solved.vsource_currents, fuel.id)
        @test isnothing(inspection_item(readings(), "Propellant flow").value)
        @test isnothing(inspection_item(readings(), "Oxidiser / fuel").value)
    end

    @testset "Gauge fill preserves actual out-of-range readings" begin
        over = InspectionGauge("Speed", 120.0, 100.0)
        @test RocketPlumber.inspection_fraction(over) == 1.0f0
        @test over.value == 120.0
        for (target, expected) in ((-20.0, 0.0f0), (40.0, 0.4f0), (80.0, 0.8f0), (120.0, 1.0f0))
            gauge = InspectionGauge("Opening", 40, 100; target)
            @test RocketPlumber.inspection_fraction(gauge, gauge.target) == expected
            @test gauge.target == target
            @test gauge.value == 40.0
        end
        @test RocketPlumber.inspection_fraction(InspectionGauge("Empty", -5.0, 100.0)) == 0.0f0
        @test RocketPlumber.inspection_fraction(InspectionGauge("No capacity", 1.0, 0.0)) == 0.0f0
        @test RocketPlumber.inspection_fraction(InspectionGauge("Unknown", NaN, 100.0)) == 0.0f0
    end

    @testset "Whole percentages and stable target text" begin
        for (value, expected) in ((0.0, "0%"), (0.4, "0%"), (1.0, "1%"), (1.15, "1%"), (9.8, "10%"), (10.5, "11%"), (99.5, "100%"), (100.0, "100%"), (-0.0, "0%"), (-0.4, "0%"))
            @test RocketPlumber.inspection_measurement(value, "%") == expected
            gauge = InspectionGauge("Opening", value, 100; target = value, units = "%")
            @test RocketPlumber.inspection_gauge_reading(gauge) == "$(lpad(expected, 4)) (target $expected)"
        end
        for (target, expected) in ((-10, 20), (0, 20), (50, 70), (100, 120), (110, 120))
            gauge = InspectionGauge("Opening", 1.15, 100; target, units = "%")
            @test RocketPlumber.inspection_target_position(gauge, 20, 120) == expected
            @test RocketPlumber.inspection_fraction(gauge) ≈ 0.0115f0
        end
    end

    @testset "Measurement formatting" begin
        for (value, units, expected) in (
                (764.4, "K", "764 K"), (1860.4, "rpm", "1860 rpm"),
                (12487.6, "N", "12488 N"), (100000.4, "EU", "100000 EU"),
                (13.64, "L/s", "13.6 L/s"), (1250.0, "L", "1250 L"), (123456.0, "kg", "123000 kg"),
                (0.01234, "L/s", "0.0123 L/s"), (2.345, "", "2.35"),
                (1.2, "", "1.2"), (-13.64, "L/s", "-13.6 L/s"),
                (0.0, "bar", "0 bar"), (-0.0, "K", "0 K"),
                (1.0e-6, "bar", "0.000001 bar"), (1.234e-6, "N", "0.00000123 N"),
                (prevfloat(1.0e-6), "bar", "1e-06 bar"), (1.234e-7, "K", "1.23e-07 K"),
                (1.0e7, "EU", "1e+07 EU"), (floatmax(Float64), "", "1.8e+308"),
                (nextfloat(0.0), "", "4.94e-324"), (9876543.2, "N", "9876543 N"),
                (NaN, "bar", "--"), (Inf, "K", "--"), (-Inf, "", "--"),
                (nothing, "L/s", "--"),
            )
            @test RocketPlumber.inspection_measurement(value, units) == expected
        end
        for (gauge, expected) in (
                (InspectionGauge("Energy", 100000.4, 150000; units = "EU"), "100000 / 150000 EU"),
                (InspectionGauge("Flow", 13.64, 100; units = "L/s", target = 28.24), "13.6 L/s (target 28.2 L/s)"),
                (InspectionGauge("Speed", 1860.4, 3000; units = "rpm", target = 2300.2), "1860 rpm (target 2300 rpm)"),
                (InspectionGauge("Unknown", NaN, 100; units = "bar", target = Inf), "-- (target --)"),
            )
            @test RocketPlumber.inspection_gauge_reading(gauge) == expected
        end
    end

    @testset "Junction core readings" begin
        coord = VertexCoord(tile, HexFrame.Q_POS)
        node = to_nodecoord(coord)
        junction_derived, junction_mna = DerivedMapState(), MNA_StateSnapshot()
        readings() = RocketPlumber.junction_inspection_items(coord, junction_derived, junction_mna)
        @test first(readings()) == InspectionDivider("Operation")
        missing = readings()
        @test map(item -> item.label, missing) == ("Operation", "Fluid", "Pressure", "Temperature")
        @test all(item -> isnothing(item.value), missing[2:end])
        for item in missing[3:4]
            @test RocketPlumber.inspection_measurement(item.value, item.units) == "--"
        end

        junction_derived.nodeactualfluids[node] = HexFluids.MONOPROP_LIQUID
        junction_derived.node_temperatures[node] = 764.4
        junction_mna.node_voltages[node] = 28.24
        available = readings()
        @test available[2].value == HexFluids.MONOPROP_LIQUID
        @test RocketPlumber.inspection_measurement(available[3].value, available[3].units) == "28.2 bar"
        @test RocketPlumber.inspection_measurement(available[4].value, available[4].units) == "764 K"
        junction_mna.node_voltages[node] = 0.0
        @test readings()[3].value === 0.0
        empty!(junction_derived.node_temperatures)
        @test isnothing(readings()[4].value)
        @test readings()[2].value == HexFluids.MONOPROP_LIQUID
    end
end

@testset "Permanent Properties visibility" begin
    inputstate = InputState()
    gamemap = GameMap()
    tile, other = TileCoord(0, 0), TileCoord(3, 0)
    pipe = first(get_pipe_segments(VertexCoord(tile, HexFrame.Q_POS)))
    for coord in (tile, other)
        set_component!(gamemap, coord, PlacedComponent(RocketPlumber.TriGasTank, HexFrame.Q_POS, :primary))
    end
    set_pipe!(gamemap, pipe, BigPipeBehav())

    function cursor!(coord)
        inputstate.cursor_x, inputstate.cursor_y = to_cartesian(coord)
        return nothing
    end
    content(; kwargs...) = RocketPlumber.property_panel_content(inputstate, gamemap; kwargs...)
    @test content() == (visibility = :idle, target = nothing)
    cursor!(TileCoord(90, 90))
    @test content().visibility == :idle # Empty tile
    cursor!(VertexCoord(TileCoord(90, 90), HexFrame.Q_POS))
    @test content().visibility == :idle # Empty geometric vertex
    cursor!(tile)
    @test content() == (visibility = :preview, target = tile)
    cursor!(TileCoord(90, 90))
    @test content().visibility == :idle # Moving away returns to idle immediately
    cursor!(other)
    @test content() == (visibility = :preview, target = other)
    @test content(; world_hover_allowed = false).visibility == :idle

    select_single_component!(inputstate, tile)
    @test content() == (visibility = :interactive, target = tile) # Selection overrides another hovered part
    @test content(; world_hover_allowed = false).target == tile
    select_single_pipe!(inputstate, pipe)
    @test content() == (visibility = :interactive, target = pipe)
    select_elements!(inputstate, Set((tile, other)), Set((pipe,)))
    @test content() == (visibility = :interactive, target = nothing)
    clear_selection!(inputstate)
    @test content() == (visibility = :preview, target = other)
    delete_component!(gamemap, other)
    @test content().visibility == :idle
    select_single_component!(inputstate, other)
    @test content() == (visibility = :interactive, target = nothing) # No stale selected readout
    select_single_pipe!(inputstate, pipe)
    delete_pipe!(gamemap, pipe)
    @test content() == (visibility = :interactive, target = nothing)
    clear_selection!(inputstate)
    cursor!(tile)

    inputstate.dev_utils_menu_active = true
    @test content() == (visibility = :preview, target = tile) # Developer Utilities does not suppress Properties
    inputstate.placement_state = PlacementTileState(; pendingcomponent = RocketPlumber.TriGasTank)
    @test content() == (visibility = :interactive, target = nothing)
    @test inputstate.dev_utils_menu_active
    for field in (:ui_hidden, :spacemap_active)
        setfield!(inputstate, field, true)
        @test content().visibility == :hidden # Global visibility overrides placement
        setfield!(inputstate, field, false)
    end
    inputstate.placement_state = PlacementReadyState()
    @test content().visibility == :preview

    # Every supported span is inspected along its body and at its endpoint without solved data.
    for span in get_pipe_segments(VertexCoord(TileCoord(10, 0), HexFrame.Q_POS))
        set_pipe!(gamemap, span, BigPipeBehav())
        inputstate.cursor_x, inputstate.cursor_y = (to_cartesian(span.v1) + to_cartesian(span.v2)) / 2
        @test content() == (visibility = :preview, target = span)
        cursor!(span.v1)
        @test content() == (visibility = :preview, target = span.v1)
        delete_pipe!(gamemap, span)
        @test !RocketPlumber.valid_property_target(span.v1, gamemap)
    end
    junction = VertexCoord(TileCoord(20, 0), HexFrame.Q_POS)
    set_surface_tile!(gamemap, TileCoord(20, 0))
    cursor!(junction)
    @test content() == (visibility = :preview, target = junction)

end
