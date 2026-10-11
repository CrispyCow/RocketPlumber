`component_state_stage1.jld2` is targeted migration data captured from
`f0edfea4d751ce5815ea842ac4b513eb24a23c2e` before the state/configuration cleanup.
It supplements the sole frozen release map under the root `test/fixtures/`.
Do not regenerate it with current types: the historical names and layouts are
what the migration test exercises.

The payload contains sealed/forced tanks (charge 23; liquid 21 and gas 4), fuel
liquid identity, damaged temperature 725 K, rotor overspeed 4200 RPM with a
3000 RPM rating, delayed power 12.5, stored energy 37, a deactivated chamber at
750 K, stalled state and auto-deactivation. Fixed configuration is also retained.

`component_representation_stage2.jld2` captures the component representations at
`6fb9a20cd70367138c36353ce810298a7e7cdd4a`, before sprite/variant storage changed.
It contains a generic basic component with `:HistoricalBasic`, all three basic
nozzle sprite families (each with independent throat area 0.73), all four valve
switch/size combinations (target conductance 1.0, current 0.4), and both electric
pump variants with stored energy 37. Do not regenerate it with current types.
