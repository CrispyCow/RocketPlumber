# Component System

Components use a **fragment composition** pattern. Complex behaviours are built from small reusable `*BehavFrag` structs. Concrete types (`*CompBehav` for tiles, `*PipeBehav` for edges) compose fragments and delegate interface methods.

See `component_module_guide.md` for the full authoring guide.

---

## Component Packages

- `HexFlowBasicComponents` — reusable fragments (`PlainSpriteBehavFrag`, `BasicElemBehavFrag`, `StallBehavFrag`, `BinaryStateBehavFrag`, `FloatStateBehavFrag`, `HorizontalFlipOnlyBehavFrag`, `NoRotationBehavFrag`) and `BasicCompBehav`
- `HexFlowTankComponents` — gas/liquid tanks (Thevenin equivalent) and pressure-fed tanks (separate gas headspace), charge tracking, stall protection
- `HexFlowNozzleComponents` — nozzles, switched nozzles, decomp chambers with thrust calculation and particle exhaust
- `HexFlowPumpComponents` — turbopumps (gas-driven) and electric pumps (battery-powered) with energy management
- `HexFlowSwitchComponents` — bool switches, stepped adjustable valves, and on/off valves in two sizes (`LargeValve`, `TinyValve`)
- `HexFlowPipeComponents` — tile-based pipe components (`ScrapTilePipeCompBehav`, `BigTilePipeCompBehav`)
- `HexFlowBasicPipes` — edge-based pipe behaviours (`ScrapPipeBehav`, `BigPipeBehav`)

---

## ComponentBehavior Interface (tile-placed)

**Mandatory methods:**
- `produce_rel_elements(behav)` — declare circuit elements in tile-local coordinates
- `get_tunables(behav)` — expose editable parameters for the properties UI
- `set_tunables(behav, tunables)` — return new instance with updated values (immutable update via `@set`)
- `render_base_elem!(queue, behav; glmap, rotation, position, pos_offset, render_height_offset, kwargs...)` — push render commands

**Optional methods** (with sensible defaults): `render_map_elem!`, `produce_rel_fluid_declarations`, `update_flowbehav!`, `on_click!`, `get_thrust`, `get_component_temperature`, `collect_effect_particles!`, `map_rotation`, `can_be_moved`, `placement_valid`, `get_component_dry_mass`, `get_component_wet_mass`, `get_component_mass`, `get_actions`, `do_action!`

---

## PipeBehavior Interface (edge-placed)

**Mandatory:** `get_conductance`, `get_pipe_tunables`, `set_pipe_tunables`, `render_pipe_base!`

**Optional:** `render_pipe_map!`, `produce_rel_fluid_declarations`, `can_pipe_be_moved`, `produce_abs_elements`, `get_tile_pipe_equivalent`

---

## Existing Components (`src/components.jl` — 15 entries)

- **Tanks**: `TriGasTank`, `TriLiquidTank` (both `ThevininTankCompBehav`), `PressureFedLiquidTank` (`PressureFedTankCompBehav`)
- **Nozzles**: `TinyNozzle`, `SmallNozzle`, `MediumNozzle`, `SwitchedTinyNozzle`, `BasicDecompChamber`
- **Pumps**: `TurboPump`, `ElecTurboPump`, `ElecTransferPump`
- **Valves**: `LargeAdjValve`, `TinyAdjValve` (stepped), `LargeOnOffValve`, `TinyOnOffValve` — all `StandardValveCompBehav{S,V}`
- **Pipes (edge)**: `ScrapPipe` (2.0 S), `BigPipe` (10.0 S)

---

## Adding a New Component

1. Create a new package under `local_packages/components/`
2. Follow fragment composition: define `*BehavFrag` structs, compose into `*CompBehav`
3. Implement all 4 mandatory interface methods
4. Register `roll_component(::Val{:YourKind}, ...)` in `src/components.jl` for proc-gen support
5. Add concrete instances to `src/components.jl`
