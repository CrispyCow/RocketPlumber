# Local Packages

## Dependency Layers

**Foundation** (no game-package dependencies):
- `HexFrame` — hex-grid coordinate types, conversions, adjacency queries, rotation algebra
- `HexFluids` — fluid type system (`FluidType`/`FluidConstraint` enums), fluid declaration types (`FluidSource`, `FluidTypeRule`, `FluidConstraintRule`), relative/absolute wrappers
- `HexElements` — circuit element types (`RelativeElement`, `AbsoluteElement`), element-type enum, coordinate mapping
- `SquirrelNoise` — deterministic noise functions (SquirrelNoise5 hash), counter-mode `SquirrelRNG`

**Core Logic:**
- `HexComponentsAPI` — abstract interfaces for `ComponentBehavior` and `PipeBehavior`, `ComponentOnTile` wrapper, `TunableProps`, `ActionInfo`
- `FlowMap` — data model (`GameMap`, `ShipMap`), ship management, docking system, space map, encounter/manoeuvre types, placement validation, bounds/geometry
- `FlowEngine` — MNA circuit solver, `DerivedMapState`, `MNA_State`, graph pruning, fluid type propagation, region temperature computation. Depends on `FlowMap` (does not re-export it)

**Application State:**
- `HexFlowControl` — `GameState`, `InputState`, `ViewState`, `PlacementModes` enum, `SimSpeed` enum, `ExitReason` enum, view transform matrix, input edge-detection helpers, closure-based console buffer

**Simulation:**
- `HexFlowCalculator` — background-thread simulation loop, `MapEditCommand` subtypes, `FlowCalculatorSnapshot`, `FlowCalculatorIPC`, `update_map!`/`update_mna!` orchestration, manoeuvre phase state machine

**Procedural Generation:**
- `HexFlowProcGen` — ship surface generation (random tile walks), component/pipe placement strategies, encounter point system (spawn/recycle via bounds-check), `SpaceMapState`, manoeuvre planning (closest-approach, intercept delta-v), ship generation configs

**Learning/Tutorial System:**
- `HexFlowLearningSystem` — tutorial types (`SandboxTutorialDef`, `SandboxTutorialLevel`, `InGameTutorialDef`, `TutorialStep`, `LearningEntry`, `LearningInputs`), trigger/step-blocker predicates, `LearningSystemState` (render-thread runtime), tutorial flow helpers
- `FlowMap` — persistent learning state (`TutorialState`, `LearningProgress`, `SandboxLearningState`) stored on `GameMap`, plus save/load reconstruction hooks

**Rendering:**
- `RenderEngine` — low-level OpenGL abstraction (`GLObjectMap`, `RenderCommand`, typed shader programs, VAOs, textures, UBOs, sprites)
- `HexFlowRendering` — game-specific rendering (4 render programs, sprite/tile/pipe helpers, particle system, animation functions, render height constants, GLSL shaders)
- `HexFlowTelemetry` — diagnostic `TimerOutput` instances and tick-gated printing

**Component Implementation** (under `local_packages/components/`): See `components/CLAUDE.md`.

Packages with tests: `FlowMap`, `FlowEngine`, `HexFlowCalculator`, `HexFlowProcGen`, `HexFlowRendering`, `HexFrame`, `HexFluids`, `HexFlowLearningSystem`, `SquirrelNoise`.

---

## What to Check When Modifying Packages

**Modifying Public APIs:**
- When modifying exported struct fields or function signatures, search for the symbol across the entire repo — packages re-export and `using` each other extensively
- JLD2 serialisation may need reconstruction hooks in `src/map_loading.jl` when load-time control is required
