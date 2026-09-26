# FlowCalculator crash dumps

## Captured data and its limits

The writer is `HexFlowCalculator._write_crash_dump` in `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl`. Its current JLD2 keys are `stored_gamemap`, `pending_commands`, `node_voltages`, `vsource_currents`, `exception_message`, and `exception_backtrace`. The map is the authoritative map at the catch point. The MNA dictionaries are the solver's then-current outputs; they may be empty or left from an earlier successful solve if failure occurred before new outputs were written. The dump does **not** include `DerivedMapState`, the full `MNA_State`, matrix A, solver caches, scheduler state, a command transaction's disposable candidate map, or an explicit failing phase. Older dumps may lack keys.

The writer drains the command channel as the calculator exits. Its `pending_commands` vector therefore contains commands awaiting processing, not necessarily a culprit. `last_command` is not written. Current command transactions use a working map, validate another disposable copy, then commit. Expected invalid/stale requests and candidate validation errors are reported or rejected; they may never produce a loop crash dump. Check `command_diagnostic` and `process_transaction!` plus terminal logs when a command is suspected.

## Reading a dump

1. Inspect the exception and backtrace first. Match frames to the phase of `flowcalculator_loop!`; follow any nested exception and coordinate in logs. Note that `exception_backtrace` is text from `showerror`, not a serialised stack object.
2. Check that `stored_gamemap` loaded as a plausible current `GameMap`. The inspector uses `HexFlowPersistence.loadmap_strict` for the embedded map and plain JLD2 for the calculator-owned metadata. If map reading fails, examine `HexFlowPersistence` migrations and saved type compatibility before assuming a circuit fault.
3. Review queued command summaries and the map's component, valve, tank, nozzle, pump, deactivation, damage, and reactivation context. Use `--coord Q R` for a tile named by a frame, command, or circuit report; inspect its neighbours and map ownership.
4. If the stack points into the solve or generated circuit, run the deep diagnostic on the dump's stored map. Label it a current-code reproduction. The saved map may already reflect component updates from the failing tick, while the deep tool starts with fresh derived/MNA state and no live command queue or reactivation scheduler.

Absence of an exception key suggests an ordinary map save or an older/partial dump. The inspector can report available fields, but a missing field is not evidence that the live state was empty. For a current failure that cannot be reproduced, compare source revision, command history, simulation tick, and transient state before claiming a cause.
