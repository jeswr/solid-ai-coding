<!-- AUTHORED-BY Claude Opus 4.8 -->
---
name: solid-app-shell
description: >-
  Use when a Solid app's interactions feel slow because every change blocks on a pod write — make mutations optimistic: update the UI immediately (e.g. a kanban card slides to its new column), persist to the pod ASYNCHRONOUSLY without blocking the interaction, show a small non-intrusive Saving…/Saved indicator, and on failure show an error + revert. Covers the two revert correctness traps caught in review: revert only the field(s) the failed write changed (preserving concurrent edits to other fields), and never let a stale failed write clobber a NEWER mutation of the same item.
---

# App shell — optimistic, non-blocking pod mutations

Read the companion [`AGENTS.md`](https://github.com/jeswr/solid-ai-coding/blob/main/AGENTS.md)
first; pairs with the [`solid-offline`](https://github.com/jeswr/solid-ai-coding/blob/main/skills/solid-offline/SKILL.md)
skill (instant-load reads) — this one is the **write** side of the same "the app feels instant" goal.

A pod write is a network round-trip (often a conditional PUT/PATCH plus a refresh). Blocking the
interaction on it makes the UI feel sluggish — a dragged card hangs in mid-air until the server
answers. Instead, make mutations **optimistic**:

1. **Update the UI immediately.** Apply the change to local state the instant the user acts — the
   kanban card slides to its new column, the toggle flips, the title updates — before any network
   call.
2. **Persist asynchronously.** Fire the pod write **without blocking** the interaction, and crucially
   **without the blocking full-refresh** that a normal mutation does (the local state is already
   correct). Reconcile in the background on success (a live-sync/refresh will also catch any coupled
   change the server made).
3. **Show a small, non-intrusive save indicator** for in-flight writes: "Saving…" while pending, a
   brief "Saved" on success that auto-clears to idle, "Save failed" on error. A fixed-corner pill
   (`role="status"`, `aria-live="polite"`, hidden when idle) — never a modal or a blocking spinner.
4. **On failure: show an error AND revert** the optimistic change. The revert is where the
   correctness lives — see below.

```ts
// optimistic write — local first, persist in the background, revert on failure
const { next, original } = optimisticMove(items, id, move /* … */);
if (!original) return;          // no-op (already in that state) — don't show "Saving…"
setItemsLocal(() => next);      // UI updates instantly
persist((repo) => repo.applyWrite(id, move)).catch(() => {
  setItemsLocal((cur) => revertIfCurrent(cur, original, next.optimistic, move));
});
```

## Revert correctly — the two traps (both real review findings)

A naïve revert ("on error, put the old record back") is wrong in two ways that bite in practice.

### Trap 1 — reverting the WHOLE record clobbers concurrent edits to other fields

While the failed write was in flight, the user may have edited a **different** field of the same
item (changed the title, added a comment, reassigned it). Replacing the whole record with the stale
`original` throws those edits away.

**Fix: revert only the field(s) the failed write changed, onto the CURRENT record.** A status move
rolls back `status`/`state` only; a priority move rolls back `priority` only — both spread over the
*current* record so every unrelated field is preserved:

```ts
const reverted =
  move.kind === "status"
    ? { ...current, status: original.status, state: original.state }
    : { ...current, priority: original.priority };
```

### Trap 2 — a stale failed write clobbers a NEWER mutation of the same item

If the user moves the **same** card again while the first write is still in flight, the first
write's later failure must **not** roll the card back to where the *first* move started — the second
move now owns the card's state. A blind revert resurrects stale state and undoes the user's newer
action.

**Fix: track the expected optimistic state and only revert if the current local state still
corresponds to the failed mutation.** Capture the record the failed write optimistically produced
(`optimistic`); on failure, compare the card's *current* state against it on the move's own
dimension. If they no longer match, a newer move already changed the card — **drop the stale failure
and leave the list unchanged**:

```ts
function revertIfCurrent(items, original, optimistic, move) {
  const current = items.find((i) => i.id === original.id);
  if (!current) return items;                 // item gone (deleted/archived) — nothing to revert
  const stillThisMove =
    move.kind === "status"
      ? current.status === optimistic.status && current.state === optimistic.state
      : current.priority === optimistic.priority;
  if (!stillThisMove) return items;           // a newer move owns it — drop the stale failure
  const reverted = move.kind === "status"
    ? { ...current, status: original.status, state: original.state }   // Trap 1: field-scoped
    : { ...current, priority: original.priority };
  return items.map((i) => (i.id === original.id ? reverted : i));
}
```

Compare on the **move's dimension** (status vs priority), not by object reference — a later
unrelated re-render produces a fresh object reference and must not look like "a newer move".
Equivalently, a per-item mutation id works: stamp each optimistic write with an id, and only revert
when the item's current pending-mutation id still equals the failed write's.

## Indicator, no-ops, and reconciliation

- **A move that doesn't change anything is a no-op** — a drop onto the card's *current* column must
  not fire a write or show "Saving…". `optimisticMove` returns no `original` in that case; bail.
- **Keep the optimistic state in the durable cache too** (see `solid-offline`), so a reopen
  mid-write paints the optimistic state rather than the pre-write one.
- **Reconcile in the background after a successful persist** (a non-blocking refresh), so a change
  the server coupled to your write — e.g. a workflow status that also flips an open/closed flag —
  lands without the user waiting on it.

## Gotchas

| Gotcha | Detail |
|---|---|
| Interaction hangs until the pod answers | The write is blocking — update local state first, persist async, never `await` before the UI updates |
| Concurrent edits lost on revert | Trap 1 — revert only the failed write's field(s) onto the **current** record, never replace the whole record with `original` |
| Newer move undone by an older failure | Trap 2 — capture the optimistic state / a mutation id and revert only if the current state still corresponds to the failed write |
| Spurious "Saving…" on a no-op drop | A move to the current column changes nothing — detect it (no `original`) and skip the write |
| Indicator clutters the UI | Hide when idle; auto-clear "Saved" back to idle after ~1.5 s; fixed-corner pill, `aria-live="polite"`, not a modal |
| Coupled server change missing after persist | Background-reconcile on success — the server may have changed a field your write didn't set |

---

*Learned building [`jeswr/solid-issues`](https://github.com/jeswr/solid-issues): the optimistic
board logic in [`src/lib/board.ts`](https://github.com/jeswr/solid-issues/blob/main/src/lib/board.ts)
(`optimisticMove`, `revertMoveIfCurrent` — both revert traps), the non-blocking `persist` in
[`src/lib/use-issues.ts`](https://github.com/jeswr/solid-issues/blob/main/src/lib/use-issues.ts),
and the [`src/components/save-indicator.tsx`](https://github.com/jeswr/solid-issues/blob/main/src/components/save-indicator.tsx)
pill, commit `ca0c687`. Both revert traps were roborev findings fixed in that change.*
