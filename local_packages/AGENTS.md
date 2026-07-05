# local_packages - Codex Notes

This directory contains the repo's Julia packages. Also consult the root
`AGENTS.md` and `local_packages/CLAUDE.md` when changing package code.

## Dependency Layers

- Foundation: `HexFrame`, `HexFluids`, `HexElements`, `SquirrelNoise`
- Core logic: `HexComponentsAPI`, `FlowMap`, `FlowEngine`
- Application state: `HexFlowControl`
- Simulation: `HexFlowCalculator`
- Procedural generation: `HexFlowProcGen`
- Learning/tutorials: `HexFlowLearningSystem`
- Rendering: `RenderEngine`, `HexFlowRendering`, `HexFlowTelemetry`
- Components: packages under `local_packages/components/`

Keep dependencies flowing in the established direction. Avoid introducing
lower-layer dependencies on gameplay, rendering, or application packages.

## Editing Rules

- Search the whole repository before modifying exported names, struct fields,
  constructors, or function signatures.
- Update callers in `src/` as well as package tests when public APIs change.
- Consider save compatibility when modifying types stored in `GameMap`; hooks
  may belong in `src/map_loading.jl`.
- Prefer package-local tests when the changed package has a test suite.

Packages with known tests include `FlowMap`, `FlowEngine`, `HexFlowCalculator`,
`HexFlowProcGen`, `HexFlowRendering`, `HexFrame`, `HexFluids`,
`HexFlowLearningSystem`, and `SquirrelNoise`.

## Running Tests

```powershell
Set-Location local_packages/<PackageName>
julia --project=. -e "using Pkg; Pkg.test()"
```

