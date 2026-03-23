using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using HexFlowSwitchComponents

using HexElements: CONST_RESISTOR

const HORIZONTAL_CONNECTION = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG)
const INTERNAL_CONNECTION = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_INTERNAL)

"Create a SwitchBehavFrag with sensible defaults for testing."
function make_switch(;
        connection = HORIZONTAL_CONNECTION,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0),
        target_conductance = min_conductance,
        current_conductance = min_conductance
    )
    return SwitchBehavFrag(;
        connection, max_conductance, min_conductance,
        growth_factor,
        target_conductance, current_conductance
    )
end

"Create a BoolSwitchBehavFrag with testing defaults."
function make_bool_switch(;
        connection = HORIZONTAL_CONNECTION,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0),
        target_conductance = min_conductance,
        current_conductance = min_conductance
    )
    return BoolSwitchBehavFrag(;
        connection, max_conductance, min_conductance,
        growth_factor, target_conductance, current_conductance
    )
end

"Create a SteppedSwitchBehavFrag with testing defaults."
function make_stepped_switch(;
        connection = HORIZONTAL_CONNECTION,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0),
        percentage_step_size = 0.05,
        target_conductance = min_conductance,
        current_conductance = min_conductance
    )
    return SteppedSwitchBehavFrag(;
        connection, max_conductance, min_conductance,
        growth_factor, percentage_step_size,
        target_conductance, current_conductance
    )
end

# ===============================================================
# SwitchBehavFrag core
# ===============================================================

@testset "SwitchBehavFrag core" begin
    @testset "Element production" begin
        sw = make_switch(current_conductance = 1.5, target_conductance = 1.5)
        elements = produce_rel_elements(sw)

        @test length(elements) == 1
        @test elements[1].type === CONST_RESISTOR
        @test elements[1].connections == HORIZONTAL_CONNECTION
        @test elements[1].value ≈ 1.5
    end

    @testset "Constructor validation" begin
        # current_conductance out of bounds
        @test_throws ArgumentError make_switch(current_conductance = 3.0)
        @test_throws ArgumentError make_switch(current_conductance = -0.1)

        # target_conductance out of bounds
        @test_throws ArgumentError make_switch(target_conductance = 3.0)
        @test_throws ArgumentError make_switch(target_conductance = -0.1)

        # growth_factor too small — constructor clamps to minimum 1.0001
        sw_clamped = make_switch(growth_factor = 0.5)
        @test sw_clamped.growth_factor ≈ 1.0001
        sw_clamped2 = make_switch(growth_factor = 1.0)
        @test sw_clamped2.growth_factor ≈ 1.0001

        # Valid edge: growth_factor exactly at boundary passes through unchanged
        sw = make_switch(growth_factor = 1.0001)
        @test sw.growth_factor ≈ 1.0001
    end

    @testset "Tunables round-trip" begin
        sw = make_switch()
        tunables = get_tunables(sw)

        @test length(tunables) == 3
        @test tunables[1].current_val ≈ sw.max_conductance
        @test tunables[2].current_val ≈ sw.min_conductance
        @test tunables[3].current_val ≈ sw.growth_factor

        # Round-trip: set tunables from values and read back
        new_vals = (3.0, 0.0, 1.5)
        sw2 = set_tunables(sw, new_vals)
        @test sw2.max_conductance ≈ 3.0
        @test sw2.min_conductance ≈ 0.0
        @test sw2.growth_factor ≈ 1.5
    end

    @testset "update_flowbehav! — exponential convergence" begin
        # Increasing from zero → jumps to the global practical minimum
        sw = make_switch(target_conductance = 2.0)
        update_flowbehav!(sw)
        @test sw.state.current_conductance ≈ HexFlowSwitchComponents.MIN_PRACTICAL_CONDUCTANCE

        # Continue increasing → exponential growth, doesn't overshoot
        prev = sw.state.current_conductance
        update_flowbehav!(sw)
        @test sw.state.current_conductance > prev
        @test sw.state.current_conductance ≤ 2.0

        # Decreasing → exponential decay
        sw_dec = make_switch(
            target_conductance = 0.0,
            current_conductance = 1.5
        )
        update_flowbehav!(sw_dec)
        @test sw_dec.state.current_conductance < 1.5

        # Decreasing snaps to min when close
        sw_near_min = make_switch(
            target_conductance = 0.0,
            current_conductance = HexFlowSwitchComponents.MIN_PRACTICAL_CONDUCTANCE * 0.05
        )
        update_flowbehav!(sw_near_min)
        @test sw_near_min.state.current_conductance ≈ 0.0

        # Already at target → no change
        sw_at_target = make_switch(
            target_conductance = 1.0,
            current_conductance = 1.0
        )
        update_flowbehav!(sw_at_target)
        @test sw_at_target.state.current_conductance ≈ 1.0

        # max ≈ min → snaps to target immediately
        sw_narrow = make_switch(
            max_conductance = 1.0,
            min_conductance = 1.0,
            target_conductance = 1.0,
            current_conductance = 1.0
        )
        update_flowbehav!(sw_narrow)
        @test sw_narrow.state.current_conductance ≈ 1.0
    end
end

# ===============================================================
# Percentage helpers
# ===============================================================

@testset "Percentage helpers" begin
    gf = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0)

    @testset "conductance_to_exp_percentage" begin
        @test HexFlowSwitchComponents.conductance_to_exp_percentage(0.0, 0.0, 2.0, gf) ≈ 0.0
        @test HexFlowSwitchComponents.conductance_to_exp_percentage(2.0, 0.0, 2.0, gf) ≈ 1.0

        # Monotonically increasing
        p_low = HexFlowSwitchComponents.conductance_to_exp_percentage(0.5, 0.0, 2.0, gf)
        p_high = HexFlowSwitchComponents.conductance_to_exp_percentage(1.5, 0.0, 2.0, gf)
        @test 0.0 < p_low < p_high < 1.0
    end

    @testset "exp_percentage_to_conductance" begin
        @test HexFlowSwitchComponents.exp_percentage_to_conductance(0.0, 0.0, 2.0, gf) ≈ 0.0
        @test HexFlowSwitchComponents.exp_percentage_to_conductance(1.0, 0.0, 2.0, gf) ≈ 2.0
    end

    @testset "Round-trip percentage ↔ conductance" begin
        for c in [0.0, 0.3, 1.0, 1.7, 2.0]
            p = HexFlowSwitchComponents.conductance_to_exp_percentage(c, 0.0, 2.0, gf)
            c_back = HexFlowSwitchComponents.exp_percentage_to_conductance(p, 0.0, 2.0, gf)
            @test c_back ≈ c atol=1e-10
        end
    end

    @testset "get_switch_percentage / get_target_percentage" begin
        sw = make_switch(
            current_conductance = 1.0,
            target_conductance = 1.5
        )
        sp = get_switch_percentage(sw)
        tp = get_target_percentage(sw)
        @test 0.0 < sp < 1.0
        @test 0.0 < tp < 1.0
        @test tp > sp  # target > current → target percentage > switch percentage
    end
end

# ===============================================================
# BoolSwitchBehavFrag
# ===============================================================

@testset "BoolSwitchBehavFrag" begin
    @testset "Delegation" begin
        bsw = make_bool_switch(current_conductance = 1.0, target_conductance = 1.0)
        elements = produce_rel_elements(bsw)
        @test elements[1].type === CONST_RESISTOR
        @test elements[1].value ≈ 1.0

        @test get_switch_percentage(bsw) ≈ get_switch_percentage(bsw.switch)
        @test get_target_percentage(bsw) ≈ get_target_percentage(bsw.switch)

        tunables = get_tunables(bsw)
        @test length(tunables) == 3

        sw2 = set_tunables(bsw, (3.0, 0.0, 1.5))
        @test sw2.switch.max_conductance ≈ 3.0

        # update_flowbehav! delegates
        bsw_update = make_bool_switch(target_conductance = 2.0)
        update_flowbehav!(bsw_update)
        @test bsw_update.switch.state.current_conductance > 0.0
    end

    @testset "on_click! toggle" begin
        # At min → opens
        bsw = make_bool_switch()
        on_click!(bsw)
        @test bsw.switch.state.target_conductance ≈ 2.0

        # At max → closes
        bsw2 = make_bool_switch(target_conductance = 2.0, current_conductance = 2.0)
        on_click!(bsw2)
        @test bsw2.switch.state.target_conductance ≈ 0.0
    end

    @testset "get_actions / do_action!" begin
        bsw = make_bool_switch()
        actions = get_actions(bsw)
        @test length(actions) == 2

        action_ids = Set(a.id for a in actions)
        @test :open_valve ∈ action_ids
        @test :close_valve ∈ action_ids

        # At min: open is enabled, close is disabled
        open_action = first(a for a in actions if a.id === :open_valve)
        close_action = first(a for a in actions if a.id === :close_valve)
        @test open_action.enabled == true
        @test close_action.enabled == false

        # do_action! open
        success, msg = do_action!(bsw, :open_valve)
        @test success
        @test bsw.switch.state.target_conductance ≈ 2.0

        # do_action! close
        success, msg = do_action!(bsw, :close_valve)
        @test success
        @test bsw.switch.state.target_conductance ≈ 0.0
    end
end

# ===============================================================
# SteppedSwitchBehavFrag
# ===============================================================

@testset "SteppedSwitchBehavFrag" begin
    @testset "Delegation" begin
        ssw = make_stepped_switch(current_conductance = 1.0, target_conductance = 1.0)
        elements = produce_rel_elements(ssw)
        @test elements[1].type === CONST_RESISTOR
        @test elements[1].value ≈ 1.0

        update_flowbehav!(ssw)
        @test ssw.switch.state.current_conductance ≈ 1.0
    end

    @testset "Tunables" begin
        ssw = make_stepped_switch()
        tunables = get_tunables(ssw)
        @test length(tunables) == 4
        @test tunables[4].current_val ≈ 0.05  # percentage_step_size

        # Round-trip
        new_ssw = set_tunables(ssw, (3.0, 0.0, 1.5, 0.1))
        @test new_ssw.switch.max_conductance ≈ 3.0
        @test new_ssw.percentage_step_size ≈ 0.1
    end

    @testset "step_conductance_up! / step_conductance_down!" begin
        ssw = make_stepped_switch(percentage_step_size = 0.25)

        # Step up from zero
        step_conductance_up!(ssw)
        target_1 = ssw.switch.state.target_conductance
        @test target_1 > 0.0

        # Step up again
        step_conductance_up!(ssw)
        target_2 = ssw.switch.state.target_conductance
        @test target_2 > target_1

        # Step down
        step_conductance_down!(ssw)
        target_3 = ssw.switch.state.target_conductance
        @test target_3 < target_2
        @test target_3 ≈ target_1  # Should return to prev step

        # Clamped at max
        for _ in 1:20
            step_conductance_up!(ssw)
        end
        @test ssw.switch.state.target_conductance ≈ 2.0

        # Clamped at min
        for _ in 1:20
            step_conductance_down!(ssw)
        end
        @test ssw.switch.state.target_conductance ≈ 0.0
    end

    @testset "get_actions disabled at extremes" begin
        ssw_min = make_stepped_switch()
        actions_min = get_actions(ssw_min)
        close_action = first(a for a in actions_min if a.id === :step_valve_close)
        @test close_action.enabled == false

        ssw_max = make_stepped_switch(target_conductance = 2.0, current_conductance = 2.0)
        actions_max = get_actions(ssw_max)
        open_action = first(a for a in actions_max if a.id === :step_valve_open)
        @test open_action.enabled == false
    end

    @testset "do_action!" begin
        ssw = make_stepped_switch()
        success, _ = do_action!(ssw, :step_valve_open)
        @test success
        @test ssw.switch.state.target_conductance > 0.0

        success, _ = do_action!(ssw, :step_valve_close)
        @test success
        @test ssw.switch.state.target_conductance ≈ 0.0
    end
end

# ===============================================================
# StandardValveCompBehav -- Adjustable Large
# ===============================================================

@testset "StandardValveCompBehav{SteppedSwitchBehavFrag, LargeValve}" begin
    valve = StandardValveCompBehav(SteppedSwitchBehavFrag, LargeValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 1.25 / 60.0),
        percentage_step_size = 0.05
    )

    @testset "Element layout" begin
        elements = produce_rel_elements(valve)
        @test length(elements) == 1
        @test elements[1].type === CONST_RESISTOR
        @test elements[1].connections == HORIZONTAL_CONNECTION
    end

    @testset "Tunables round-trip" begin
        tunables = get_tunables(valve)
        @test length(tunables) == 4

        valve2 = set_tunables(valve, (3.0, 0.0, 1.5, 0.1))
        @test valve2.switch.switch.max_conductance ≈ 3.0
        @test valve2.switch.percentage_step_size ≈ 0.1
    end

    @testset "Fluid tags" begin
        tags = get_fluidtags(valve)
        @test tags.NODE_Q_POS === HexFluids.NONE
        @test tags.NODE_Q_NEG === HexFluids.NONE
    end

    @testset "on_click! dispatches step up/down" begin
        on_click!(valve; relative_clicksite = (y = 0.5,))
        @test valve.switch.switch.state.target_conductance > 0.0

        target_after_up = valve.switch.switch.state.target_conductance

        on_click!(valve; relative_clicksite = (y = -0.5,))
        @test valve.switch.switch.state.target_conductance < target_after_up

        # Click at zero -- no-op
        prev = valve.switch.switch.state.target_conductance
        on_click!(valve; relative_clicksite = (y = 0.0,))
        @test valve.switch.switch.state.target_conductance ≈ prev
    end

    @testset "update_flowbehav! convergence" begin
        v = StandardValveCompBehav(SteppedSwitchBehavFrag, LargeValve;
            max_conductance = 2.0,
            growth_factor = calculate_growth_factor(2.0, 0.0, 1.25 / 60.0),
            percentage_step_size = 0.05,
            target_conductance = 2.0
        )
        for _ in 1:500
            update_flowbehav!(v)
        end
        @test v.switch.switch.state.current_conductance ≈ 2.0
    end

    @testset "get_actions / do_action!" begin
        actions = get_actions(valve)
        @test length(actions) == 2
        action_ids = Set(a.id for a in actions)
        @test :step_valve_open ∈ action_ids
        @test :step_valve_close ∈ action_ids
    end

    @testset "Sprite trait dispatch" begin
        @test HexFlowSwitchComponents.fluidmask_sprite(valve) === :Valves_Large_fluidmask
        @test HexFlowSwitchComponents.valvebody_sprite(valve) === :Valves_Large_valvebody
        @test HexFlowSwitchComponents.static_sprite(valve) === :Valves_Large_static
        @test HexFlowSwitchComponents.controlbox_sprite(valve) === :Valves_Adjustable_controlbox
        @test HexFlowSwitchComponents.valve_travel_px(valve) == 100.0f0
    end
end

# ===============================================================
# StandardValveCompBehav -- Adjustable Tiny
# ===============================================================

@testset "StandardValveCompBehav{SteppedSwitchBehavFrag, TinyValve}" begin
    valve = StandardValveCompBehav(SteppedSwitchBehavFrag, TinyValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0),
        percentage_step_size = 0.05
    )

    @testset "Element layout" begin
        elements = produce_rel_elements(valve)
        @test length(elements) == 1
        @test elements[1].type === CONST_RESISTOR
    end

    @testset "Fluid tags" begin
        tags = get_fluidtags(valve)
        @test tags.NODE_Q_POS === HexFluids.NONE
        @test tags.NODE_Q_NEG === HexFluids.NONE
    end

    @testset "Sprite trait dispatch" begin
        @test HexFlowSwitchComponents.fluidmask_sprite(valve) === :Valves_Tiny_fluidmask
        @test HexFlowSwitchComponents.valvebody_sprite(valve) === :Valves_Tiny_valvebody
        @test HexFlowSwitchComponents.static_sprite(valve) === :Valves_Tiny_static
        @test HexFlowSwitchComponents.controlbox_sprite(valve) === :Valves_Adjustable_controlbox
        @test HexFlowSwitchComponents.valve_travel_px(valve) == 25.0f0
    end

    @testset "Tunables round-trip" begin
        tunables = get_tunables(valve)
        @test length(tunables) == 4

        valve2 = set_tunables(valve, (3.0, 0.0, 1.5, 0.1))
        @test valve2.switch.switch.max_conductance ≈ 3.0
    end
end

# ===============================================================
# StandardValveCompBehav -- On/Off Large
# ===============================================================

@testset "StandardValveCompBehav{BoolSwitchBehavFrag, LargeValve}" begin
    valve = StandardValveCompBehav(BoolSwitchBehavFrag, LargeValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0)
    )

    @testset "Element layout" begin
        elements = produce_rel_elements(valve)
        @test length(elements) == 1
        @test elements[1].type === CONST_RESISTOR
        @test elements[1].connections == HORIZONTAL_CONNECTION
    end

    @testset "Tunables round-trip" begin
        tunables = get_tunables(valve)
        @test length(tunables) == 3

        valve2 = set_tunables(valve, (3.0, 0.0, 1.5))
        @test valve2.switch.switch.max_conductance ≈ 3.0
    end

    @testset "Fluid tags" begin
        tags = get_fluidtags(valve)
        @test tags.NODE_Q_POS === HexFluids.NONE
        @test tags.NODE_Q_NEG === HexFluids.NONE
    end

    @testset "on_click! dispatches open/close" begin
        # Click above horizontal -- opens
        on_click!(valve; relative_clicksite = (y = 0.5,))
        @test valve.switch.switch.state.target_conductance ≈ 2.0

        # Click below horizontal -- closes
        on_click!(valve; relative_clicksite = (y = -0.5,))
        @test valve.switch.switch.state.target_conductance ≈ 0.0

        # Click at zero -- no-op
        on_click!(valve; relative_clicksite = (y = 0.5,))  # open first
        prev = valve.switch.switch.state.target_conductance
        on_click!(valve; relative_clicksite = (y = 0.0,))
        @test valve.switch.switch.state.target_conductance ≈ prev
    end

    @testset "get_actions / do_action!" begin
        do_action!(valve, :close_valve)
        actions = get_actions(valve)
        @test length(actions) == 2
        action_ids = Set(a.id for a in actions)
        @test :open_valve ∈ action_ids
        @test :close_valve ∈ action_ids
    end

    @testset "Sprite trait dispatch" begin
        @test HexFlowSwitchComponents.fluidmask_sprite(valve) === :Valves_Large_fluidmask
        @test HexFlowSwitchComponents.valvebody_sprite(valve) === :Valves_Large_valvebody
        @test HexFlowSwitchComponents.static_sprite(valve) === :Valves_Large_static
        @test HexFlowSwitchComponents.controlbox_sprite(valve) === :Valves_OnOff_controlbox
        @test HexFlowSwitchComponents.valve_travel_px(valve) == 100.0f0
    end
end

# ===============================================================
# StandardValveCompBehav -- On/Off Tiny
# ===============================================================

@testset "StandardValveCompBehav{BoolSwitchBehavFrag, TinyValve}" begin
    valve = StandardValveCompBehav(BoolSwitchBehavFrag, TinyValve;
        max_conductance = 2.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0)
    )

    @testset "Element layout" begin
        elements = produce_rel_elements(valve)
        @test length(elements) == 1
        @test elements[1].type === CONST_RESISTOR
    end

    @testset "Sprite trait dispatch" begin
        @test HexFlowSwitchComponents.fluidmask_sprite(valve) === :Valves_Tiny_fluidmask
        @test HexFlowSwitchComponents.valvebody_sprite(valve) === :Valves_Tiny_valvebody
        @test HexFlowSwitchComponents.static_sprite(valve) === :Valves_Tiny_static
        @test HexFlowSwitchComponents.controlbox_sprite(valve) === :Valves_OnOff_controlbox
        @test HexFlowSwitchComponents.valve_travel_px(valve) == 25.0f0
    end

    @testset "Tunables round-trip" begin
        tunables = get_tunables(valve)
        @test length(tunables) == 3

        valve2 = set_tunables(valve, (3.0, 0.0, 1.5))
        @test valve2.switch.switch.max_conductance ≈ 3.0
    end
end

# ===============================================================
# calculate_growth_factor utility
# ===============================================================

@testset "calculate_growth_factor" begin
    # Basic: positive conductance range
    gf = calculate_growth_factor(2.0, 0.0, 6.0 / 60.0)
    @test gf > 1.0

    # Round-trip: growth_factor → percentage mapping is internally consistent
    # A switch using this growth_factor should traverse 0→max in ~(max/change_rate) ticks
    sw = make_switch(growth_factor = gf, target_conductance = 2.0)
    ticks = 0
    while sw.state.current_conductance < 1.99 && ticks < 500
        update_flowbehav!(sw)
        ticks += 1
    end
    @test sw.state.current_conductance ≈ 2.0 atol=0.02
    @test ticks < 500  # Should converge

    # Edge: very small change_rate → error
    @test_throws ErrorException calculate_growth_factor(2.0, 0.0, 1e-10)
end
