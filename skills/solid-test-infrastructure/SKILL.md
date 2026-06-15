---
name: solid-test-infrastructure
description: >-
  Use when scaffolding a Solid app's test setup, writing its first e2e test, seeding CSS test
  accounts/pods, needing an authenticated fixture without driving the login popup, or when a
  Playwright suite against local CSS is flaky or won't start (port clash, globalSetup transpile
  errors, bare pod profiles). Bundles the execution-verified harness: two-webServer Playwright
  config + CSS account/pod/profile seeding via client-credentials DPoP.
---

# Solid test infrastructure — build it before the features

**The test infrastructure is part of the scaffold, not an afterthought.** Stand it up right
after `create-next-app`, before the first feature — then every feature lands with its tests,
and TDD is possible: write the failing test (unit or e2e), implement, go green, refactor.
(Install the `test-driven-development` skill from `obra/superpowers` for the discipline; this
skill is the Solid-specific machinery.)

Two layers, per [`AGENTS.md`](https://github.com/jeswr/solid-ai-coding/blob/main/AGENTS.md) Part 2 §Testing:

| Layer | Tool | Scope |
|---|---|---|
| Unit / integration | **Vitest** | `src/lib/` — the data layer; `fetch` injected as an **optional** param, omitted in production paths |
| End-to-end | **Playwright** | Golden paths against a **real local CSS** — login popup included; no mocks |

## The bundled harness (execution-verified)

Two files, lifted verbatim from the clean-room verification build that validated this guide —
they powered full popup-login e2e runs (3/3 stable) and authenticated write-path tests:

1. **[`playwright.config.ts`](./playwright.config.ts)** — the two-`webServer` pattern: one
   in-memory CSS@7 on `:3000` (it must own that port — the auth issuer map requires it) and the
   app on `:3200` (`next dev` would otherwise clash on 3000; **using another framework, swap
   that webServer command for your dev server on `:3200`** — the harness is framework-agnostic,
   as is `dev.mjs` via `APP_CMD`). One CSS instance per suite — startup is ~13s, so never
   per-test. `reuseExistingServer` keeps local iteration fast.
2. **[`global-setup.ts`](./global-setup.ts)** — runs once after the servers are up:
   - creates an account via the CSS account API (`POST /.account/account/` with `{}` — with a
     JSON content-type an empty body 500s), registers a password, creates the pod;
   - mints **client-credentials**, then exchanges them for a **DPoP-bound token** (jose-built
     proofs — note the `ath` claim on resource requests);
   - **seeds the profile** — a fresh CSS pod profile has no `foaf:name` and no `pim:storage`
     (so no display name and no write path); the setup PUTs them plus a photo.

3. **[`css-account.ts`](./css-account.ts)** — the per-test account fixture:
   `createCssAccount({ pod })` returns `{ webId, email, password, podRoot, token, proof }` with
   the bare profile seeded — fresh-account-per-write-test isolation without restarting CSS
   (compile-verified; same recipe as global-setup, packaged per call).

Copy what you need, adjust the constants (`POD`, `EMAIL`, `PASSWORD`), done. `jose` is the only
extra dev-dependency. Alternative to run-time profile seeding: start CSS with the **custom pod
templates** from this repo's `config/pod-templates/` (+ `config/css-memory-wac-templates.json`)
and every pod is born with `pim:storage` — see `docs/local-ops.md` for the verified mechanics
and the `--seedConfig` boot-time account seeding.

## The dev environment — seeded and ready to log in

`npm run dev` must give the developer a **testable** environment, not just a compiling app:
CSS running, accounts already seeded, and the **credentials printed where they can't be
missed**. The bundled [`dev.mjs`](./dev.mjs) (execution-verified) does exactly that — starts
in-memory CSS on `:3000`, seeds two accounts (alice/bob, profile names + `pim:storage`
included), prints a credentials banner (WebID / email / password / pod root per account), then
starts the app on `:3200`. Wire it as the dev script:

```json
{ "scripts": { "dev": "node scripts/dev.mjs" } }
```

`node scripts/dev.mjs --no-app` gives CSS + seeded accounts only — run it once in its own
terminal and leave it up: **CSS takes ~15 s to boot, so avoid restarting it**. The script
reuses a CSS already on `:3000` (tolerating existing accounts), so app restarts never pay the
CSS boot cost. It detects that reuse by probing the CSS-specific account API
(`GET /.account/` → JSON), **not** a bare `200` on `/` — so a stray `next dev` (whose default
port is also `3000`) won't be mistaken for CSS; if something non-CSS owns `:3000` the script
fails fast with an `lsof -i :3000` hint instead of seeding against the wrong server. For clean
state, prefer a fresh account (`createCssAccount`) over a restart.

## Patterns the harness enables

- **Authenticated fixtures without the popup**: the client-credentials DPoP token from
  global-setup reads/writes the pod directly — use it to arrange test data and to test the
  data layer against live CSS (fast, no browser). Interactive popup login stays in exactly one
  or two e2e specs.
- **401-gated assertions**: before asserting authenticated content, confirm the resource
  returns `401` unauthenticated — then a passing test *proves* the auth upgrade ran; a false
  pass is impossible.
- **Write isolation**: in-memory CSS resets on restart; for a pristine pod per suite, restart
  CSS. For write-heavy suites, `createCssAccount` (bundled) gives a fresh account + seeded
  profile + DPoP token per test — no shared-pod interference, no restart.
- **Popup flows**: capture the OIDC popup with `context.waitForEvent("page")`; CSS login is
  `#email` / `#password` → "Log in" → "Authorize". Ignore the transient `prompt=none` popup
  that closes itself before the interactive one opens.

## Per-feature loop (the actual instruction)

For every feature: **(1)** write the failing Vitest case against the data-layer contract
(mock `fetch` via the optional param), **(2)** implement until green, **(3)** extend — or
confirm coverage by — an e2e golden path. A feature without tests is not done. Don't
snapshot-test UI, don't test shadcn primitives, don't `sleep()` — auto-waits only.

[`feature.spec.example.ts`](./feature.spec.example.ts) is the per-feature e2e template —
distilled from a real Bob-built TODO app developed against this guide: login error-states
first (they're the executable form of the `solid-reactive-authentication` UX spec), a
`beforeEach` login, role/placeholder locators, empty-state → create → persist-across-reload.

## PGlite-backed services — boot once per worker, reset between tests

When testing a Postgres-backed Solid service with
[`@electric-sql/pglite`](https://github.com/electric-sql/pglite) (in-process WASM Postgres) under
vitest, **do NOT `new PGlite()` per test or per suite** — the WASM boot takes ~1 s each and
parallel boots thrash CPU, forcing long test timeouts and slow suites. Instead **boot one engine
per vitest worker and reset the schema (~80 ms) between tests** (drop + recreate or truncate).

In `jeswr/solid-webid-index` this cut the suite from ~683 s cumulative / ~123 s wall-clock to
~90 s / ~16 s (≈7.5×) and removed the need for inflated per-test timeouts.

**Pattern:**

```ts
// test/helpers/db.ts  (imported by every test file)
import { PGlite } from "@electric-sql/pglite";

// Kick off the WASM boot immediately at module load so it overlaps vitest's import phase.
const enginePromise = PGlite.create();

export async function freshDb(): Promise<PGlite> {
  const db = await enginePromise;
  // Drop and recreate the schema — ~80 ms vs ~1 s for a new engine.
  await db.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
  await runMigrations(db);   // your app's migration function
  return db;
}
```

```ts
// my-feature.test.ts
import { freshDb } from "./helpers/db.js";

let db: PGlite;
beforeEach(async () => { db = await freshDb(); });
// No afterAll close — the shared engine lives for the whole worker lifetime.
```

Rules:
- **Never `close()` the shared engine** mid-suite; it cannot be reopened.
- Route every test through one shared `freshDb()` / `freshTestStore()` helper — never call
  `PGlite.create()` directly in a test file.
- Each vitest worker gets its own engine (vitest isolates workers) so tests in different files
  run truly in parallel without contention.

## Gotchas

| Gotcha | Detail |
|---|---|
| `globalSetup` must be self-contained | Importing a sibling `.ts`/`.mjs` from it trips Playwright's config transpiler in a CJS-default project — inline everything |
| `node x.ts` strip-only mode | Rejects TS parameter properties — plain field assignments in files run directly with node |
| Port clash | CSS owns `:3000`; the app runs on `:3200` (see config comments) |
| Bare fresh profiles | Without the profile seed, `Agent.name` is `undefined` and `storageUrls` is empty — apps appear broken when it's just an unseeded pod |
| ETag from CSS | Present and stable — exercise the conditional-PUT (`If-Match`/`412`) path in tests; legacy NSS lacks it (see `solid-server-matrix`) |
| PGlite boot cost | `new PGlite()` per test is ~1 s × N tests; boot once per vitest worker + reset schema between tests instead (see section above) |
