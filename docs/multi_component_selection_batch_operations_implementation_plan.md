# Multi-Component Selection and Batch Operations Implementation Plan

## Purpose

Add player-facing multi-component selection and shared group actions without coupling persistent selection to the existing placement gesture state machine. Execute group actions through a general, all-or-nothing `BatchCommand` facility that can later support other transactional map edits.

The work is deliberately divided into three independently reviewable stages:

1. Introduce the orthogonal selection state machine while preserving existing single-selection behaviour.
2. Introduce and test general transactional batch commands without using them from gameplay.
3. Add multi-selection interaction, shared-action menus, selection rendering, and gameplay batch execution.

Each stage should leave the game in a working state and pass its own package tests and gameplay smoke test before the next stage begins.

## Agreed Player Behaviour

- Shift + left-click on an unselected component adds it to the current selection.
- Shift + left-click on a selected component removes it from the selection.
- Shift + left-click on empty space leaves the current selection unchanged.
- Right-click on any selected component opens the group action menu.
- Right-click on an unselected component clears the existing group and opens the ordinary single-component menu for that component.
- Right-click on empty ship surface retains the existing ship action behaviour and clears any component selection.
- An ordinary left-click on empty space clears the component selection, subject to the existing click-versus-move and pipe interaction rules.
- Escape and entry into incompatible placement/editor modes clear the selection.
- Selection is limited initially to tile components on ships with zero render offset, matching current interaction restrictions.
- Pipes, box selection, group movement, and drag selection are not part of the first implementation.

Shift is the only additive-selection modifier in the initial implementation. Control-click should not be added as an alias unless player testing identifies a need.

## Architectural Decisions

### Selection is orthogonal to placement

The existing `AbstractPlacementState` hierarchy continues to represent the active tool or gesture: ready, pressed, move, pipe chain, editor placement, surface editing, and redocking.

A separate `AbstractSelectionState` hierarchy represents persistent world selection. This allows a later group move to combine a persistent selection with a placement gesture rather than forcing both concepts into one mutually exclusive state machine.

The selection belongs in `InputState`. It is transient render-thread UI state, not authoritative `GameMap` state, and must not be saved or sent to the calculator.

### Selection targets are extensible

Use typed selection targets so pipe selection can be added later without redesigning the state model. The first implementation only accepts component targets.

The expected shape is approximately:

```julia
abstract type AbstractSelectionTarget end

struct ComponentSelectionTarget <: AbstractSelectionTarget
    coord::TileCoord
end

struct PipeSelectionTarget <: AbstractSelectionTarget
    coord::PipeCoord
end

abstract type AbstractSelectionState end
struct SelectionEmptyState <: AbstractSelectionState end

mutable struct ComponentSelectionState <: AbstractSelectionState
    targets::Set{ComponentSelectionTarget}
    primary::ComponentSelectionTarget
end
```

`PipeSelectionTarget` may be defined in the first stage to establish the abstraction, but it must not become selectable yet. If defining an unused concrete pipe target adds noise, defer that concrete type while retaining `AbstractSelectionTarget`.

The `primary` target provides deterministic popup anchoring and lets the inspector retain a useful single-component view. It should be updated predictably when the primary target is removed, using a stable rule rather than relying on `Set` iteration order.

### Group actions are matched by stable action ID

For a component selection, call `get_actions` on every currently valid selected component and match actions by `ActionInfo.id`.

- Only action IDs present on every selected component are shown.
- A shared action is enabled only if it is enabled for every selected component.
- If an action is shared but disabled for one or more components, show it disabled with an aggregate explanation such as `Unavailable for 3 of 12 selected components.`
- An action missing from any component is omitted rather than displayed disabled.
- Group deletion is added as a synthetic shared action.
- Equal action IDs are expected to have compatible labels and confirmation messages. Use the primary target's display metadata and emit a development warning if other targets disagree.

The group popup title should include the selection count, for example `Actions - 12 Components`. Confirmation text must also make the scope explicit.

### Batch commands are map transactions

Add a general `BatchCommand <: MapEditCommand` containing an ordered vector of child `MapEditCommand`s. It occupies one queue slot and has the only response channel for the transaction.

Children are applied in order to one private working copy of the authoritative `GameMap`. If any child returns `false` or throws, discard the working copy and leave the live map untouched. If all children apply, validate the final candidate once through the graph/MNA validation pipeline. Commit only after validation succeeds.

Do not recursively call `process_command!` for child commands. Doing so would commit child operations independently and defeat rollback.

### Validation requires a second speculative copy

The current validation pipeline calls `update_components!`, which can mutate component state. Therefore transaction processing needs separate maps:

1. `working_map = deepcopy(live_map)`, on which child commands are applied.
2. `validation_map = deepcopy(working_map)`, on which speculative component updates and graph/MNA validation run.
3. Commit `working_map`, never `validation_map`, to avoid advancing component behaviour as a side effect of validation.

The live map should be replaced from the successfully tested working candidate instead of replaying commands against the live map. This ensures the committed state is the state that passed the transaction and prevents action hooks from executing twice.

### Batch execution validates the final state

Each child's immediate domain checks still run against the progressively modified working map. The expensive circuit validation runs once after all children have applied. This permits temporarily incomplete intermediate circuit states when the final state is valid.

This is ordered transaction semantics, not automatically simultaneous operation semantics. A future group move with overlapping source and destination tiles will probably need a specialised `MoveGroupCommand` that removes all sources and places all destinations as one child operation. That specialised command can itself participate in a `BatchCommand`.

### Transaction side effects are controlled

- Child commands in a batch must have `response_channel = nothing`.
- Only the outer batch reports `APPLIED`, `INVALID`, `REJECTED`, or `QUEUED_FAILED`.
- Console messages generated while applying children are buffered.
- Buffered success messages are published only after commit.
- On failure, discard success messages and publish one useful summary identifying the failing child index and reason.
- Commands must be explicitly marked batchable. Default to not batchable so future commands with external side effects cannot silently participate in transactions.
- Nested batches should initially be rejected. They can be flattened by a constructor later if a concrete use case appears.

## Stage 1: Orthogonal Single-Selection State

### Goal

Introduce the new selection state machine and migrate existing single-component selection, popup highlighting, clearing, and inspection to it without enabling group selection. Player-visible behaviour should remain effectively unchanged.

### Implementation

#### `HexFlowControl`

- Add and export the selection target and selection state types.
- Add `selection_state::SelectionState` to `InputState`, defaulting to `SelectionEmptyState()`.
- Add focused helpers such as:
  - `selection_state(inputstate)`
  - `selected_component_coords(inputstate)`
  - `primary_selected_component(inputstate)`
  - `select_single_component!(inputstate, coord)`
  - `clear_selection!(inputstate)`
  - `has_selected_component(inputstate, coord)`
- Update `clear_world_selection!` and placement transition helpers to clear the new selection consistently.
- Keep popup state separate from selection state: closing a popup should use an explicit policy rather than relying on nullable coordinate fields.
- Remove `rightclick_selectedcoord` after all callers have migrated. Do not leave two competing component-selection sources of truth.
- Retain `rightclick_selectedship` unless ship selection is intentionally migrated at the same time. Component multi-selection does not require generalising ship selection.

#### Input and popup flow

- Change ordinary component right-click to call `select_single_component!` before constructing the existing `ComponentPopupTarget`.
- Preserve current restrictions on offset ships and placement-ready state.
- Ensure ordinary left-click, pipe-chain entry, move activation, editor tool entry, redocking, Escape, and ship right-click clear selection according to existing behaviour.
- Closing the ordinary single-component popup should preserve or clear the selection exactly as current gameplay does. Record this in tests rather than allowing it to emerge accidentally from popup implementation details.

#### Rendering and inspector

- Render the existing green marker from the new selection state, still for at most one coordinate in this stage.
- Update the inspector to use the primary selected component.
- If the selected component disappears from the current snapshot, clear or prune the selection safely rather than retaining an invalid coordinate.

### Tests

Add `HexFlowControl` tests for:

- Empty selection by default.
- Selecting one component.
- Replacing a single selection.
- Clearing selection.
- Primary-target queries.
- World-selection and placement-transition helpers clearing selection.
- No dependence on the removed `rightclick_selectedcoord` field.

Add or extend interaction-level tests where practical for:

- Single right-click opening the same component popup as before.
- Popup target and selected component remaining consistent.
- Offset-ship restrictions.
- Selection clearing on incompatible state transitions.

### Review Gate

- No Shift-click group behaviour exists yet.
- Existing single-component menus, actions, deletion, inspector display, and green highlight behave as before.
- `HexFlowControl` package tests pass.
- The root gameplay smoke test passes.

## Stage 2: General Transactional Batch Commands

### Goal

Build and test the calculator transaction facility independently of player selection. Existing single commands should share the corrected transaction path so single and batch semantics cannot drift.

### Implementation

#### Refactor command processing

- Extract the graph/MNA sandbox validation portion of `process_command!` into a focused helper such as `validate_gamemap_candidate!`.
- Add an internal transaction result containing at least:
  - Public `CommandStatus`.
  - Failed child index, when applicable.
  - Human-readable failure reason.
- Add a transaction processor that:
  1. Deep-copies the live map to a working map.
  2. Applies all child commands in order to the working map.
  3. Stops immediately on `false` or exception.
  4. Deep-copies the completed working map for speculative validation.
  5. Validates the final candidate once.
  6. Replaces the live map from the working map only on success.
  7. Publishes buffered messages and the outer response status.
- Route ordinary single commands through the same transaction processor as a one-command transaction.
- Correct the existing behaviour where the sandbox application result is discarded.
- Stop replaying a successful command on the live map after validation.

#### Add `BatchCommand`

- Define and export `BatchCommand <: MapEditCommand` with:
  - Its own command ID.
  - An ordered collection of child commands.
  - Its own optional response channel.
  - Optional summary metadata only if it materially improves console reporting.
- Add and export `create_batch_command`.
- Construct batches defensively:
  - Reject empty batches unless a no-op batch has an explicit use case.
  - Reject nested batches.
  - Reject children with response channels.
  - Copy or otherwise take safe ownership of the child collection.
- Add `is_batchable` dispatch with a safe default of `false`.
- Initially allow the ordinary map-local commands needed for actions, deletion, placement, and movement after reviewing each implementation for external effects.
- Explicitly review or exclude `MapOverrideCommand`, encounter creation, and redocking.

#### Error and message behaviour

- Distinguish a child returning `false` (`INVALID`) from final sandbox validation failure (`REJECTED`).
- Include the failed child position in the failure message.
- Do not emit child success messages for rolled-back work.
- On success, either emit buffered child messages or a concise batch summary. Prefer summary output for homogeneous large batches.
- Ensure a closed batch response channel cannot crash the calculator loop, matching current policy.

### Required transaction invariants

- A failed child leaves the live map byte-for-byte or hash-equivalent to its pre-transaction state.
- A validation exception leaves the live map unchanged.
- Successful children before a failed child are rolled back.
- Later children observe earlier changes in the same working map.
- The committed map is the command-mutated working map, not the validation map.
- Component actions execute once on the committed state, not once speculatively and again live.
- The batch consumes one queue slot.
- Child response channels never receive misleading partial-success notifications.

### Tests

Add `HexFlowCalculator` tests for:

- Successful batch of heterogeneous batchable commands.
- Failure of the first, middle, and last child with complete rollback.
- A later command observing an earlier command's working-map mutation.
- Final graph/MNA validation failure rolling back all children.
- Successful commit matching the working candidate.
- Validation-only `update_components!` mutations not leaking into the committed map.
- `DoActionCommand` behaviour executing exactly once from the live-state perspective.
- Child console messages discarded on rollback.
- Batch response channel receiving one final status.
- Empty, nested, non-batchable, and child-response-channel cases being rejected.
- One queue slot handling a batch larger than the queue's normal child count.
- Existing single-command statuses and response-channel tests continuing to pass.

### Review Gate

- No gameplay code creates `BatchCommand` yet.
- All existing calculator command tests pass under the refactored transaction path.
- New rollback, commit, status, and side-effect tests pass.
- Root gameplay smoke test passes.
- Review performance with a representative multi-command batch and confirm it performs one final graph/MNA validation rather than one per child.

## Stage 3: Multi-Selection and Group Actions

### Goal

Enable Shift-click multi-selection, calculate shared actions, render all selections, and execute chosen actions atomically through `BatchCommand`.

### Implementation

#### Selection transitions

- Extend `ComponentSelectionState` to hold multiple unique targets.
- Add helpers for toggling a component, counting selections, and pruning missing or newly ineligible targets.
- Detect left and right Shift with `get_instate`.
- Intercept Shift + left-click before existing short-click/move classification so it cannot accidentally trigger `on_click!`, pipe placement, or hold-to-move.
- Shift-clicking a selected component removes it.
- Shift-clicking an unselected component adds it and makes it the primary target unless testing indicates the original primary is more intuitive.
- When removing the primary target, choose a replacement deterministically.
- Shift-clicking empty space does nothing to the selection.
- Ordinary right-click on an unselected component replaces the entire selection with that component and opens the ordinary single menu.
- Right-click on a selected component opens the group menu when more than one component is selected.
- Right-click on ship surface clears component selection and opens the existing ship menu.
- Prevent selection of components on offset ships.

#### Stale selection handling

- Before rendering, inspecting, or building a popup, reconcile selected coordinates against the current `FlowCalculatorSnapshot`.
- Remove coordinates whose components no longer exist.
- Close a group popup if its target set is no longer meaningful.
- If one valid component remains, safely fall back to single-selection behaviour where appropriate.
- Never send coordinates from an older selection directly to gameplay commands without authoritative calculator-side validation.

#### Group popup target and shared actions

- Add a typed `ComponentGroupPopupTarget` containing a stable ordered collection of selected coordinates.
- Anchor the popup at the right-clicked selected component, not an arbitrary `Set` element.
- Add a pure shared-action aggregation helper that is easy to unit test.
- Intersect action IDs across all selected components.
- Preserve the primary/right-clicked target's display order where possible.
- Aggregate enabled state across all components.
- Report the number of components that disable a shared action.
- Warn on inconsistent label or confirmation metadata for an equal ID.
- Add group deletion as a synthetic action with an explicit count in its confirmation text.
- Keep the existing single-component popup path unchanged for a one-element selection.

#### Batch gameplay execution

- For an ordinary shared component action, create one `DoActionCommand` per selected coordinate with no child response channel, then wrap them in one `BatchCommand`.
- For group deletion, create one `DeleteAtCommand{TileCoord}` per selected coordinate and wrap them in one `BatchCommand`.
- Use a stable coordinate ordering for reproducible behaviour, logs, and tests.
- Enqueue only the outer batch.
- Clear the popup and selection after successful enqueue, matching current single-action menu flow.
- If enqueueing fails, retain enough UI state for the player to retry and show the failure clearly.
- Calculator-side transaction checks remain authoritative because the render snapshot may be stale.

#### Rendering and inspector

- Render the existing green `:MoveArrow_arrow_start` marker at every selected coordinate as the provisional visual.
- Keep marker colour, height, and scale centralised so a dedicated selection sprite can replace it later.
- Consider a distinct tint or intensity for the primary/right-clicked component only if the group anchor is otherwise unclear; this is optional for the first pass.
- Show the selected count in the inspector while continuing to inspect the primary component.

### Tests

Add selection and interaction tests for:

- Shift-click adding multiple components.
- Shift-click toggling a selected component off.
- Shift-click empty space preserving selection.
- Primary-target replacement after removal.
- Right-clicking a selected component opening a group popup.
- Right-clicking an unselected component replacing the group and opening a single popup.
- Right-clicking ship surface clearing component selection.
- Ordinary empty-space click and Escape clearing selection.
- Placement/editor/redock transitions clearing selection.
- Offset-ship components remaining unselectable.
- Stale selected coordinates being pruned safely.

Add action aggregation tests for:

- Identical tanks exposing all common actions.
- A tank and pump exposing only their shared action IDs.
- An action missing from one component being omitted.
- An action present but disabled on some components being shown disabled.
- Stable display ordering.
- Inconsistent metadata warning behaviour.
- Synthetic group deletion always being available for valid component selections.

Add integration tests for:

- A group action creating one queued `BatchCommand` with the expected children.
- Group deletion creating the expected delete children.
- A stale or invalid child causing complete calculator rollback.
- Successful tank action affecting every selected tank.
- No partial group mutation when one selected component no longer supports the requested action.

### Review Gate

- Shift-click selection and toggle behaviour feels predictable in manual testing.
- Single-component right-click behaviour remains unchanged.
- Heterogeneous groups expose only genuinely shared actions.
- Disabled shared actions cannot be invoked.
- Group actions and deletion are all-or-nothing at the calculator transaction boundary.
- Selection markers are visible and do not obscure component actions or placement ghosts.
- Package tests and the root gameplay smoke test pass.
- Perform manual inspection through `src/repl_launch.jl` after the automated smoke test.

## Likely File Touchpoints

- `local_packages/HexFlowControl/src/HexFlowControl.jl`
  - Selection target/state types, `InputState`, and transition helpers.
- `local_packages/HexFlowControl/test/runtests.jl`
  - Selection state and transition tests.
- `src/interactions.jl`
  - Shift-click routing, right-click decisions, popup construction, pruning, and provisional selection markers.
- `src/ui_menus.jl`
  - Group popup rendering, confirmation, target-dispatched batch execution, and popup closing policy.
- `src/ui_game.jl`
  - Primary component inspection and group count.
- `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl`
  - Transaction refactor, validation helper, `BatchCommand`, constructor, batchability, buffered messages, and status handling.
- `local_packages/HexFlowCalculator/test/runtests.jl`
  - Transaction, rollback, validation, side-effect, and queue tests.
- `src/test_harness.jl`
  - Batch command construction helpers if gameplay integration tests require them.

Search all callers before removing `rightclick_selectedcoord` or changing exported command APIs.

## Testing Commands

Run after each stage from the indicated project directory.

```powershell
Set-Location local_packages/HexFlowControl
julia --project=. -e "using Pkg; Pkg.test()"

Set-Location ../HexFlowCalculator
julia --project=. -e "using Pkg; Pkg.test()"

Set-Location ../..
julia --project=. --threads=2,1 --gcthreads=1,1 src/auto_test_launch.jl
```

After Stage 3, manually inspect interaction behaviour with:

```powershell
julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl
```

Allow at least six minutes for the automated gameplay smoke test before treating it as hung.

## Deferred Work

- Dedicated selection marker sprite and final visual treatment.
- Pipe selection and shared pipe actions.
- Box, drag, or paint selection.
- Control-click aliases.
- Group movement UI.
- `MoveGroupCommand` with simultaneous source/destination semantics.
- Mixed component-and-pipe selection.
- Nested or composable batches.
- Rich structured transaction results exposed through response channels.
- Undo/redo built on transaction records.

## Completion Criteria

The feature is complete when players can Shift-click a group of components, clearly see the selection, right-click a selected member, choose an action supported by every selected component, and have that action or deletion apply to all selected components atomically. Existing single-component, placement, movement, pipe-chain, ship-action, and editor interactions must continue to behave correctly.
