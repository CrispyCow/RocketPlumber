---
name: rocket-plumber-map-diagnostics
description: Investigate Rocket Plumber saved maps, FlowCalculator crash dumps, circuit generation, and MNA failures when explicitly asked to diagnose them.
---

# Rocket Plumber Map Diagnostics

Use this specialist workflow for a saved `GameMap` or a FlowCalculator crash dump. Run commands from the repository root with `--project=.`. The scripts load application components and current JLD2 conversions; allow for Julia startup time. Work on copies if the artifact may be needed as evidence. These scripts do not alter the supplied file, but the deep run mutates its in-memory map while advancing the circuit state.

## Choose a path

- **Crash dump:** Start with `julia --project=. .agents/skills/rocket-plumber-map-diagnostics/scripts/inspect_crash_dump.jl PATH`. It reports captured exception, backtrace, pending commands, map and selected component state. Read [crash-dumps.md](references/crash-dumps.md) before interpreting that report. Use `--coord Q R` to inspect a reported tile and its neighbours. Run the deep tool on the same file only when current-code circuit reproduction would help; its result is a new calculation, not the captured failure.
- **Ordinary saved map or suspected circuit/MNA fault:** Run `julia --project=. .agents/skills/rocket-plumber-map-diagnostics/scripts/debug_map_MNA.jl PATH [TICKS]`. Start with one tick, then use a small number of ticks if the symptom depends on state evolution. Read [circuit-and-mna.md](references/circuit-and-mna.md) to interpret filtering, element identities, matrix rank, and source tracing. This is a headless base circuit calculation, not a full gameplay replay.
- **Map will not load:** Check the loading error and `stored_gamemap` before drawing circuit conclusions. `src/map_loading.jl` owns the JLD2 typemap and upgrade hooks. A map-load problem belongs there or in persisted type changes, not in MNA analysis.

## Diagnose from evidence

Locate the failing phase first: deserialisation, command transaction, component update, element/fluid generation, filtering, A construction/factorisation, Z/solve, or later gameplay work. Compare the captured exception and stack trace with the current implementation. Pending commands are queue contents at dump time; they do not by themselves identify the command that failed. Follow suspicious `NodeCoord`s and `ElementID`s to their map owner and the component or pipe's element producer. Inspect current source and relevant tests before proposing a root cause.

Report what the artifact captured, what the scripts reproduced in current code, and what you infer from those observations. A healthy base solve only establishes that this loaded state completed the exercised path. A rank deficit identifies an unconstrained combination in the analysed matrix; its null vector suggests where to investigate, not which component is defective. For a future production crash, check the current writer and solver again: these helpers intentionally use internal APIs and cannot guarantee diagnosis of an unknown failure.
