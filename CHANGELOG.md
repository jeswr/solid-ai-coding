# Changelog

## [Unreleased] - 2026-06-16 (5)

### Changed

- **`solid-reactive-authentication` skill** (+ `AGENTS.md` §Authentication) — new subsection + two
  gotchas: **silent session restore (DPoP refresh-token) is a SHARED, AUDITED package, not a per-app
  copy.** The reload-restore mechanics are easy to get subtly, silently wrong (a missed guard leaks a
  credential across accounts, or a logout race re-authenticates the just-logged-out user), so the
  security invariants belong in tests at ONE package boundary —
  **[`@jeswr/solid-session-restore`](https://github.com/jeswr/solid-session-restore)** (WebID-scoped
  IndexedDB DPoP refresh-token persistence + a PURE `decideSilentRestore` decision + a DPoP-bound
  `restoreSession` grant); apps do thin wiring only. Captures: (1) the package boundary +
  confirmed exports (`decideSilentRestore`, `restoreSession`, `webIdsEqual`, `shouldDropRememberedPointer`,
  `forgetPersisted`, `IndexedDbSessionStore`, `isInvalidGrantError`); (2) **the DPoP key-extractability
  sharp edge (RFC 9449 §4.2 — bit two apps, survived multiple reviews):** the DPoP PRIVATE key must be
  non-extractable but the PUBLIC key MUST be `extractable: true` (oauth4webapi serialises it into the
  proof JWK, so `publicKey.extractable === false` throws `"key is not extractable"` → silent restore
  silently broken); `generateKey(…, false, …)` gets the popup-key case right, the full-page-redirect
  export/re-import must re-import private `false` / public `true` (NOT both `true`); test = public
  exports to JWK, private `exportKey` rejects; (3) the thin-wiring adoption recipe (request
  `offline_access` on popup AND redirect; confirm-then-persist after `webIdsEqual`; `webid-mismatch`
  teardown order; generation-fenced store; single-flighted + ordered + AWAITED logout; pointer
  best-effort but durable `forgetPersisted` independent; persist-before-publish; WebID-aware pointer
  reconciliation); (4) the test pattern — drive the REAL package `restoreSession` over a STUBBED
  transport (never mock `oauth4webapi`), every guard adversarial (fails with the guard removed, then
  restored). Two new gotchas-table rows + one new rule in `AGENTS.md` §Authentication. (Cited:
  `@jeswr/solid-session-restore` — `IndexedDbSessionStore` persists the non-extractable DPoP keypair,
  `restoreSession.test.ts` drives the real refresh grant over a stubbed transport; validated across the
  7 vite pod-apps + the package extraction from the pod-mail pilot.)

## [Unreleased] - 2026-06-16 (4)

### Changed

- **`solid-reactive-authentication` skill** (+ `AGENTS.md` §Authentication) — new subsection + one
  gotcha: **foreign-origin fetch — capture native `fetch` BEFORE `registerGlobally()`.**
  `ReactiveFetchManager.registerGlobally()` REPLACES `globalThis.fetch` with a wrapper that, on a
  `401`, re-issues the request with the user's Solid DPoP/bearer credentials when a token provider
  matches the request's host — correct for the user's own pod, but wrong and unsafe for THIRD-PARTY
  origins (a public WebID index, `matrix.org`, a Solid forum/Discourse, any non-pod public API).
  THE TRAP (bit the Pod Manager twice): **`credentials:"omit"` alone does NOT prevent the
  upgrade-and-retry** — the wrapper acts at the global-fetch layer, ABOVE the per-request
  `credentials` flag. Fix: snapshot `globalThis.fetch` BEFORE the patch and use that pristine
  reference (with `credentials:"omit"`) for foreign origins — two equivalent capture strategies
  documented (an eager module-evaluation-time `nativeFetch` const, AND an idempotent first-wins
  `captureNativeFetch()` boot hook read via `getNativeFetch()`; the boot hook is the more robust).
  One new gotchas-table row + one new rule in `AGENTS.md` §Authentication. (Cited: the Pod Manager's
  unified `src/lib/native-fetch.ts`, used by the WebID people-search client and the community-feeds
  client — [`jeswr/solid-pod-manager`](https://github.com/jeswr/solid-pod-manager), the native-fetch
  unification on `main`.)

## [Unreleased] - 2026-06-16 (3)

### Changed

- **`solid-app-shell` skill** — new subsection + one gotcha: **cross-app data interop on a shared pod —
  a consumer must map EVERY producer's `solid:forClass` into its own categories/views.** Suite apps
  interoperate by reading/writing the SAME pod resources, discovered via the Type Index (a producer
  registers its container with `solid:instanceContainer` + its primary class via `solid:forClass`; a
  consumer — a pod manager/dashboard — discovers data by matching those `forClass` IRIs). THE TRAP: a
  consumer that hasn't mapped a producer's `forClass` IRI still DISCOVERS that data but drops it into a
  generic "uncategorised/other" bucket instead of the right view (a real finding: pod-docs' `pd:Document`
  showed under "Other data" until the Pod Manager added the class). So when adding a producer app: add
  its class(es) to the consumer's category map (both `https`/`http` schema.org forms) AND cover each with
  a regression test that asserts it resolves to the expected category, not the fallback. Also captures the
  interop-friendly resource shape that worked across all the suite apps (one-resource-per-item Turtle with
  a stable `#it`/fragment subject, standard vocabs — schema.org / ActivityStreams / domain ontologies —
  registered per-container in the Type Index). Cross-references the `solid-type-index` skill for the
  registration mechanics. (Cited: cross-app interop test 2026-06-16 across
  [`jeswr/pod-docs`](https://github.com/jeswr/pod-docs), [`jeswr/pod-chat`](https://github.com/jeswr/pod-chat),
  and the Pod Manager on one shared pod.)

## [Unreleased] - 2026-06-16 (2)

### Changed

- **`solid-reactive-authentication` skill** — new gotcha + subsection: **a custom element defined by a
  DYNAMIC `import()` is not upgraded at first mount, so don't eager-bind its methods.** When the auth
  `<authorization-code-flow>` element's defining module (`@solid/reactive-authentication`) is code-split
  behind a dynamic import, on a COLD first mount `customElements.define(…)` hasn't run yet → `ui.getCode`
  is `undefined` → `ui.getCode.bind(ui)` THROWS and breaks first-load login (a fetch-mock harness hides
  it). Fix: publish a LAZY accessor `(...args) => ui.getCode(...args)` that reads the method at CALL time
  (after the import resolves), with `await customElements.whenDefined("authorization-code-flow")` as
  belt-and-braces. Never access `.getCode` at mount. One new gotchas-table row. (Cited:
  [`jeswr/pod-docs@6e589ca`](https://github.com/jeswr/pod-docs/commit/6e589ca).)
- **`solid-app-shell` skill** — new subsection + two gotchas: **a prebuild config generator (e.g. the
  per-origin `clientid.jsonld` emitter) must load `.env`/`.env.local` itself and resolve precedence
  PER-LAYER.** A script that runs BEFORE Vite/the bundler doesn't get its `.env` loading, so reading only
  `process.env` makes a plain `npm run build` silently bake a localhost/dev origin into the production
  client-id document (whose served URL IS the `client_id` → broken login at the deployed subdomain). Load
  `.env` then `.env.local` via Node's built-in `util.parseEnv` (no dep; Node ≥ 20.12), and resolve the
  origin in strict priority `shell(non-empty) → .env.local → .env → dev-default`, each layer picking its
  OWN `APP_ORIGIN`/`VITE_APP_ORIGIN`, first layer that yields one wins — do NOT merge the files into one
  dict + pick per-variable (that lets a `.env` value beat a `.env.local` value of the OTHER variable, so
  `.env.local` fails to fully override `.env` cross-variable). Guard the file-writing `main()` behind a
  realpath `isInvokedDirectly()` check so the resolvers are unit-test-importable side-effect-free. (Cited:
  [`jeswr/pod-photos@bd490ac`](https://github.com/jeswr/pod-photos/commit/bd490ac),
  [`jeswr/pod-music@2c3dcb3`](https://github.com/jeswr/pod-music/commit/2c3dcb3).)

## [Unreleased] - 2026-06-16

### Changed

- **`solid-reactive-authentication` skill** — added a **"Correlating the probe correctly"** subsection
  (plus `reset()`/logout generation-fencing and StrictMode lifecycle subsections), capturing the
  concrete mechanism behind the existing "prove a per-attempt token, never an HTTP status" rule when
  building a **standalone login shell** over the WebID DPoP token provider. The four correlation
  constraints: (1) `ReactiveFetchManager` does `new Request(input, init)` before `upgrade()`, so a
  per-request `WeakMap`/expando/symbol side channel is dropped — only `url`/`method`/`headers` survive;
  (2) a custom probe **header** triggers a CORS preflight that pods reject (breaks cross-origin login in
  prod; fetch-mock hides it) — correlate with an unforgeable `#probe-<uuid>` URL **fragment** instead
  (never sent on the wire, RFC 3986 §3.5); (3) the `dpop` package uses `htu` verbatim but a server
  strips query+fragment (RFC 9449 §4.2), so compute the DPoP `htu` from scheme+authority+path only while
  keeping the fragment URL for in-process correlation; (4) single-flight `login()` keyed on the requested
  WebID (same-WebID shares the promise, different-WebID rejects, never resolves as the wrong identity).
  Plus: `reset()`/logout must **generation-fence** all in-flight async (capture an epoch up front,
  re-check **after every await** before mutating `#issuer`/`#sessions`/`#authenticatedWebId`/the token
  count — else a late settle re-auths the just-logged-out user); and StrictMode needs an idempotent
  `registerGlobally()` (snapshot pristine `fetch` once) + a module-level `<authorization-code-flow>`
  holder updated every mount (never a closed-over first-mount ref the double-mount kills). Eight new
  gotchas-table rows. (Learned driving a login host shell to zero roborev findings over four rounds:
  `jeswr/pod-docs@283134b`, `jeswr/create-solid-app@adb85e6`.)

## [Unreleased] - 2026-06-15 (6)

### Added

- **New `solid-offline` skill** — the offline / instant-load read pattern: hydrate the UI
  **synchronously** from a durable client cache on mount so the app paints instantly, then
  revalidate against the pod in the background (stale-while-revalidate); never show a blank/loading
  screen when a cache exists. Documents the **security** requirement that prevented a real HIGH:
  the cache MUST be scoped to the authenticated WebID — WebID in BOTH the storage key AND the
  stored envelope, hydrate only on an identity match (a missing/mismatched WebID is a MISS), clear
  on **account switch** as well as logout, and VERSION the envelope so a schema change can't
  resurrect un-scoped legacy entries (stops one signed-in user's private data painting for a
  different user on the same browser). Notes the eventual home is a service-worker read-through
  cache + `WebSocketChannel2023` invalidation (the `jeswr/solid-offline` package); the
  app-level `localStorage`/`IndexedDB` snapshot is the interim pattern. (Learned in
  `jeswr/solid-issues`: `src/lib/issue-cache.ts` + the WebID-scoped snapshot in
  `src/lib/use-issues.ts`, commit `ca0c687`.)
- **New `solid-app-shell` skill** — optimistic, non-blocking pod mutations: update the UI
  immediately (a kanban card slides to its new column), persist to the pod **asynchronously**
  without blocking the interaction, show a small non-intrusive "Saving…/Saved" indicator for
  in-flight writes, and on failure show an error + revert. Documents the two revert-correctness
  traps that were real review findings: (1) revert only the field(s) the failed write changed onto
  the CURRENT record (preserving concurrent edits to other fields), and (2) guard against a stale
  failed write clobbering a NEWER mutation of the same item (track a per-item optimistic
  state/mutation id; only revert if the current local state still corresponds to the failed
  mutation). The write-side companion to `solid-offline`. (Learned in `jeswr/solid-issues`:
  `src/lib/board.ts` `optimisticMove`/`revertMoveIfCurrent`, `src/components/save-indicator.tsx`,
  `src/lib/use-issues.ts` `persist`, commit `ca0c687`.)
- Registered both skills in the README skills table (now twelve), the AGENTS.md §Solid skills
  list, and the SETUP.md skill inventory.

## [Unreleased] - 2026-06-15 (5)

### Changed

- **`solid-reactive-authentication` skill** — added a **"Reload-restore: persist the DPoP refresh
  token, restore via a refresh grant"** subsection. The existing `prompt=none` advice only restores
  silently *while the IdP cookie session is alive*; for genuine session restore (reopen a closed tab
  after the cookie expired, or in Safari ITP / privacy modes that drop IdP cookies) it fails and
  bounces the user to login. The captured pattern: persist the **DPoP-bound refresh token** (not the
  access token) in **IndexedDB**, WebID-scoped, cleared on logout; on load attempt a silent
  **refresh-grant fetch** (no redirect, no iframe) with a brief "restoring…" state, falling back to
  interactive login only on genuine refresh failure; schedule proactive refresh before expiry. Notes
  this is what upstream `reactive-authentication#15` (optional `SessionStore`) tracks, and that a
  consumer holds the IndexedDB store until the library ships it. (Cited: prod-solid-server auth
  architecture + the Pod-Manager / suite "silent session restore on load" UX invariant,
  jeswr/solid-pod-manager.)

## [Unreleased] - 2026-06-15 (4)

### Changed

- **`solid-fetch-rdf` skill** — added a **"Receiver-side: trusting cross-pod claims (provenance)"**
  section: when an app consumes data *assigned/shared from other pods*, a foreign pod's claim ("this
  task is assigned to you", "you are a member") is **untrusted** — anyone who can write that pod can
  write that triple. Two-tier verify: own-pod data is trusted only when it is **owner-write-only**
  (a world-/group-appendable resource in your own pod — a public inbox — holds third-party bytes, so
  it is still foreign for trust); foreign-pod data is shown only when the asserting WebID is an
  authorised source (a `foaf:knows`
  contact) **and** the resource resides in that source's *own* advertised `pim:storage` (read from
  the source's profile) **and is owner-write-only there** (so a third party posting into the
  friend's public inbox cannot spoof a claim) — closing the confused-deputy gap where a third pod
  merely names a trusted friend. Fail closed on ambiguity; bound discovery to the authorised set; keep the pure trust
  decision separate from I/O so it is exhaustively unit-testable. Includes a code-shape sketch and a
  Gotchas row, with a note that provenance governs *who* may assign (not the network layer — DNS
  rebinding is a separate guard). (Learned building the Pod Manager assigned-to-me view,
  jeswr/solid-pod-manager.)

## [Unreleased] - 2026-06-15 (3)

### Fixed

- **Vendoring-safe `AGENTS.md` links (jeswr/solid-ai-coding#1).** Seven SKILL.md files linked the
  companion guide as `[AGENTS.md](../../AGENTS.md)`, which resolves inside this repo but breaks at
  the standard vendored path (`.agents/skills/<name>/`, where `../../` no longer reaches this
  repo's root). Rewrote them — and the two `solid-client-id` sibling-skill cross-references — to
  absolute GitHub URLs (`https://github.com/jeswr/solid-ai-coding/blob/main/…`) so the references
  survive vendoring. (Surfaced by a Copilot review during vendoring into prod-solid-server#64.)
- **`solid-test-infrastructure` `dev.mjs` — CSS-reuse detection no longer over-matches
  (jeswr/solid-ai-coding#1).** The reuse check inferred "a Community Solid Server is already up"
  from any `200` on `GET /`, so a stray `next dev` (default port 3000) false-positived and seeding
  then failed downstream with cryptic JSON/HTML errors. Now probes the CSS-specific account API
  (`GET /.account/`, `Accept: application/json`, require a JSON response — the same guard
  `global-setup.ts` already uses) and distinguishes css / occupied / free: reuse a genuine CSS,
  boot one when the port is free, and **fail fast with an `lsof` hint** when something non-CSS owns
  `:3000`. Removed the now-unused `up()` helper and documented the new probe in the SKILL.

## [Unreleased] - 2026-06-15 (2)

### Changed

- **`solid-test-infrastructure` skill** — added a **"PGlite-backed services — boot once per
  worker, reset between tests"** section: when testing a Postgres-backed Solid service with
  `@electric-sql/pglite` under vitest, booting `new PGlite()` per test costs ~1 s × N and
  thrashes CPU; instead boot one engine per vitest worker at module load and drop+recreate the
  schema (~80 ms) between tests via a shared `freshDb()` helper. Includes a code sketch.
  (Learned in jeswr/solid-webid-index: suite went from ~123 s wall-clock to ~16 s, ≈7.5×.)
  Also added a Gotchas table row summarising the anti-pattern.

## [Unreleased] - 2026-06-15

### Changed

- **`solid-fetch-rdf` skill** — added two receiver/server-side AS2 LDN lessons: (1) `parseRdf`
  rejects `application/activity+json` — normalise to `application/ld+json` before parsing (bytes
  are JSON-LD-compatible); (2) a JSON-LD `documentLoader` that fetches remote `@context` URLs is
  an SSRF + reliability hazard on the request path — bundle the AS2 context locally and refuse all
  remote fetches. (Learned building the LDN suggest-inbox in jeswr/solid-webid-index.)

## [Unreleased] - 2026-06-14

### Changed

- **`solid-server-matrix` skill** — added a **DPoP `ath` enforcement** row + footnote to the
  compatibility matrix: several deployed apps (Penny, Pod Drive, Tired Bike) send DPoP proofs
  without the RFC 9449 `ath` claim, so a strict resource server rejects their reads/writes while
  login still succeeds. (Lesson surfaced during prod-solid-server app-compatibility testing.)
- **`solid-notifications` skill** — documented the **ETag short-circuit**: a change notification's
  `state` field can carry the new resource ETag; comparing it against a cached ETag lets a client
  skip a redundant re-fetch (and makes a self-caused write echo free), falling back to an
  unconditional re-fetch when `state` is absent. (Lesson from the prod-solid-server notifications
  ↔ offline-cache integration, where the change frame carries the ETag in `state`.)
- **`solid-reactive-authentication` skill** — added a **"Testing proactive refresh with fake
  timers"** subsection: a proactive-refresh cycle awaits real WebCrypto that settles on the real
  macrotask queue (not vitest's fake clock), so tests must expose `onProactiveCycleStarted` /
  `onProactiveCycleSettled` seams and wait on settled-cycle counts (yielding to a pre-fake-capture
  `setTimeout`, bounded by a real wall-clock deadline) rather than a fixed time budget. (Lesson
  from a prod-solid-server consumer's `webid-token-provider` tests.)

## [Unreleased] - 2026-06-05

### Added

- **`setup-bob.js`** — New cross-platform Node.js setup script
  - Fully parallelized installation (completes in ~1-2 minutes vs 5-10 minutes)
  - Works identically on Windows, macOS, and Linux
  - Automatic VS Code reload after installation
  - Idempotent (safe to run multiple times)
  - No external dependencies (uses Node.js built-ins only)

- **CI testing** — GitHub Actions workflow (`.github/workflows/test-setup.yml`)
  - Tests on Ubuntu, macOS, and Windows
  - Tests on Node.js 18, 20, and 22
  - Verifies all files and skills are installed correctly
  - Tests script idempotency

- **`SETUP.md`** — Comprehensive setup script documentation
  - Usage instructions
  - Architecture details
  - Troubleshooting guide
  - Migration guide from bash scripts

### Changed

- **README.md** — Updated IBM Bob setup section
  - Emphasizes the new Node.js script as the recommended approach
  - Moved manual setup to a collapsed details section
  - Added feature list for the automated script

### Deprecated

- **`setup-bob.sh`** — Legacy bash script (still works but shows deprecation warning)
- **`install-skills.sh`** — Legacy bash script (still works but shows deprecation warning)

Both scripts now display a 5-second warning recommending the new `setup-bob.js` script before proceeding.

### Performance Improvements

- **10x faster setup** — Parallel execution reduces setup time from ~10 minutes to ~1-2 minutes
- All file downloads run concurrently
- All skill installations run concurrently
- No sequential bottlenecks

### Technical Details

#### Parallelization Strategy

The new script uses `Promise.all()` to run all tasks concurrently:

```javascript
const tasks = [
  // 3 file downloads
  downloadAndSaveFile(AGENTS.md),
  downloadAndSaveFile(CLAUDE.md),
  downloadAndSaveFile(mcp.json),
  
  // 11 skill installations
  installSkill('jeswr/solid-ai-coding'),
  installSkill('antfu/skills', 'vitest'),
  // ... 9 more skills
];

await Promise.all(tasks);
```

#### Cross-Platform Compatibility

- Uses Node.js built-in modules only (`child_process`, `fs/promises`, `path`, `https`)
- Shell commands use `shell: true` for Windows compatibility
- File paths use `path.join()` for correct separators on all platforms
- ANSI colors work on all modern terminals

#### CI Test Matrix

- **Platforms:** ubuntu-latest, macos-latest, windows-latest
- **Node versions:** 18, 20, 22
- **Total test combinations:** 9 (3 platforms × 3 Node versions)

### Migration Guide

If you previously used the bash scripts:

1. **Switch to the new script:**
   ```sh
   curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/setup-bob.js | node
   ```

2. **Benefits:**
   - 10x faster (1-2 minutes vs 10 minutes)
   - Works on Windows without WSL
   - Automatic VS Code reload
   - Better error handling and reporting

3. **No breaking changes:**
   - Installs the same files and skills
   - Same directory structure
   - Same end result

### Breaking Changes

None — the new script is fully backward compatible.

### Known Issues

None

### Contributors

- IBM Bob (AI coding agent)
- Jesse Wright (@jeswr) — Repository maintainer

---

## Previous Releases

See git history for changes before this release.