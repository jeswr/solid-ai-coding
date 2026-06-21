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
// optimisticMove returns three things: the new item LIST, the pre-move record,
// and the optimistically-moved record (the "expected current state" the revert
// compares against so a stale failure can't clobber a newer move — see Trap 2).
const { items: next, original, optimistic } = optimisticMove(items, id, move /* … */);
if (!original) return;          // no-op (already in that state) — don't show "Saving…"
setItemsLocal(() => next);      // UI updates instantly
persist((repo) => repo.applyWrite(id, move)).catch(() => {
  setItemsLocal((cur) => revertIfCurrent(cur, original, optimistic, move));
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

## Flush a debounced write on tab teardown — don't lose the last edit

An optimistic mutation that **debounces** the pod write (coalescing rapid edits into one PUT) has a
gap the optimistic path itself doesn't cover: if the user **closes the tab, navigates away, or
backgrounds it** while a debounced write is still pending, the timer never fires and the **last edit
is lost** — the UI showed "Saving…" (or even "Saved" optimistically) but nothing reached the pod. The
durable cache (`solid-offline`) preserves it for *that* browser, but a different device never sees it.

Flush pending writes on the teardown signals — and mind the `keepalive` body cap:

- **Flush on `pagehide` AND `visibilitychange` → `hidden` (and `beforeunload` as a belt-and-braces).**
  `visibilitychange(hidden)` is the most reliable on mobile (a backgrounded tab the OS may kill never
  fires `pagehide`/`unload`); `pagehide` covers tab-close/navigation. Treat them as the same "the page
  may be going away now — persist now" trigger and de-dupe (below).
- **Use `fetch(url, { keepalive: true })` so the request OUTLIVES the page** — a normal `fetch` is
  cancelled when the document tears down, so the write never completes. `keepalive` lets the browser
  finish it after the page is gone. **But `keepalive` has a hard ~64 KB cap on the encoded request
  body** (the Fetch spec's `keepalive` inflight-body limit) — over it the `fetch` **rejects**. So:
  encode the body first, and use `keepalive` **only when it fits**; an oversized snapshot falls back
  to a **normal** `fetch` (best-effort — it may not finish, but it can't silently swallow the write).
  (`navigator.sendBeacon` is the same cap and can't send the conditional `If-Match`/`Content-Type`
  headers a pod PUT needs, so prefer `keepalive` `fetch`.)
- **Clear the pending marker only AFTER the write resolves — keep it for retry on failure.** A teardown
  flush that optimistically marks the snapshot "saved" before the keepalive request resolves loses the
  edit if that request fails; leave the durable-cache pending flag set until success so the next open
  retries.
- **Coalesce concurrent unload flushes of the SAME snapshot.** `pagehide` and `visibilitychange` can
  both fire for one teardown; firing two keepalive PUTs of the same body **doubles** the bytes counted
  against the per-page keepalive cap (and can race the conditional `If-Match`). Single-flight the flush
  on the snapshot's identity/version so one teardown sends **one** request. **But never coalesce a
  keepalive flush onto a non-keepalive in-flight save** — a normal debounced save already in flight is
  cancelled by the teardown, so the keepalive flush must still run; only coalesce keepalive-with-keepalive.

This is the teardown corner of the optimistic-mutation / `solid-offline` invariant: optimistic +
durable-cache makes the edit *survive locally*; the keepalive flush is what makes it *reach the pod*
when the tab dies mid-debounce. (Cited: the five jeswr OSS Solid forks — Linkding, Elk, Excalidraw,
Miniflux, Actual — 2026-06; Excalidraw's debounced scene-persist needed the `pagehide` keepalive
flush + the 64 KB cap fallback, hardened over roborev's fetch/unload rounds.)

## Indicator, no-ops, and reconciliation

- **A move that doesn't change anything is a no-op** — a drop onto the card's *current* column must
  not fire a write or show "Saving…". `optimisticMove` returns no `original` in that case; bail.
- **Keep the optimistic state in the durable cache too** (see `solid-offline`), so a reopen
  mid-write paints the optimistic state rather than the pre-write one.
- **Reconcile in the background after a successful persist** (a non-blocking refresh), so a change
  the server coupled to your write — e.g. a workflow status that also flips an open/closed flag —
  lands without the user waiting on it.

## Reading a pod container into a view (the read side)

Building a list/browser view over a pod container surfaced three patterns worth applying every time (each a roborev finding while building 8 sibling Solid apps):

- **Inject the authenticated `fetch` as a seam, don't hard-wire login.** The view/hook/data-layer take an injectable `fetch` (fall back to the ambient global a reactive-auth shell patches). This builds + unit-tests *now* (stub the fetch) while the real login wires in later — the view is never coupled to the auth flow.
- **Validate `ldp:contains` child IRIs before you fetch them.** A view that reads each child of a listed container must NOT blindly fetch every IRI the container advertises — a malicious/malformed container can list arbitrary URLs/schemes (an SSRF vector, and it runs before any href-display gate). Require each child to be: an `http(s):` IRI, **same-origin** with the container (compare parsed `URL.origin`, not a raw string prefix — defeats `https://you@evil/…` userinfo + look-alike-prefix tricks), and a **real descendant path** (compare `URL.pathname` under the container's slash-terminated path with a non-empty remainder — so the container itself, even with `?query`/`#fragment`, is rejected). Drop anything else (don't fetch, don't fail the listing).
- **A data-layer `list()` that swallows 401/403 → `[]` is right for the store but WRONG for a screen.** It makes "you don't have permission" indistinguishable from "empty", so a forbidden container renders "Nothing here" instead of an access-denied state. Wrap it in a thin **UI read facade** that surfaces a typed `AccessDeniedError` (401/403), maps **404 → empty**, **2xx-empty → empty**, else re-throws — without changing the shared store contract other callers depend on. And on an access error during a *reload*, **clear the previously-loaded list + selection** so stale data doesn't linger under the access-denied state.

## Cross-app interop on a shared pod — a consumer must map EVERY producer's `forClass`

Suite apps interoperate by reading and writing the **same pod resources**, discovered through the
**Type Index** (see the [`solid-type-index`](https://github.com/jeswr/solid-ai-coding/blob/main/skills/solid-type-index/SKILL.md)
skill for the registration/lookup mechanics). A *producer* app registers its container with
`solid:instanceContainer` and stamps it with its primary class via `solid:forClass`; a *consumer*
app — a pod manager, dashboard, or any "browse my data" view — discovers that data by matching those
`forClass` IRIs into its own categories/views. No shared paths, no app-to-app coupling: the class
IRI is the contract.

**THE TRAP (a real finding, cross-app interop test 2026-06-16 across
[`jeswr/pod-docs`](https://github.com/jeswr/pod-docs), [`jeswr/pod-chat`](https://github.com/jeswr/pod-chat),
and the Pod Manager on one shared pod):** a consumer must map *every* producer's registered
`forClass` IRI into its own category/view map — otherwise the producer's data is **still discovered**
(it shows up) but lands in a generic "uncategorised / other" bucket instead of the right view.
Concretely, pod-docs registers its documents as `pd:Document` (`https://w3id.org/jeswr/pod-docs#Document`);
the Pod Manager hadn't mapped that IRI, so the docs surfaced under "Other data" until the consumer
added the class to its Documents category. The data was never lost — just mis-bucketed — which makes
this easy to miss in a quick look (the app "works", it's just in the wrong place).

So, two standing rules when you **add a producer app** to a suite that shares a pod:

1. **Add its registered class(es) to the consumer's category/view map** in the same change — and
   include both `https://schema.org/` and legacy `http://schema.org/` forms where the producer might
   stamp either (pods in the wild use both). For an interim/placeholder namespace
   (`https://TBD.example/…` pending a frozen vocab base), keep the consumer's map in sync with the
   producer's vocab module and leave a comment so the freeze updates both.
2. **Cover each mapping with a regression test** — assert each producer's primary `forClass` resolves
   to its expected category and is NOT the fallback bucket, so a future edit that drops a mapping
   fails loudly instead of silently re-bucketing that app's data into "Other".

**The interop-friendly resource shape** that worked across all the suite apps: **one resource per
item**, Turtle, with a **stable fragment subject** (`<#it>` / a per-item `#…` IRI, not a bare `<>`),
typed with **standard vocabs** — schema.org, ActivityStreams (`as:Note`), or a domain ontology — and
**registered per-container in the Type Index** (`solid:instanceContainer` + `solid:forClass`). A
stable fragment subject lets other apps and the consumer reference the item by a durable IRI across
edits; standard vocabs are what make the `forClass` match work without bilateral agreement.

## A prebuild config generator must load `.env` itself — and resolve precedence PER-LAYER

A per-origin host shell often runs a **prebuild script** to emit build-time config — most commonly a
per-subdomain Client Identifier Document (`clientid.jsonld`, see the `solid-client-id` skill), whose
served URL *is* the `client_id`, so a wrong origin = broken login at the deployed subdomain. Two traps,
both real (cited:
[`jeswr/pod-photos@bd490ac`](https://github.com/jeswr/pod-photos/commit/bd490ac),
[`jeswr/pod-music@2c3dcb3`](https://github.com/jeswr/pod-music/commit/2c3dcb3)):

- **A script that runs BEFORE the bundler does not get the bundler's `.env` loading.** Vite (etc.) loads
  `.env`/`.env.local` for *your app code*, not for a Node script you run in a prebuild step — so reading
  only `process.env` means a plain `npm run build` (no shell var set) silently bakes the **localhost/dev**
  origin into the production document, even though `.env.example` claims those files drive it. Load them
  yourself: `parseEnv` from `node:util` (zero deps; needs Node ≥ 20.12) over `.env` then `.env.local`.
- **Resolve the origin PER-LAYER, in strict priority — do NOT merge the files into one dict.** Order:
  `shell (non-empty) → .env.local → .env → dev-default`; each layer picks its *own* origin var (e.g.
  `APP_ORIGIN`, else `VITE_APP_ORIGIN`), and the **first layer that yields one wins**. Merging the two
  files into a single dict and then picking per-variable (`merged.APP_ORIGIN ?? merged.VITE_APP_ORIGIN`)
  is **wrong**: if `.env` sets `APP_ORIGIN` and `.env.local` sets the *other* var (`VITE_APP_ORIGIN`),
  the merged dict keeps both keys and the `APP_ORIGIN`-first pick returns the `.env` value — so `.env`
  beats `.env.local` cross-variable, and `.env.local` fails to fully override `.env`. Per-layer
  resolution avoids that. (Treat an **empty** shell var `APP_ORIGIN=` as *absent*, so it doesn't suppress
  a file value.)
- **Guard the file-writing `main()` behind a realpath `isInvokedDirectly()` check** (compare
  `realpathSync(process.argv[1])` to this module's `realpathSync(fileURLToPath(import.meta.url))`), and
  export the pure resolver — so the precedence logic is **unit-test-importable side-effect-free** (no
  filesystem write, no `process.env` read) while still running on direct invocation.

## Never call a throwing typed setter from a controlled input's `onChange`

A controlled (live-edit) React text input wired **directly** to a typed model setter that
**validates by throwing** is a recurring footgun. Typed RDF accessors (`@solid/object` /
`@rdfjs/wrapper` `…As` setters, see the [`solid-object`](https://github.com/jeswr/solid-ai-coding/blob/main/skills/solid-object/SKILL.md)
skill) throw on invalid input — and **every intermediate keystroke is transiently invalid**: the
empty string mid-edit, a duplicate-while-retyping, a half-typed value. So `onChange={(e) =>
model.statusName = e.target.value}` throws the moment the field is blank and breaks the editor.

**Pattern: store raw, validate separately, set only valid.** The controlled input writes the **raw**
string into local component state and **never throws in `onChange`**. Validation runs separately —
over the assembled draft — surfaced as a save-blocking validity check / inline error. The throwing
model setter is invoked **only at save time, with an already-valid value:**

```tsx
// onChange NEVER throws — raw string into local state
<input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
// validate the assembled draft separately (save-blocking + inline error)
const error = draft.name.trim() === "" ? "Name required"
  : isDuplicate(draft.name) ? "Name already used" : undefined;
// the throwing typed setter runs ONLY at save, with a valid value
<button disabled={!!error} onClick={() => { model.statusName = draft.name; save(); }}>Save</button>
```

This generalises to ANY Solid app form bound to typed RDF accessors that validate — store-raw-then-
validate, never let a transient mid-edit value reach a throwing setter. (Learned building the
[`jeswr/solid-issues`](https://github.com/jeswr/solid-issues) workflow-editor, 2026-06-17 — a
status-rename input wired straight to a throwing typed setter broke on the empty string mid-edit.)

## Tailwind v4: a host app's UNLAYERED global rule out-ranks ALL your `@layer`'d utilities

A shared component library (an app shell consumed by many apps) cannot assume the host's global CSS
leaves its controls alone. In Tailwind v4 utilities live in `@layer utilities`, and an author rule
that is **unlayered** — a bare `button {}` / `input {}` in the app's CSS, outside any `@layer` —
beats **every** `@layer`'d rule in the cascade, regardless of specificity or source order (unlayered
author styles always win over layered ones). So a host app's plain `button { background; border;
color }` repaints your shell's buttons, and **`@layer`'ing your component CSS or bumping specificity
does NOT fix it** — a layered rule loses to an unlayered one no matter how specific.

Two defenses that actually make a library immune to arbitrary host global CSS:

- **Ship an unlayered, attribute-scoped defensive reset.** Mark your controls with a data attribute
  and write an **unlayered** `[data-app-shell-control] {…}` rule. An attribute selector (specificity
  0,1,0) beats a bare element selector (0,0,1) **when both are unlayered**, so your controls keep
  their look against any host `button {}`. Re-assert the leak-prone visuals there (fill/border/text
  per variant, the `:focus-visible` ring). Give consumers an escape hatch (a prop to opt a control
  out) so they can still restyle it.
- **Isolate design tokens with a library-private mirror of LITERAL values, not `var()` indirection.**
  A token that resolves `var(--accent)` re-reads the consumer's `:root` at use-time, so a host
  re-aliasing `--accent` still clobbers you. Hold literal values in private names instead
  (`--as-accent: #4f46e5`). Declare that private mirror on a **shared ancestor that portaled content
  also inherits from** — a `:root`/host-element scope (or a class on a stable ancestor), NOT only on
  the control selector: CSS custom properties inherit down the DOM **subtree** only, so a token
  declared on `[data-app-shell-control]` won't reach a dropdown/dialog **portaled outside** that
  subtree. (Alternatively, stamp portaled roots with the same data attribute.) A `:root`-scoped
  private literal both reaches portals and resists the consumer-override that `var()` indirection
  suffers.

```css
/* The private LITERAL mirror lives on a shared ancestor (`:root`/host) so
   portaled menus/dialogs inherit it — NOT `var(--accent)` indirection. */
:root { --as-accent: #4f46e5; }

/* UNLAYERED (outside any @layer) so a host's bare `button {}` can't beat it.
   Attribute selector (0,1,0) > element selector (0,0,1) when both are unlayered. */
[data-app-shell-control] {
  background: var(--as-accent);
  border: 1px solid var(--as-accent);
  color: #fff;
}
[data-app-shell-control]:focus-visible { outline: 2px solid var(--as-accent); }
```

(Learned building [`@jeswr/app-shell`](https://github.com/jeswr/app-shell), 2026-06-17 — a consuming
app's unlayered `button {}` repainted the shell's controls and `@layer`/specificity bumps didn't fix
it; an unlayered attribute-scoped reset + a private literal token mirror did.)

## Apply theme in an isomorphic layout effect, not a passive `useEffect`, to kill the first-frame flash

A `ThemeProvider` that resolves + applies the theme (and adopts the stored preference) in a passive
`useEffect` runs **after paint**: for a dark-OS `system` user, `resolvedTheme` starts `"light"` and
is corrected only after the first frame — a one-frame light flash for any content rendered off
`resolvedTheme`. An inline pre-hydration `<script>` that toggles the `.dark` **class** does NOT fix
the React **state** that content reads.

**Fix: apply via an isomorphic layout effect** — `useLayoutEffect` in the browser, `useEffect`
off-browser (a `typeof window` guard) — so `resolvedTheme` and the `.dark` class are correct on the
**first painted frame**. It's SSR-safe: a no-op off-browser, and the first render still uses the
SSR-stable default so there's no hydration mismatch. Generalises to any light/dark/system theme
provider.

```ts
const useIsomorphicLayoutEffect =
  typeof window !== "undefined" ? useLayoutEffect : useEffect;

useIsomorphicLayoutEffect(() => {
  const resolved = preference === "system" ? systemPrefersDark() ? "dark" : "light" : preference;
  setResolvedTheme(resolved);                                  // correct on the first PAINTED frame
  document.documentElement.classList.toggle("dark", resolved === "dark");
}, [preference]);
```

(Learned building [`@jeswr/app-shell`](https://github.com/jeswr/app-shell), 2026-06-17 — a
`ThemeProvider` applying the theme in a passive `useEffect` flashed light for one frame for dark-OS
`system` users.)

## `@lit/react` drops a custom element's reactive PROPERTY under React 19 unless it reflects to an attribute

When a framework-agnostic Web-Components chrome library (Lit) ships a React adapter via `@lit/react`'s
`createComponent`, the wrapper classifies each prop **at component-creation time** — *before* the Lit
element class is finalized. A Lit reactive **property** that is NOT reflected to an attribute can then
be **silently dropped** when set through the React wrapper under React 19: the property never reaches
the element, so it renders its fallback (e.g. a `<jeswr-loading label="Signing you in…">` shows the
generic "Loading"). It looks like the prop "didn't take" with no error.

Three fixes, in order of preference:

- **(a) Make the element's string props `reflect: true`** (declare them as attributes) so a real
  browser forwards them as attributes — the durable fix, in the library. (But `reflect: true` does
  **not** make the prop reach the element under `@lit/react`'s React wrapper in **vitest/jsdom** —
  see the test caveat below.)
- **(b) Until then, consume via the RAW custom element with a DOM attribute**, not the React-wrapper
  property: `<jeswr-loading label="Signing you in…">` rather than the wrapped `<Loading label=…>`.
- **(c) In unit tests, drive the RAW custom element and assert via the rendered shadow root /
  `::part` / the reflected attribute (`reflect: true`) / `aria-label` — NOT the raw property and NOT
  a React-wrapper assertion** — and validate real prop-forwarding in a browser.

```tsx
// (a) library-side: a reflected property is forwarded by @lit/react in a real browser
@property({ type: String, reflect: true }) label = "Loading";

// (b) consumer workaround until (a) lands — raw element + DOM attribute, not the wrapper property
<jeswr-loading label="Signing you in…" />

// (c) test against the RAW element's rendered DOM, not the React wrapper and not the property
//     (cast: createElement returns HTMLElement — use the exported element type if you have it)
const el = document.createElement("jeswr-loading") as HTMLElement & { label: string; updateComplete: Promise<unknown> };
el.label = "Signing you in…"; document.body.append(el);
await el.updateComplete;
expect(el.getAttribute("label")).toBe("Signing you in…");                               // reflected attribute
expect(el.shadowRoot!.querySelector('[part="label"]')!.textContent).toBe("Signing you in…"); // shadow part
// NOT: render(<Loading label="Signing you in…"/>) then assert the label — it won't reach the element in vitest
```

**Why a React-wrapper assertion can't pass in vitest (clarifies fix (a)): the wrapper's
prop-forwarding effect is compiled OUT under the `node` export condition.** `@lit/react`'s
`createComponent` forwards reactive props to the element in a `useLayoutEffect` (its `NODE_MODE`
build). Under vitest/jsdom, `@lit/react` resolves its package's **`node`** export condition, whose
build **skips that property-forwarding effect** — so `render(<Loading label="…"/>)` then asserting
the rendered label **cannot pass in vitest even with `reflect: true`**: the prop simply never reaches
the element. This is an **environment artifact, not a component bug** (it works in a real browser).
So `reflect: true` is necessary for attribute-based consumption, but it does **not** make the
`<Wrapper prop>` render under the wrapper in vitest — assert the contract on the **raw element**
(set the property directly, then check the reflected attribute + the rendered `::part`).

(Learned adopting [`@jeswr/solid-elements`](https://github.com/jeswr/solid-elements) across the vite
pod-apps, 2026-06-17 — a `Loading` label set via the `@lit/react` wrapper was dropped under React 19
and the spinner showed the generic fallback; reflecting the prop / using the raw element + DOM
attribute fixed it. The vitest `node`-condition caveat came from the same pod-mail/pod-money safe-form
back-port — a React-wrapper label assertion couldn't pass under vitest's `NODE_MODE` build no matter
what, until the test was rewritten to drive the raw element + assert the reflected attribute/part.)

## A shared chrome library that isolates COLOR but not the BOX MODEL: keep host element rules SCOPED

A shared React/WC chrome library (like [`@jeswr/app-shell`](https://github.com/jeswr/app-shell)) may
isolate its controls' **color / border / fill** via an unlayered attribute-scoped reset
(`[data-app-shell-control]`, see the Tailwind-v4 section above) + private design tokens — but
deliberately leave the **box model** (padding / border-radius / font-size) to its own *layered*
utility classes, so consumers can size things. The consequence on the consuming side: a consumer
app's **bare unlayered global `button {}`** that sets box-model props will still out-rank the
library's *layered* sizing (unlayered beats layered) and **distort the shared controls** — squashed
padding, wrong radius — even though their color survives. The reset isolates color, not the box model.

**Fix — on the CONSUMER: keep host element base rules SCOPED, and only globally relax what the reset
actually covers.** Scope your global element rules so they don't reach the library's controls (a
container class, or excluding the controls' marker attribute), and reserve any *global* element rule
for the parts the reset owns (e.g. re-aliasing a design token), not the box model the library lays
out:

```css
/* WRONG: a bare unlayered global rule out-ranks the library's layered sizing and squashes its controls */
button { padding: 4px 8px; border-radius: 2px; font-size: 13px; }

/* RIGHT: scope host element rules so the shared controls are left to size themselves */
.login-form button { padding: 4px 8px; border-radius: 2px; }      /* container-scoped */
button:where(:not([data-app-shell-control])) { padding: 4px 8px; } /* or exclude the controls — :where() keeps it (0,0,1) */
```

**The exclusion-selector trap (important): wrap the `:not()` in `:where()`, never use a bare
`:not([attr])`.** A bare `:not([data-app-shell-control])` **leaks the attribute selector's
specificity through `:not()`** — it raises the rule from a plain element's `(0,0,1)` to `(0,1,1)`.
That now out-ranks your own *class-only* host-button overrides (`.foo-link`, `.foo-cancel`, the
transparent/outline buttons at `(0,1,0)`) and **repaints them with the base look** — a real visual
regression, not a near-miss. `:where(:not(…))` carries **zero** specificity, so the base stays
`(0,0,1)` — identical to a bare `button {}` — your class-only overrides win again, and the library's
controls are still excluded. Guard it at source: a test that rejects **both** the unscoped global
form and the bare-`:not()` form.

```css
/* WRONG too: a bare :not([attr]) leaks specificity → (0,1,1), out-ranks your own .foo-link/.foo-cancel (0,1,0) */
button:not([data-app-shell-control]) { … }
/* RIGHT: :where() zeroes it → (0,0,1), your class-only overrides still win */
button:where(:not([data-app-shell-control])) { … }
```

The rule of thumb: **a chrome library can isolate color cheaply (a reset re-asserts a few literal
visuals) but cannot defend its box model without owning your layout** — so the box model stays a
shared contract, and the consumer keeps its global element styling off the library's controls (and
keeps that global rule at element specificity via `:where()`).

(Learned adopting [`@jeswr/solid-elements`](https://github.com/jeswr/solid-elements) across the vite
pod-apps, 2026-06-17 — `@jeswr/app-shell`'s reset isolated the controls' color but not their box
model, so a consuming app's unlayered global `button {}` distorted the shared controls until the
host's element rules were scoped. The `:where()`-vs-bare-`:not()` specificity-leak refinement came
from the pod-mail/pod-money back-port of that safe form, where the bare `button:not([…])` exclusion
was reviewer-flagged Medium for raising the base button to `(0,1,1)` and silently repainting the
apps' own class-only link/cancel buttons; pod-docs landed the `:where(:not(…))` fix.)

## Consuming `@jeswr/app-shell` on a Tailwind-v4 app while keeping YOUR OWN palette

`@jeswr/app-shell` ships its own suite theme tokens (the `--as-*` design tokens above). An app
that has its **own** brand palette doesn't want the suite colours — it wants the shell's *chrome*
(`ThemeProvider`/`ThemeToggle`, `AccountMenu`, `FeedbackButton`) to render in **its** colours.
The recipe that worked across the portfolio apps, without forking the shell:

- **Alias the shell-private `--as-*` tokens onto the app's own palette**, declared on **both**
  `:root` and `.dark` so the shell's controls track your light/dark scheme. You re-point the
  shell's private literals at *your* values rather than adopting its defaults:

  ```css
  :root      { --as-accent: var(--my-brand-600); --as-bg: var(--my-bg);  --as-fg: var(--my-fg); }
  .dark      { --as-accent: var(--my-brand-400); --as-bg: var(--my-bg-dark); --as-fg: var(--my-fg-dark); }
  ```

- **Register the `as-*` keys in your Tailwind v4 `@theme` + make the `dark:` variant CLASS-driven**
  so your utility classes can reference the same tokens and the shell's `ThemeProvider` (which toggles
  the `.dark` **class**, see the isomorphic-layout-effect section) drives both the shell's chrome and
  your app's dark variants from one switch. In Tailwind v4's CSS-first setup the `dark:` variant is
  **media-driven by default** — you must opt into class-driven dark mode with the CSS-native
  `@custom-variant` (otherwise `dark:` utilities ignore the `.dark` class the shell toggles, so your
  app and the shell's chrome disagree on dark mode):

  ```css
  /* CSS-first (v4-native): register the tokens AND make `dark:` follow the `.dark` class */
  @custom-variant dark (&:where(.dark, .dark *));
  @theme {
    --color-as-accent: var(--as-accent);
    --color-as-bg: var(--as-bg);
    --color-as-fg: var(--as-fg);
  }
  ```

  (If your project drives Tailwind from a JS config instead, set `darkMode: "class"` there and load
  it via `@config "../tailwind.config.js";` — a bare JS config is **not** picked up automatically in
  v4's CSS-first mode, so the `dark:` variant would silently stay media-driven.)

- **Import ONLY the shell's reset, not its suite theme tokens.** Pull in the unlayered
  attribute-scoped reset (`[data-app-shell-control]`) that keeps the controls immune to your global
  CSS — but do **not** import the shell's suite-palette token sheet, or it re-declares `--as-*` with
  the suite colours and overrides your aliases. Import the reset stylesheet; alias the tokens
  yourself. (The shell exposes the reset separately precisely so a consumer can keep its own palette.)

The mental model: `@jeswr/app-shell` is the *theme-truth + RDF/stateful home* and the
`--as-*` tokens are its **public theming seam** — a consumer keeps its own look by **re-pointing
that seam at its palette** (`:root`/`.dark` aliases + the Tailwind theme keys + `darkMode:'class'`),
taking the shell's reset for control-isolation but not its colour values. This pairs with the
Tailwind-v4 defensive-reset section above (that's the library defending its controls; this is the
consumer steering the controls to its own colours through the same token seam).

(Learned in the @jeswr money-making-portfolio build — AccessRadar/Keystone/CapNote/Provena/Furlong,
2026-06: consuming `@jeswr/app-shell` on Tailwind-v4 apps that each kept a distinct brand palette by
aliasing the `--as-*` seam onto their own colours rather than adopting the suite theme.)

## Gotchas

| Gotcha | Detail |
|---|---|
| Interaction hangs until the pod answers | The write is blocking — update local state first, persist async, never `await` before the UI updates |
| Editor breaks on the empty string mid-edit | A controlled input wired straight to a throwing typed setter (`@solid/object` `…As`) throws on every transiently-invalid keystroke — store the **raw** string in local state, never throw in `onChange`, validate the assembled draft separately, call the setter only at save with a valid value |
| Host app's `button {}` repaints your shell's controls | Tailwind v4: an **unlayered** author rule beats EVERY `@layer`'d utility — `@layer`/specificity bumps don't fix it. Ship an unlayered attribute-scoped reset (`[data-app-shell-control]{…}`, 0,1,0 > a bare element's 0,0,1 when both unlayered) + a **private literal** token mirror (`--as-accent`, not `var(--accent)` indirection) declared on a `:root`/shared ancestor so portaled menus/dialogs inherit it |
| Dark-OS user sees a one-frame light flash | A `ThemeProvider` resolving/applying the theme in a passive `useEffect` runs after paint, so `resolvedTheme` starts `light`. Apply in an **isomorphic layout effect** (`useLayoutEffect` in-browser, `useEffect` off-browser via a `typeof window` guard) — correct on the first painted frame, SSR-safe; a pre-hydration class-toggling `<script>` doesn't fix React state |
| Web-Component prop dropped via the React wrapper | `@lit/react` `createComponent` classifies props before the Lit class finalizes, so a non-reflected reactive **property** is silently dropped under React 19 — the element renders its fallback (e.g. `Loading` shows generic "Loading"). Make the prop `reflect: true`, or consume the raw element with a DOM **attribute** (`<jeswr-loading label="…">`) |
| `@lit/react` prop won't render in a vitest test | `@lit/react` resolves its **`node`** export condition under vitest/jsdom, whose build SKIPS the `useLayoutEffect` that forwards props — so a React-wrapper assertion (`render(<Loading label/>)` then check the label) **can't pass even with `reflect: true`**; it's an env artifact, not a bug. Test the **raw element**: set the property directly, then assert the reflected attribute + the rendered `::part`, not the wrapper |
| Host `button {}` distorts the shared controls' SIZE | A chrome library's reset isolates **color/border/fill** but leaves the **box model** to its own layered classes — so a consumer's bare unlayered global `button {}` still out-ranks that layered sizing and squashes the shared controls. Scope host element rules (`.login-form button`), or exclude the controls with `button:where(:not([data-app-shell-control]))`; only globally relax what the reset covers, never the box model |
| Bare `:not([attr])` exclusion repaints your OWN buttons | The exclusion-selector trap: `button:not([data-app-shell-control])` **leaks the attribute's specificity through `:not()`** → `(0,1,1)`, out-ranking your class-only host overrides (`.foo-link`/`.foo-cancel` at `(0,1,0)`) and repainting them with the base look. Wrap it: `button:where(:not([…]))` carries **zero** specificity → stays `(0,0,1)`. Guard with a test rejecting BOTH the unscoped and the bare-`:not()` form |
| App shows the SUITE palette instead of its own | To consume `@jeswr/app-shell` on a Tailwind-v4 app while keeping your own colours: **alias** the shell-private `--as-*` tokens onto your palette on **both `:root` and `.dark`**, register the `as-*` keys in `@theme` + set `darkMode: 'class'`, and import **only the shell's reset** — NOT its suite theme-token sheet (which re-declares `--as-*` with the suite colours and overrides your aliases). Re-point the token seam; don't fork the shell |
| `npm run build` bakes a localhost client-id | A prebuild config script doesn't get the bundler's `.env` loading — load `.env`/`.env.local` yourself via `node:util` `parseEnv`; a wrong client-id origin = broken login at the deployed subdomain |
| `.env.local` fails to fully override `.env` | Resolve the origin **per-layer** (`shell → .env.local → .env → default`, first layer that yields one wins), never merge into one dict + pick per-variable — that lets `.env` beat `.env.local` cross-variable |
| Forbidden container shows "empty" | A store `list()` swallowing 401/403→`[]` hides access-denied — wrap in a UI facade that surfaces a typed AccessDenied; clear stale list on a reload that 403s |
| View fetches an attacker's URL | Don't fetch every `ldp:contains` IRI — require http(s) + same-origin (parsed `origin`) + a real descendant `pathname` before fetching a child |
| A producer app's data shows under "Other" | A consumer must map EVERY producer's Type-Index `solid:forClass` IRI into its own category/view map (both `https`/`http` schema.org forms) — an unmapped class is still discovered but mis-bucketed into the fallback (cited: pod-docs' `pd:Document`); add the mapping + a regression test when you add a producer app |
| Concurrent edits lost on revert | Trap 1 — revert only the failed write's field(s) onto the **current** record, never replace the whole record with `original` |
| Newer move undone by an older failure | Trap 2 — capture the optimistic state / a mutation id and revert only if the current state still corresponds to the failed write |
| Spurious "Saving…" on a no-op drop | A move to the current column changes nothing — detect it (no `original`) and skip the write |
| Indicator clutters the UI | Hide when idle; auto-clear "Saved" back to idle after ~1.5 s; fixed-corner pill, `aria-live="polite"`, not a modal |
| Coupled server change missing after persist | Background-reconcile on success — the server may have changed a field your write didn't set |
| Last edit lost when the tab is closed mid-debounce | A debounced pod write whose timer hasn't fired is lost on tab-close/navigate/background. Flush on `pagehide` **and** `visibilitychange→hidden` (mobile-reliable) with `fetch(url,{keepalive:true})` so the request outlives the page; clear the pending marker only AFTER it resolves (keep it for retry) |
| `keepalive` flush rejects on a big body | `keepalive` has a hard ~64 KB encoded-body cap — over it the `fetch` rejects and the write silently never sends. Encode first, use `keepalive` only when it fits; an oversized snapshot falls back to a **normal** `fetch` (best-effort). `sendBeacon` has the same cap and can't carry the `If-Match`/`Content-Type` a pod PUT needs |
| Two keepalive PUTs of one snapshot blow the cap | `pagehide` + `visibilitychange` both fire for one teardown — single-flight the flush on the snapshot's version so one teardown = one request. But never coalesce a keepalive flush onto a non-keepalive in-flight save (the normal save is cancelled by the teardown; the keepalive flush must still run) |

---

*Learned building [`jeswr/solid-issues`](https://github.com/jeswr/solid-issues): the optimistic
board logic in [`src/lib/board.ts`](https://github.com/jeswr/solid-issues/blob/main/src/lib/board.ts)
(`optimisticMove`, `revertMoveIfCurrent` — both revert traps), the non-blocking `persist` in
[`src/lib/use-issues.ts`](https://github.com/jeswr/solid-issues/blob/main/src/lib/use-issues.ts),
and the [`src/components/save-indicator.tsx`](https://github.com/jeswr/solid-issues/blob/main/src/components/save-indicator.tsx)
pill, commit `ca0c687`. Both revert traps were roborev findings fixed in that change.*
