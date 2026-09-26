# Local Package Guide

`local_packages/` contains the Julia packages that implement the game. Prefer
putting reusable domain behaviour here and leaving `src/` as the application
integration layer. Each package has a `Project.toml`; a package root may also
own workspace member projects that share its root `Manifest.toml`. The local
package updater refreshes package-root workspaces.

## Responsibility Map

- `HexFrame`: hex coordinate types, canonicalisation, transforms, adjacency,
  pipe spans, and stacking order.
- `HexFluids`: fluid types, constraints, declarations, physical lookup data,
  and temperature defaults.
- `HexElements`: relative and absolute circuit-element representations and
  coordinate mapping.
- `SquirrelNoise`: deterministic hash noise and `SquirrelRNG`.
- `components/HexComponentsAPI`: behaviour interfaces, placed component/pipe
  wrappers, tunables, actions, validation results, and shared simulation
  constants.
- `FlowMap`: persistent/runtime map model, ship ownership, placement, docking,
  learning persistence, space-map abstractions, and playthrough statistics.
- `FlowEngine`: derived circuit/fluid state, graph filtering, fluid
  propagation, region temperatures, sparse MNA construction, and solving.
- `HexFlowProcGen`: deterministic ship/encounter generation, encounter space
  maps, and manoeuvre planning.
- `HexFlowPersistence`: persisted time-lapse types, game-map save/load, and
  historical save migrations.
- `HexFlowCalculator`: authoritative simulation loop, command transactions,
  reactivation trials, snapshots, and calculator IPC.
- `HexFlowLearningSystem`: tutorial definitions, runtime learning state, and
  trigger/blocker evaluation.
- `HexFlowControl`: input, selection, placement, view, session, and simulation
  control state shared by the application.
- `HexFlowTelemetry`: shared timing and diagnostic output.
- `RenderEngine`: low-level typed OpenGL resources and render commands.
- `HexFlowRendering`: game render programs, sprite/tile/pipe helpers,
  particles, shaders, and render-height constants.
- `components/HexFlow*Components` and `HexFlowBasicPipes`: concrete behaviour
  implementations. See `components/AGENTS.md`.

This is a responsibility map, not permission to introduce arbitrary imports.
Treat each package's `Project.toml` as the current dependency graph and avoid
making domain/foundation packages depend on application or concrete-component
packages.

## Package Change Rules

- Search the whole repository before changing an exported name, constructor,
  struct layout, or method contract. Update downstream packages, `src/` call
  sites, and tests together.
- Keep abstract interfaces and neutral wrappers in `HexComponentsAPI`; keep
  map ownership and validation in `FlowMap`; keep numerical circuit/fluid work
  in `FlowEngine`; keep tick orchestration and mutation transactions in
  `HexFlowCalculator`.
- A type stored beneath `GameMap` is persistence-facing even if its package has
  no JLD2 dependency. Changes to its identity or layout require review of
  `HexFlowPersistence` migrations and appropriate historical fixtures/tests.
- Adding an `ElementTypes` member requires matching labels/units in
  `HexElements`, plus `FlowEngine` classification, matrix stamping, solution
  extraction, and tests.
- Do not edit generated manifests by hand. When package dependencies change,
  resolve the affected environments and ensure the root environment still
  resolves. `julia tools/local_package_updater.jl` refreshes all local package
  environments; pass `--update` only when dependency upgrades are intended.

More specific invariants live in `FlowMap/AGENTS.md`, `FlowEngine/AGENTS.md`,
`HexFlowCalculator/AGENTS.md`, and `HexFlowRendering/AGENTS.md`.

## Testing

Run the closest package suite first:

```shell
julia --project=local_packages/<PackageName> -e 'using Pkg; Pkg.test()'
```

For a component package, include the `components/` segment. To discover or run
every package suite under this tree:

```shell
julia tools/run_all_package_tests.jl --list
julia tools/run_all_package_tests.jl
```

The runner discovers test suites dynamically, runs them in separate Julia
processes, and writes ignored logs under `logs/package_test_runs/`. Use
`--help` for parallelism, child-thread, instantiation, and logging options.
