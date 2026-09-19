# FlowEngine Guide

`FlowEngine` transforms placed component/pipe contributions into filtered
circuit and fluid state, constructs and solves sparse MNA systems, and computes
fluid-region temperatures. Keep gameplay orchestration and authoritative map
mutation in `HexFlowCalculator`.

## Solver Invariants

- Component `RelativeElement` values are mapped to stable `AbsoluteElement`
  identities; pipe behaviours normally produce one absolute resistor from
  conductance. Preserve element IDs because dependant sources refer to them.
- Circuit filtering is a fixed-point process called by `HexFlowCalculator`:
  `prune!`, then `ground_search!`, then `clear_dangling_dependants!`. If the
  dangling pass removes controllers/dependants, pruning and grounding must run
  again.
- Ground reachability intentionally does not treat current sources or
  zero-conductance resistors as voltage references. Changing those predicates
  can turn valid filtering into singular MNA systems.
- Propagate fluid declarations over the surviving graph before temperature and
  thrust consumers read the derived state. Clear stale node, fluid, region, and
  MNA outputs when the filtered circuit becomes empty.
- `CalculatorScratchpad` containers are caller-owned reusable storage. Leave
  them in the documented clean state and avoid replacing in-place hot paths
  with allocating convenience wrappers without measurement.

## MNA Changes

- An `ElementTypes` addition or semantic change must update labels/units in
  `HexElements`, plus element classification, source indexing, A/Z stamping,
  solution-current extraction, diagnostics, and focused tests here.
- The A-matrix cache distinguishes topology changes from value-only changes.
  Preserve structural/value hash semantics and the full rebuild versus
  in-place refactorisation paths.
- Keep matrix sign and node-order conventions consistent across stamping and
  output extraction. Add a small analytically checkable circuit test for each
  new stamp or source type.
- Do not hide singularities by broadly catching solver errors; candidate-map
  validation relies on failures to reject invalid transactions.

## Verification

Run:

```shell
julia --project=local_packages/FlowEngine -e 'using Pkg; Pkg.test()'
```

Also run `HexFlowCalculator` tests when graph filtering, derived-state layout,
MNA lifecycle, or temperature propagation changes.
