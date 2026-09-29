# Component Package Guide

This tree contains the neutral component API and the concrete tile/pipe
behaviour packages. Concrete behaviours use fragment composition: reusable
parts end in `BehavFrag`, complete tile behaviours in `CompBehav`, and pipe
behaviours in `PipeBehav`.

## Package Map

- `HexComponentsAPI` defines the interfaces, placed wrappers, tunables,
  actions, request results, mass hooks, and reactivation-probe contract.
- `HexFlowBasicComponents` provides shared rendering, circuit, state, stall,
  rotation, and mirroring fragments.
- `HexFlowSwitchComponents` implements boolean and stepped switches plus valve
  behaviours.
- `HexFlowTankComponents` implements gas, liquid, and pressure-fed storage.
- `HexFlowNozzleComponents` implements nozzles and combustion chambers.
- `HexFlowPumpComponents` implements turbopumps and electric pumps.
- `HexFlowBasicPipes` implements the built-in pipe behaviours.

Use `component_module_guide.md` for the established module layout and fragment
pattern. Treat the current `HexComponentsAPI` source and tests as authoritative
for method names and signatures; verify guide examples before copying them.

## Module Style

These rules apply to the concrete implementation packages. `HexComponentsAPI`
may use API-specific documentation and sections where the implementation-module
layout does not fit.

- Start each migrated source file with an accurate scope header and its
  `Formatter` policy. Obey the policy after every edit.
- Give each implementation module a short module docstring whose inventory
  contains exactly its exported concrete `ComponentBehavior` or `PipeBehavior`
  implementations. Do not include fragments, state holders, traits, aliases,
  or helpers in that inventory.
- Use broad `using` statements for types, constants, and ordinary helper calls.
  Use `import Package: method_names` for foreign functions extended by the
  module. Group `using` statements by dependency role with consistently ordered
  names. Import only the methods actually extended; keep each statement on one
  physical line and use another complete statement when a semantic grouping is
  useful. Do not introduce package aliases merely to shorten interface method
  definitions.
- Group exports, omitting empty groups, as behaviour fragments, helper
  functions, support types, and concrete component or pipe behaviours.
- Use `Behaviour Fragments` and `Concrete Component Behaviours` (or `Concrete
  Pipe Behaviours`) as the normal major sections. Give each primary fragment or
  concrete behaviour a minor banner. Keep its closely related state, traits,
  constants, and methods together; use short ordinary comments for method
  subgroups such as rendering or reactivation probes.
- Document exported types and genuinely non-obvious helpers or contracts. In
  implementation packages, straightforward API implementations, pure
  delegation, obvious accessors, and routine rendering methods do not need
  docstrings; the API package owns their general contract documentation.
- Keep every rendering-function signature and every call representing one
  rendering operation on one physical line, regardless of length. This
  includes nested operations such as `push!(queue, render_basic_tile(...))`.
  Setup calculations and control flow inside rendering functions still follow
  the normal semantic-layout guidance.

Use Australian English in project-owned prose and headings (`behaviour`,
`colour`, `standardised`). Preserve established identifiers and external API
names such as `ComponentBehavior` exactly.

## Behaviour Contracts

- Implement every mandatory method for a new concrete behaviour and rely on an
  optional default only when its semantics are genuinely correct. Tests should
  exercise both direct behaviour calls and placed-wrapper delegation.
- Component circuit elements and fluid declarations use tile-relative
  coordinates. `FlowEngine` maps them after placement. Pipes normally rely on
  the default conductance-to-resistor conversion.
- The simulation currently collects fluid declarations from components. Adding
  a pipe fluid-declaration feature requires an explicit API and collection-path
  change, not merely a method on one pipe type.
- Preserve `pos_offset` and `render_height_offset` through both base and dynamic
  render methods so docking animation and layer ordering remain correct.
- Override dry and wet mass hooks separately for stored-fluid components;
  generic ship mass calculations combine them.
- `get_actions` describes supported UI actions. `do_action!` returns a request
  result for expected state rejection and throws for an unsupported action ID.
- Reactivation classification must be pure. Mutate behaviour state only in
  `commit_reactivation_probe!` after the calculator accepts a useful probe.

## Precompile Workloads

- Concrete implementation packages own compilation of API defaults and wrappers
  specialised for their supported `ComponentBehavior` and `PipeBehavior` types.
  `HexComponentsAPI` owns interface definitions and generic behaviour contracts;
  it needs no dedicated workload merely for abstract/default methods. The root
  application owns a small realistic workload for heterogeneous and
  runtime-dispatch integration paths.
- Put an implementation workload in `src/precompile_workload.jl` and include it
  from the package module after the relevant definitions. Import the needed
  `PrecompileTools` macros in the workload file. Use `@setup_workload` to
  construct fixtures without executing the API paths being precompiled; use
  `@compile_workload` for those calls. Multiple compile-workload stages are
  appropriate when target calls produce state needed by later target calls.
- Cover supported concrete specialisations, mandatory methods, overridden
  optional hooks, and important placed-wrapper paths such as
  `produce_abs_elements`. Add states only when they reach materially different
  execution paths; a workload is not a behavioural test suite.
- Use minimal, deterministic fixtures. Reuse test patterns for valid solver
  state. Render headlessly with fake sprite metadata when methods only enqueue
  commands. Avoid display, GL execution, external I/O, and lasting runtime
  side effects during package precompilation. Where dependencies load GLFW,
  verify headlessly with `JULIA_GLFW_PLATFORM=null`; do not set it in the workload.
- Keep fixture helpers internal and local until repeated use justifies shared
  infrastructure. Update the workload when adding a concrete specialisation or
  a materially new API execution path.

## Adding Or Changing A Component

1. Update the most appropriate existing package unless the behaviour introduces
   a genuinely new reusable dependency boundary.
2. Follow nearby fragment composition, imports, exports, constructors, and test
   organisation.
3. Add or update application-level instances in `src/components.jl` when the
   game should expose the behaviour.
4. Add `roll_component`/`roll_pipe` registration there when procedural
   generation needs to create it, and update relevant generation pools.
5. Add source sprites under `tools/TexturePacker/textures/` and regenerate the
   tracked atlas when rendering needs new artwork.
6. Add or update the package precompile workload for each supported concrete
   specialisation and materially new API path.
7. Run the package test suite, plus dependent component or application tests
   when a shared fragment or interface changed.

Application names such as `TurboPump`, `TriGasTank`, and `LargeAdjValve` are
instances in `src/components.jl`; they are not implementation types. Search
both the concrete type and the application instance before changing behaviour.
