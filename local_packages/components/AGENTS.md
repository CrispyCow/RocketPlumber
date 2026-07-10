# local_packages/components - Codex Notes

This directory contains component implementation packages. Also consult the
root `AGENTS.md`, `local_packages/AGENTS.md`, and
`local_packages/components/CLAUDE.md`.

Components use fragment composition. Reusable fragments are named `*BehavFrag`.
Concrete tile components are named `*CompBehav`; pipe-segment behaviours are named
`*PipeBehav`.

## Component Packages

- `HexFlowBasicComponents`: reusable fragments and `BasicCompBehav`
- `HexFlowTankComponents`: gas, liquid, and pressure-fed tanks
- `HexFlowNozzleComponents`: nozzles, switched nozzles, decomp chambers
- `HexFlowPumpComponents`: turbopumps and electric pumps
- `HexFlowSwitchComponents`: adjustable and on/off valves
- `HexFlowBasicPipes`: pipe-segment behaviours

## Tile Component Interface

Mandatory methods:

- `produce_rel_elements(behav)`
- `get_tunables(behav)`
- `set_tunables(behav, tunables)`
- `render_base_elem!(queue, behav; glmap, rotation, position, pos_offset, render_height_offset, kwargs...)`

Optional methods include `render_map_elem!`,
`produce_rel_fluid_declarations`, `update_flowbehav!`, `on_click!`,
`get_thrust`, `get_component_temperature`, `collect_effect_particles!`,
`map_rotation`, `can_be_moved`, `placement_valid`,
`get_component_dry_mass`, `get_component_wet_mass`, `get_component_mass`,
`get_actions`, and `do_action!`.

## Pipe Interface

Mandatory methods:

- `get_conductance`
- `get_pipe_tunables`
- `set_pipe_tunables`
- `render_pipe_base!`
- `get_pipe_click_radius`

Optional methods include `render_pipe_map!`,
`produce_rel_fluid_declarations`, `can_pipe_be_moved`,
and `produce_abs_elements`.

## Adding Components

1. Create or update a package under `local_packages/components/`.
2. Follow fragment composition for shared behaviour.
3. Implement the mandatory interface methods.
4. Register `roll_component(::Val{:YourKind}, ...)` or pipe equivalents in
   `src/components.jl` when proc-gen needs to create it.
5. Add concrete instances to `src/components.jl` where the game should expose
   them.

