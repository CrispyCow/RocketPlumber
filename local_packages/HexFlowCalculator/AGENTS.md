# HexFlowCalculator Guide

This package owns authoritative simulation mutation, command transactions,
solver orchestration, and render-thread snapshot publication. Changes here can
affect determinism, thread safety, map validity, and most gameplay systems.

## Command Transactions

- UI/input callers enqueue `MapEditCommand` values with
  `try_enqueue_command!`; they do not mutate the calculator's map directly.
- A transaction deep-copies the authoritative map, applies the command to that
  working copy, validates another disposable copy through the component and MNA
  pipeline, then commits by mutating the original map in place.
- Expected player rejection uses `InvalidRequest`. Stale commands are invalid,
  while exceptions and failed candidate validation are rejected and leave the
  authoritative map unchanged.
- New command types need a typed payload, creation/enqueue path, diagnostic
  context, application method, status behaviour, and transaction tests. Avoid
  placing UI objects or OpenGL state in commands.

## Tick Pipeline

Preserve phase order unless the change explicitly redesigns its dependencies.
The active simulation path currently:

1. updates docking and manoeuvre phase;
2. updates component state;
3. scans reactivation requests;
4. collects primary circuit elements and fluid declarations;
5. attempts one speculative reactivation trial, or runs the base solve;
6. handles thrust and manoeuvre burn progress;
7. advances space-map time, refreshes estimated minimum delta-v, and records
   the simulated tick;
8. publishes a snapshot.

The solve path filters elements to a fixed point in this order: `prune!`,
`ground_search!`, then `clear_dangling_dependants!`; it then propagates fluids,
builds/stamps MNA state, solves, scales voltages, and computes region
temperatures. Keep this order coherent with reactivation trials and candidate
validation.

When paused, commands are still drained. If any were processed, rebuild the
derived/MNA state and publish without advancing time.

## Snapshots And Shared State

- Snapshot storage is triple-buffered. Publication deep-copies `gamemap`,
  refills derived/MNA/game-state snapshot buffers, and swaps indices under a
  short lock.
- Returned snapshots and their maps are detached read models, but callers must
  still treat them as read-only. A buffer slot will be reused after a later
  swap.
- Access every field of `FlowCalculatorSharedState` atomically. Do not add an
  unsynchronised side channel between the calculator and render threads.
- Keep live mutable state confined to the calculator thread unless a type has
  an explicit synchronisation contract.

## Reactivation

- A queued component probe extends the primary solve inputs speculatively; it
  must not mutate the map before classification.
- Commit only a `PROBE_USEFUL` result. Preserve fairness/queue behaviour when
  changing scan or trial scheduling, and ensure a failed probe cannot leak
  solver state into the base tick.

## Verification

Run:

```shell
julia --project=local_packages/HexFlowCalculator -e 'using Pkg; Pkg.test()'
```

Follow with affected `FlowMap`, `FlowEngine`, component, or proc-gen suites,
then the application smoke test for end-to-end command or tick changes.
