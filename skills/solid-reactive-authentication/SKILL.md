---
name: solid-reactive-authentication
description: >-
  Use when implementing Solid login — importing @solid/reactive-authentication, mounting <authorization-code-flow>, designing the WebID entry / identity-provider selection UX, integrating Solid-OIDC's mandatory DPoP into an auth framework that has none (Auth.js / next-auth v5 / @auth/core via the customFetch seam), or debugging 'Unknown issuer' or auth-after-reload behaviour. Documents the published 0.1.x API: not in context7, and the repo demos track unreleased APIs.
---

# @solid/reactive-authentication — auth via a patched fetch

Mental model first (companion guide: [`AGENTS.md`](https://github.com/jeswr/solid-ai-coding/blob/main/AGENTS.md) §Authentication): there is
**no session object and no authenticated-fetch wrapper**. `ReactiveFetchManager` patches
`globalThis.fetch` when you call `registerGlobally()` (the constructor alone does **not** patch
it in 0.1.3); afterwards every plain `fetch()` (including inside `@jeswr/fetch-rdf`) transparently
upgrades on `401` — find a matching provider, attach a DPoP-bound token, retry.

```sh
npm install @solid/reactive-authentication   # deps oauth4webapi + dpop come with it
```

Pure ESM, browser-only (custom elements, popups). In Next.js, import it **client-side only** —
the unguarded top-level `customElements.define` breaks `next build` otherwise; the mounting
recipe is in `AGENTS.md` §Mounting in Next.js.

## Published API (v0.1.2 — trust this over repo demos)

```ts
import {
  ReactiveFetchManager,          // new ReactiveFetchManager(providers: Iterable<TokenProvider>)
  DPoPTokenProvider,             // new DPoPTokenProvider(callbackUri, getCodeCallback) — 2 args
  BearerTokenProvider,           // demo-grade
  ClientCredentialsTokenProvider,// server-to-server (clientId, clientSecret)
  AuthorizationCodeFlow,         // the <authorization-code-flow> element class
  ReactiveFetchWorkerManager,    // service-worker variant — not production-ready in 0.1.x
  CodeRequestCancelledError, ReactiveFetchError,
} from "@solid/reactive-authentication";
import type { GetCodeCallback } from "@solid/reactive-authentication";
// GetCodeCallback = (authorizationUri: URL, signal: AbortSignal) => Promise<string>
```

Setup (full version with typing notes in `AGENTS.md`):

```ts
const ui = document.querySelector<AuthorizationCodeFlow>("authorization-code-flow")!;
const manager = new ReactiveFetchManager([
  new DPoPTokenProvider(new URL("/callback.html", location.href).toString(), ui.getCode.bind(ui)),
]);
manager.registerGlobally(); // 0.1.3: the constructor does NOT patch globalThis.fetch — this does
```

`/callback.html` (in `public/` for Next.js) contains the line
`<script>opener.postMessage(location.href)</script>`.

**Do not write code against** `IdpPicker`, `issuerFrom`, `GetIssuerCallback`, a 3-argument
`DPoPTokenProvider`, `registerElements`, or `AuthorizationCodeFlowUI` — these appear in the
repo/demos but are **not in the published 0.1.2**.

## Issuer resolution today

The published provider resolves the OIDC issuer **internally** from the resource URL's host:
`localhost:3000`, `*.solidcommunity.net`, `storage.inrupt.com` (PodSpaces), `*.solidweb.org`,
`*.solidweb.app`, `teamid.live`, `datapod.igrant.io`. Any other host **throws `Unknown
issuer`** — that error means the pod's host is outside the built-in map, not that your code is
wrong. A configurable issuer callback exists upstream and is expected in the next release.

⚠️ **Local CSS login is broken in 0.1.2** despite `localhost:3000` being on the list: the
issuer is hard-coded as `http://localhost:3000` and `oauth4webapi` refuses non-HTTPS issuers
(`OperationProcessingError: only requests to HTTPS are allowed`) with no app-level
`allowInsecureRequests` hook — and HTTPS-ing CSS doesn't help because the issuer URL is fixed.
Test interactive login against solidcommunity.net; use client-credentials DPoP tokens from the
CSS account API for local authenticated test traffic.

## Sessions, reloads, silent re-auth

Tokens live **in memory only**. A hard reload drops them; the next `401` re-runs the flow with
`prompt=none` first, so while the IdP cookie session lives, re-auth completes silently (no
popup). Prefer client-side navigation so the page (and its tokens) survive between views — and do
not roll your own *access*-token cache (it expires fast and the in-memory + `prompt=none` path
already covers in-session recovery).

### Reload-restore: persist the DPoP refresh token, restore via a refresh grant

`prompt=none` only restores silently **while the IdP cookie session is still alive**. For genuine
session *restore* — closing the tab (without logging out) and reopening later, after the IdP cookie
has expired or in a browser that drops third-party/IdP cookies (Safari ITP, privacy modes) — that
path fails and the user is bounced to login, which feels broken. The fix (a suite-wide UX invariant,
learned across prod-solid-server + jeswr/solid-pod-manager) is to persist the **DPoP-bound refresh
token**, not the access token, and restore from it on load:

- On login, store the **refresh token** in **IndexedDB**, keyed/scoped to the **WebID** (never
  `localStorage` — it is synchronous, size-capped, and readable by any same-origin script). The
  refresh token is DPoP-**bound**, so a leaked copy is useless without the matching private key.
- **Persist the matching DPoP key too — this is mandatory, not optional.** A DPoP-bound refresh
  token can only be redeemed with the **same DPoP key** it was bound to; if the private key is
  memory-only it dies with the tab and reload-restore fails (`invalid_dpop_proof`). Store the key as
  a **non-extractable `CryptoKey`** (`crypto.subtle.generateKey(..., /*extractable*/ false, ...)`)
  in the same IndexedDB store, scoped with the refresh token — IndexedDB can structured-clone a
  non-extractable `CryptoKey`, so the private-key bytes never become readable by script. Generate
  the keypair once, reuse it for the original grant and every later refresh, and delete it with the
  refresh token on logout. (If you instead rely on the library/provider to hold the token, it must
  supply stable key persistence before this pattern works at all.)
- On load, before showing a login screen, attempt a silent **refresh-grant fetch** (an
  `oauth4webapi` refresh-token grant with a fresh DPoP proof) to mint new tokens — **no redirect, no
  hidden iframe.** Show a brief "restoring…" state; fall back to interactive login only on a genuine
  refresh failure (revoked/expired refresh token). Land back on the actual page, not the home screen.
- **Clear the persisted refresh token on logout** (and on a hard refresh failure), and keep it
  scoped per WebID so switching accounts can't cross the streams.
- Schedule a **proactive** refresh before access-token expiry (and re-check on `visibilitychange`
  resume) rather than waiting for a `401` — see the proactive-refresh testing subsection above for
  how to test that deterministically.

This is what upstream issue [reactive-authentication#15](https://github.com/solid-contrib/reactive-authentication/issues/15)
("optional `SessionStore` so reloads restore via a refresh grant") tracks. Until the library ships
it, **don't hand-roll the store per app** — use the shared, audited package below. (Cited:
prod-solid-server auth architecture + the Pod-Manager / suite "silent session restore on load" UX
invariant, jeswr/solid-pod-manager.)

### Silent session restore is a SHARED, AUDITED package — not a per-app copy

The reload-restore mechanics above are **easy to get subtly, silently wrong** (a missed guard
leaks a credential across accounts, or a logout race re-authenticates the just-logged-out user),
so the security invariants belong in tests at **one** package boundary, not re-derived in every
app. That package is **[`@jeswr/solid-session-restore`](https://github.com/jeswr/solid-session-restore)**
(`npm install github:jeswr/solid-session-restore#main` — committed `dist/`, ESM). It owns three
things and apps do **thin wiring only**, never their own crypto/persistence:

```ts
import {
  IndexedDbSessionStore,   // WebID-scoped IndexedDB: { refresh_token + non-extractable DPoP CryptoKeyPair }, keyed by ISSUER
  restoreSession,          // the DPoP-bound refresh_token grant (real oauth4webapi grant + fresh DPoP proof)
  decideSilentRestore,     // a PURE fail-closed decision: given inputs → restore | login(reason)
  webIdsEqual,             // normalising WebID compare (trailing-slash / fragment / host-case)
  shouldDropRememberedPointer, // WebID-aware pointer reconciliation (see below)
  isInvalidGrantError,     // distinguishes a dead refresh token (→ login) from a transient failure (→ keep)
  forgetPersisted, clearPersisted,
} from "@jeswr/solid-session-restore";
```

The package's value is that the invariants are **tested at the boundary, adversarially** — each
guard's test verifies it genuinely FAILS when the guard is removed, then restores it.

**DPoP key extractability — the sharp one (RFC 9449 §4.2), it bit two apps and survived multiple
reviews.** A DPoP-bound refresh token is only redeemable with the **same DPoP key**, so the key
must persist — but persist it *correctly*:

- The DPoP keypair's **PRIVATE** key must be **non-extractable** (never durably store an
  exfiltratable private key). The **PUBLIC** key must be **`extractable: true`** —
  `oauth4webapi`/`dpop` serialise the public key into the DPoP proof header's JWK, so a
  `publicKey.extractable === false` throws `"key is not extractable"` and breaks proof generation
  (→ silent restore silently broken).
- For the **popup-login** key persisted directly in IndexedDB, this is automatic:
  `crypto.subtle.generateKey({ ...alg }, /*extractable*/ false, ["sign","verify"])` already yields
  a **non-extractable private + an always-extractable public** half, and IndexedDB
  structured-clones the non-extractable `CryptoKey` so the private bytes never become script-readable.
  (This is exactly what `@jeswr/solid-session-restore`'s `IndexedDbSessionStore` persists.)
- The **full-page-redirect** path is the trap: it must EXPORT the key (`extractable: true`) to
  survive the navigation via `sessionStorage`, then RE-IMPORT it on return — and the re-import MUST
  be **private `false` / public `true`**, NOT both `true`. Leaving the private key extractable after
  re-import is a hygiene regression (an exfiltratable private key in memory).
- **Test it:** the persisted/re-imported **public** key `exportKey`s to a JWK; the **private** key's
  `exportKey` **rejects**.

**The thin-wiring adoption recipe (each line is a hard-won guard):**

- **Request `offline_access`** on ALL interactive login paths — popup AND redirect — or there is no
  refresh token to persist.
- **Confirm-then-persist.** Persist the refresh credential only AFTER a fail-closed
  `webIdsEqual(authenticatedWebId, requestedWebId)` match. Persist-before-match leaks a credential
  into the wrong account's store.
- **`webid-mismatch` teardown ORDER:** `reset()` → `forgetPersisted` → clear pointer. (Tear the live
  session down before deleting the durable credential before clearing the public pointer.)
- **Generation-fence the store wrapper.** A logout racing the grant must not be undone by the
  package's internal rotated-token write-back — fence the store so a write for a superseded
  generation is dropped (same epoch discipline as the `reset()` rule below).
- **Logout = single-flighted + ordered + AWAITED:** `reset()` → invalidate the restore latch →
  **await** the durable delete → publish logged-out UI. Never fire-and-forget the delete.
- **Pointer (localStorage) writes/clears are best-effort/guarded, but durable `forgetPersisted` runs
  INDEPENDENTLY** — a pointer-clear throw must not skip credential cleanup.
- **Persist the credential BEFORE publishing the logged-in UI** (symmetric with logout's
  delete-before-publish) — else a tab closed in the race window misses the persist and restore fails.
- **WebID-AWARE pointer reconciliation (`shouldDropRememberedPointer`).** The store is keyed by
  **ISSUER**, so a "present" credential on a SHARED issuer may belong to a PRIOR account on that
  issuer — require the stored WebID `webIdsEqual` the requested one before trusting it. On a transient
  store-read failure, write THIS login's pointer; never blind-keep a possibly-stale one.

**Test pattern (lesson, applies to your wiring too):** drive the **real** package `restoreSession`
over a **stubbed `fetch`/transport** — do NOT mock `oauth4webapi`, which would hide the grant and
the DPoP proof entirely. Make every guard **adversarial**: assert it FAILS with the guard removed,
then restore it. (Cited: `@jeswr/solid-session-restore` — `IndexedDbSessionStore` persists the
non-extractable DPoP keypair, `restoreSession.test.ts` drives the real refresh grant over a stubbed
transport; validated across the 7 vite pod-apps + the package extraction from the pod-mail pilot.)

### Token-endpoint client auth: EXACT-host gates + a FAIL-CLOSED auth-method selection

Two security rules for any code that picks how a confidential client authenticates to the token
endpoint (the ESS `client_secret_basic` workaround, or `buildClientAuth` / `#clientAuth` in the
reference provider). Both are **fail-closed** rules — get them wrong and you mis-route a secret or
silently send no auth at all.

- **Match the issuer host EXACTLY — `new URL(issuer).hostname === "login.inrupt.com"`, never a
  substring `issuer.includes("login.inrupt.com")`.** A substring match is **spoofable** by a sibling
  or sub-path host: `https://login.inrupt.com.attacker.example`,
  `https://evil.example/login.inrupt.com/oidc`, `https://login.inrupt.com.example.com` all *contain*
  the substring, so a bespoke per-vendor workaround (here, the ESS non-URL-encoded Basic credential)
  would be sent to the **wrong server** — leaking a confidential `client_secret` in a non-standard
  header to an attacker-controlled OP. Parse the URL and compare `.hostname`; an unparseable issuer →
  `false` (never apply a vendor path to an unknown issuer). Trailing slash / path are then harmless
  (`https://login.inrupt.com/oidc` still matches on host), and the lookalikes above cannot.
- **Select the auth method FAIL-CLOSED — never silently downgrade to `none`.** A naive
  `if (method === "client_secret_basic") {…} else None()` treats EVERY unrecognised
  `token_endpoint_auth_method` as a public client, so a confidential client declaring
  `client_secret_jwt` / `private_key_jwt` / `tls_client_auth` is silently mis-authenticated — and on a
  server that *also* accepts public clients, succeeds-as-public when the user intended confidential
  auth. Instead: **THROW** on (a) a defined-but-unsupported method, and (b) a confidential method
  declared with no (or empty) secret. Two subtleties:
  - The OIDC/RFC-6749-§2.3.1 default for an **OMITTED** method is **`client_secret_basic` when a
    secret is present, `none` when it is not** — not unconditionally `none`. So a confidential client
    that omits the method must still present its secret (Basic), not silently drop it.
  - A **PRESENT-but-invalid** value (e.g. `null` from malformed/untrusted metadata) must NOT be
    coalesced to the omitted default — compare **`=== undefined`**, never `?? "none"`. `null ?? "none"`
    would accept a public path for a value that should fail closed. Apply the omitted-default only when
    the field is genuinely `undefined`; any other present value falls through to the unsupported-method
    guard and throws.

Cited — the cross-app security-parity rollout (2026-06): the hardened `buildClientAuth` /
`isEssNoUrlEncodeIssuer` / `isSupportedTokenEndpointAuthMethod` shipped in the pod-* apps'
`webid-token-provider.ts` (+ adversarial `webid-client-auth.test.ts`, which asserts the spoofed host
gets the SPEC encoder and that an unsupported method throws) and `@jeswr/solid-session-restore`'s
fail-closed `buildClientAuth`. The reference `webid-token-provider.ts` here carries the same hardened
helpers, with `webid-token-provider.test.ts` porting both the exact-host-spoof and fail-closed-method
cases.

### Deep-link autologin (`#autologin/<webid>` on load) — full-page redirect, enforce the WebID

A "send someone a link that logs them straight in as a known WebID" affordance (the pattern in
[media-kraken#54](https://github.com/NoelDeMartin/media-kraken/issues/54)) — an `#autologin/<webid>`
URL fragment that, on load, kicks off a Solid-OIDC login for that WebID — has a small set of
load-bearing constraints (learned wiring the Pod-suite apps, 2026-06):

- **Full-page redirect, not a popup.** A popup auto-opened on load has **no user gesture**, so the
  browser's popup blocker kills it — the autologin silently never starts. Drive the login as a
  **full-page** Solid-OIDC authorization redirect instead (the user *did* click the deep link, but
  that gesture is on the previous page and does not carry to the auto-open). Register **both**
  `${origin}/callback.html` (the popup target used by interactive login) **and** `${origin}/` (the
  full-page redirect lands back on the app root) in the client-id document's `redirect_uris` — miss
  the root and the IdP rejects the redirect.
- **Persist the flow secrets across the redirect.** A full-page redirect tears down the page, so the
  DPoP keypair (exported as a JWK — the *same* key must sign the eventual token-exchange proof), the
  **PKCE verifier**, the OAuth **state**, and the **nonce** all have to survive in `sessionStorage`
  and be re-read on return. (`sessionStorage`, not `localStorage`: scoped to the tab, cleared when it
  closes.)
- **ENFORCE the requested WebID — fail-closed before writing any state.** On return, the
  authenticated WebID from the returned **ID token** MUST equal the WebID the deep link asked for —
  compare with a normalising `webIdsEqual` (trailing-slash / fragment / case-of-host differences are
  real). If they differ, **throw before any session or issuer state is written.** The trap: a user
  may already have a *live IdP cookie session for a different account*; without this guard the
  autologin happily logs them in as the wrong WebID, which is a silent identity-confusion bug. This
  is the same fail-closed-on-WebID-mismatch principle as the per-attempt-token check above, applied
  to the deep-link return.
- **`prompt=none` so it's silent-with-fallback.** Set `prompt=none` on the authorization request so
  an already-logged-in user is bounced through silently; an OIDC error return (`login_required`,
  `interaction_required`) is then the signal to fall back to the normal interactive login. **Validate
  the OAuth `state` on the error/abort return too**, before consuming the persisted record — not only
  on the success path.
- **Seed BOTH the session AND the issuer before publishing.** Write the resolved issuer alongside the
  session so a later silent upgrade / refresh reuses it rather than re-resolving from scratch.

(Learned wiring the Pod-suite apps, 2026-06.)

### Testing proactive refresh with fake timers

If you build a **proactive token-refresh** provider — one that schedules a refresh before
expiry rather than waiting for a `401` — testing it with vitest fake timers is racy (lesson
from a prod-solid-server consumer). A refresh cycle awaits real **WebCrypto** (oauth4webapi
DPoP-proof signing + ES256 sign/verify), which runs on the libuv threadpool and settles on the
**real** macrotask queue, not the fake clock — so draining with a fixed count of
`advanceTimersByTimeAsync(0)` rounds is non-deterministic (under load the crypto isn't done
when assertions run). Instead:

- Expose **observable seams** on the provider, both production no-ops (undefined unless
  injected): `onProactiveCycleStarted` at the top of the single cycle method *all* trigger
  paths funnel through (timer fire, backoff retry, visibility-resume), and
  `onProactiveCycleSettled` in a `finally` once refresh + persist + reschedule has settled.
- Count STARTED vs SETTLED and **wait on the settled seam, not a time budget**: positive
  assertions poll for the expected settled count; "nothing more happens" assertions drain
  until quiescent. Between checks, yield to a `setTimeout` captured *before* `useFakeTimers`
  so threadpool crypto can settle, bounded by a real wall-clock deadline (pre-captured
  `Date.now`) that throws with context on overrun. Reset counters per-test.
- **Pitfall:** count STARTED at the *provider* level, not in the timer wrapper — a
  resume-triggered cycle that bypasses the timer fires SETTLED without a matching STARTED, and
  `settle()` then wrongly treats an in-flight refresh as quiescent.

### Detecting login: prove a per-attempt token, never infer from an HTTP status

A tempting "did login succeed?" check is to probe a resource and read the status. **Every
status-based shortcut is wrong** (each was a real bug, found over three review rounds building
`create-solid-app`'s auth provider):

- **`401`/`403` ≠ definitive failure.** Treating only non-401/403 as success, then setting the
  session, is the first trap.
- **A public `2xx` ≠ success.** Once you reject 401/403, *any* 2xx authenticates — so probing a
  **public** resource (or a `/` fallback) returns 200 with **no token attached** and falsely marks
  the user logged in.
- **A sticky "session established" flag ≠ this attempt.** A provider-level boolean set the first
  time any `upgrade()` attached a token stays set forever — so a later attempt whose probe got a
  public 200 (after a prior rejected probe, or logout→re-login) is wrongly accepted.

The correct signal is **whether a token was attached to *this* login attempt's request**. Have the
token provider expose a **monotonic count** of tokens it has actually minted+attached (incremented
inside `upgrade()` only after the `Authorization`/`DPoP` headers are set); the UI snapshots the
count **before** the probe and reads it **after** — a strictly higher count proves an attachment
*during this attempt* (a prior session's attachments are already in the "before" baseline, so
nothing stale leaks in). Decision: `2xx + count increased → logged in`; `2xx + no increase →
public/not logged in`; `401/403 → rejected`; other → error. Keep the decision in a **pure,
dependency-free function** so it's unit-testable in isolation. (Learned: `jeswr/create-solid-app`,
3 roborev rounds.)

### Correlating the probe correctly — the re-wrap, CORS, and concurrency constraints

The per-attempt token count above tells you *whether* a token was minted; a standalone login shell
also has to correlate "the probe I just fired" with *this* `upgrade()` call inside a custom
`TokenProvider`. Four constraints make the obvious approaches wrong (each a real bug, driven to zero
roborev findings over four rounds building a login host shell — cited:
[`jeswr/pod-docs@283134b`](https://github.com/jeswr/pod-docs/commit/283134b),
[`jeswr/create-solid-app@adb85e6`](https://github.com/jeswr/create-solid-app/commit/adb85e6)):

- **The manager re-wraps the request — per-request side channels do not survive.** `ReactiveFetchManager`'s
  patched fetch does `new Request(input, init)` **before** calling `provider.upgrade(request)`. So a
  `WeakMap<Request, …>` keyed on object identity, or an expando/symbol property on the Request, is
  **dropped** by the copy — only `url` / `method` / `headers` survive. (Confirm at runtime:
  `new Request(orig) !== orig`.) Anything you need the provider to read must live on those three.
- **Don't tag the probe with a custom HEADER — it breaks cross-origin login.** A custom request header
  (`x-…-probe-id`) makes a cross-origin pod request "non-simple", so the browser sends a **CORS
  preflight** that many Solid pods reject — the probe fails before the 401/upgrade path ever runs, and
  login is broken in production. A fetch-mock test harness hides this entirely (no real preflight).
- **Correlate with an unforgeable URL FRAGMENT, and strip it from the DPoP `htu`.** A `#probe-<uuid>`
  fragment **survives** the re-wrap (it's on `.url`), is **never sent on the wire** (RFC 3986 §3.5 —
  client-side only, so no preflight), and an unrelated same-base-URL request can't carry it. **But**
  the `dpop` package uses its `htu` argument verbatim while a server computes `htu` from the
  query/fragment-stripped request URI (RFC 9449 §4.2) — so compute the DPoP `htu` from
  **scheme+authority+path only** (strip query *and* fragment), while keeping the full fragment-bearing
  URL for in-process correlation. Forget this and every probe fails `invalid_dpop_proof` on `htu`.
- **Single-flight `login()`, keyed on the requested WebID.** Without it a double-clicked or concurrent
  login opens overlapping probes that overwrite each other's correlation or duplicate popups. Share the
  one in-flight promise on a **same-WebID** re-entry; a **different-WebID** concurrent login must
  **reject cleanly** (never resolve as the wrong identity).

### `reset()` / logout must generation-fence ALL in-flight async — re-checked AFTER every await

Logout (and starting a new login) clears cached provider state, but async already in flight —
issuer resolution, the session `upgrade()`, `DPoP.generateProof()` — can settle **later** and write
`#issuer` / `#sessions` / `#authenticatedWebId` / the token count for a **stale** identity, silently
re-authenticating as the just-logged-out user. Fix: a monotonic **generation/epoch** that `reset()`
advances; every async op **captures the generation up front AND re-checks it immediately after each
await**, before mutating any provider state — a superseded op writes nothing (reject with a typed
reset error). The re-check must be **after** the await, not only before it (that's the half that bites
— a check before a 300 ms crypto await is stale by the time the await resolves). (Same commits.)

### StrictMode: idempotent global patch + a module-level popup holder

React StrictMode double-mounts, which breaks two login-shell assumptions:

- **`registerGlobally()` must be idempotent.** Capture the **pristine** `fetch` exactly once in a
  module-level singleton — a second mount must not snapshot the **already-patched** fetch as "pristine"
  (logout would then restore a patched fetch) and must not stack a second patch.
- **Read the `<authorization-code-flow>` element through a module-level holder updated on EVERY mount** —
  never close over the first mount's element. StrictMode immediately unmounts that first element, so a
  captured reference points at a dead node and the popup never opens. Update the holder in each mount's
  effect; the flow reads the current one.

### Cross-account DPoP-token leak: a per-login `globalThis.fetch` patch with NO teardown reuses the PREVIOUS account's token

The single sharpest auth bug found across the suite build: **constructing a fresh
`ReactiveFetchManager` (or a fresh provider) per login and calling `registerGlobally()` each time,
with no teardown, leaks one account's DPoP token to the next.** The patch stacks: after
**logout → re-login as a *different* WebID**, the new patch sits on top of (or re-uses a provider
that still holds) the **previous** account's session/token, so the *first* request as the new user
is upgraded-and-retried with the **prior** account's DPoP-bound credential — a cross-account
confidential-data leak (read or write to account B's pod with account A's token). It is invisible in
a single-account test and in any fetch-mock harness; it only surfaces on a real logout→switch.

This is the same family as the StrictMode "snapshot the pristine fetch once" rule and the
generation-fence below, but the failure here is **account isolation**, so the fix is a stricter
lifecycle than idempotency alone:

- **One singleton manager for the app's whole lifetime — never one per login.** Capture the
  **pristine** `globalThis.fetch` exactly once (module-level), and `registerGlobally()` exactly once;
  **keep the wrapper installed for the app's whole lifetime.** The wrapper is harmless without an
  armed session (with no live token it falls through to the pristine fetch), so the lifecycle is:
  *patch once, never restore-on-logout* — **logout clears/disarms the provider's SESSION STATE, not
  the fetch patch.** (Restoring the pristine fetch on logout is the *other* coherent design, but then
  the next login must explicitly, idempotently re-arm it — and that re-arm is the easy place to
  re-introduce the stacking bug, so prefer "patch stays, session state is what's torn down".) Do not
  `new ReactiveFetchManager(...)` + `registerGlobally()` again per login — that is what stacks patches
  and orphans the old provider's live token.
- **Rebuild the provider with CLEARED sessions on logout AND before each login.** A provider caches
  resolved issuer + minted sessions/tokens keyed by identity; reusing it across an account switch is
  exactly the leak. Tear it down (or `reset()` it to an empty session set) on logout, and again
  **before** starting a new login, so a login can never inherit a prior account's session — belt and
  braces, because the logout might have raced or been skipped.
- **Login-generation fence.** A monotonic login epoch that **logout AND a newer login both advance**;
  an in-flight login captures the epoch up front and re-checks it **after every await** (issuer
  resolution, the popup, the token exchange) — a superseded login writes **no** session/token and
  resolves to nothing, so a slow login-as-A cannot resurrect account A after the user has moved on to
  log in as B (or logged out). This is the same epoch discipline as `reset()`/logout below, applied to
  the *login* path specifically.
- **Ownership-guarded teardown via session-ids.** Stamp each session with a unique id at creation;
  teardown (logout, or a failed/superseded login's cleanup) revokes **only the session whose id it
  owns**. The trap it prevents: an **older** login's late error (or its `finally`) firing **after** a
  **newer** valid login has already established session B — an unguarded "clear the current session"
  teardown then revokes B, logging out the legitimately-logged-in newer user. Compare the id before
  revoking; an older owner that no longer owns the current session is a no-op.

The unifying rule: **the fetch patch and the provider's session state are app-lifetime singletons
whose ownership is fenced by a login epoch + per-session ids — never per-login objects.** Test it
adversarially with a **real account switch**: log in as A, do one authenticated read, log out, log
in as B, and assert B's first request carries **B's** token (or no token), never A's — and that an
artificially-delayed login-as-A completing after the switch establishes **nothing**. (Cited: the
@jeswr money-making-portfolio build — AccessRadar/Keystone/CapNote/Provena/Furlong, 2026-06.)

### Foreign-origin fetch — the global patch upgrades-and-retries, so capture native `fetch` BEFORE `registerGlobally()`

`registerGlobally()` **replaces `globalThis.fetch`** with a wrapper that, on a `401`, **re-issues
the request with the user's Solid DPoP/bearer credentials** when a token provider matches the
request's host. That is correct for the user's own pod — but **wrong and unsafe for THIRD-PARTY /
foreign origins**: a public WebID index, `matrix.org`, a Solid forum/Discourse, any non-pod public
API. The app must never risk attaching a pod credential to a foreign host, nor pay the wrapper's
extra unauthenticated round-trip. The trap (it bit the Pod Manager twice): **`credentials:"omit"`
alone does NOT prevent the upgrade-and-retry** — the wrapper acts at the **global-fetch layer,
above** the per-request `credentials` flag, so `fetch(url, { credentials: "omit" })` still goes
through the patched wrapper and can still trigger the 401→attach-token→retry path.

The fix: capture a snapshot of `globalThis.fetch` **before** `registerGlobally()` patches it, and
use that pristine reference (bound to the global, with `credentials:"omit"`) for every
foreign-origin request. Two equivalent capture strategies — use both, belt-and-braces; the
idempotent boot hook is the more robust:

- A **module-evaluation-time** snapshot in a module imported eagerly from the app root, so it
  evaluates **before** the session provider's runtime effect calls `registerGlobally()` (an ES
  module's top-level code runs the first time it is imported). Expose it as a `nativeFetch` const.
- An **idempotent `captureNativeFetch()` boot hook** (first-call-wins) invoked at the very top of
  the app root/layout, before the session provider mounts; consumers read it via a
  `getNativeFetch()` accessor. First-call-wins matters: a later call that happens to run *after*
  the patch can then never overwrite the good reference.

Both should resolve to the **same backing reference** — never two uncoordinated snapshots. The
runtime hazard this defeats is real and code-splitting makes it sharp: the patch is installed
inside a React `useEffect` in the session provider (after an async dynamic import), and a route
chunk that needs the native fetch (e.g. a community-feeds client) loads lazily **after** the
patch — so reading `globalThis.fetch` at that point would get the **patched** one.

This is the same "snapshot the pristine fetch once" reflex as the StrictMode singleton above, but
for a different reason (foreign-origin safety, not logout-restore). Cited: the Pod Manager's
unified `src/lib/native-fetch.ts` — a single captured reference backing both a `nativeFetch` const
and `captureNativeFetch()`/`getNativeFetch()` — used by the WebID people-search client AND the
community-feeds client ([`jeswr/solid-pod-manager`](https://github.com/jeswr/solid-pod-manager),
the native-fetch unification on `main`).

### Eliminating the per-resource 401-dance (proactive token attach)

The foreign-origin section above is the **don't-attach-across-the-boundary** half of the credential
boundary; this is the **DO-attach-eagerly-INSIDE-the-boundary** half. `ReactiveFetchManager` is
purely **reactive**: it fetches every resource **bare first** (no `Authorization`/`DPoP`), waits for
the resource server's `401`, finds a matching provider, upgrades, and **retries** — *per resource,
with no origin/storage cache of "this host needs auth"*. So every distinct URL pays a **wasted
unauthenticated round-trip**, and the cost **scales with resource count**: a container listing that
fans out to N private children does N extra 401s on top of the N real reads (the "401-dance"). On a
high-latency link this is the dominant cost of opening a data-heavy view.

The fix is to **proactively attach** the DPoP-bound token on the **first** request to an **allowed**
origin, instead of waiting for each resource's `401`. A shared `installProactiveAuthFetch` helper
patches `globalThis.fetch` so that a request to an allowed origin gets the token attached up front,
with **one bounded `401` re-upgrade** retained as a fallback (token rotated/expired mid-flight). This
collapses the N-extra-round-trips to **one** auth round-trip per storage root. (Cited: the
proactive-fetch rollout across the pod-mail/pod-money/pod-photos/pod-docs/pod-chat + Pod-Manager
suite, 2026-06; the helper now lives in
[`@jeswr/solid-elements/auth`](https://github.com/jeswr/solid-elements) as `installProactiveAuthFetch`.)

**The credential boundary is load-bearing security — get the allowed-origin set right.** Proactive
attach means the token goes on *before* any `401` tells you the host wants it, so the allow-set is the
only thing standing between your pod credential and a foreign host. Rules (fail-closed throughout):

- **`https:` origins only.** A loopback **`http:`** origin (local CSS dev/test) is allowed **only**
  under an explicit dev/test opt-in flag — never in a production build.
- **Empty allow-set ⇒ attach to NOTHING** (fail-closed). A misconfigured/empty set must not
  degrade to "attach everywhere"; it degrades to "attach nowhere" (back to the reactive path).
- **Resource-server origins ONLY — and the issuer is NOT one.** Derive the allowed origins from the
  authenticated identity, but restrict the set to **proven Solid resource origins**: the
  **pod-root/storage origin(s)**, plus the **WebID-document origin only when the WebID is served by the
  pod** (i.e. it IS a resource server). **Do NOT put the OIDC issuer origin in the proactive
  allow-set** — a pod *access* token has no audience at the issuer's token/JWKS endpoints, and
  attaching it there both leaks a resource credential to a non-resource origin and **collides with the
  `customFetch` rule below** (issuer HTTP must stay on the pristine, unpatched fetch). The issuer is
  reached only via the pinned `customFetch`, never via the proactive boundary.
- **Never a foreign origin.** A WebID index, `matrix.org`, a Discourse forum, any non-pod public API
  is **out of set** (this is the same boundary the foreign-origin section protects from the other
  direction).

**The `customFetch` re-entrancy pin — a gotcha that DEADLOCKS login.** When you patch the global
`fetch` to attach tokens, the OIDC machinery itself uses `fetch` to talk to the issuer (token
endpoint, JWKS). If those internal requests go through *your* patched fetch, they re-enter the
attach path — which needs a token it is in the middle of minting — and **login deadlocks**. So you
MUST pin `oauth4webapi`'s **`customFetch`** option (and any other internal OIDC HTTP) to the
**pristine, unpatched** `fetch` captured before `installProactiveAuthFetch` ran — the same pristine
reference the foreign-origin section captures. Add an **adversarial test** that drives a login with
the pin in place (passes) and **without** it (must hang/deadlock or fail) so the pin can't silently
regress.

> **The general principle (applies to ANY proactive global-`fetch` patch, not just the proactive-attach
> helper).** The moment your app monkey-patches `globalThis.fetch` to transparently attach Solid auth,
> the **OIDC library makes its own internal `fetch` calls** — discovery, JWKS, the token-endpoint
> exchange, the refresh grant — and if *those* go through the patched global, the wrapper wrongly
> intercepts the library's own bootstrap requests: it recurses into the attach path (needs a token it
> is mid-mint of → deadlock), or attaches a DPoP proof bound to the *wrong* `htu` (the issuer, not a
> resource). The fix is the same two-part reflex everywhere: (1) capture a **pristine reference to the
> original `fetch` BEFORE patching** (a module-load snapshot, the "MODULE_PRISTINE_FETCH" pattern), and
> (2) hand that pristine fetch to the auth library so its internal HTTP **bypasses the global patch** —
> for `oauth4webapi`-based libraries that is its **`customFetch`** option (exported as a `unique symbol`,
> used as `[customFetch]`; this is exactly the seam `@jeswr/auth-solid`'s `[customFetch]: dpopFetch` and
> `@jeswr/solid-openid-client`'s `[oidc.customFetch]` set). The token then only ever reaches a vetted
> **resource** origin, never the issuer's endpoints. *(Architectural variant — the same invariant, no
> `customFetch` needed.* The [Solid browser extension](https://github.com/jeswr/solid-browser-extension)
> hand-rolls its OIDC flow in the MV3 **service worker** (`jose` + raw `fetch`) and keeps the
> token-attaching path in a **separate realm** from the OIDC HTTP: the SW's
> [`service-worker.ts`](https://github.com/jeswr/solid-browser-extension/blob/main/src/background/service-worker.ts)
> documents the rule as `RE-ENTRANCY: discovery / token / refresh / profile fetches use the RAW fetch,
> never the authenticatedFetch path`, while the popup's `MODULE_PRISTINE_FETCH` snapshot — captured at
> module load *before* anything could patch the global — backs its credential-free public/foreign-origin
> reads. Whether you pin `customFetch` or segregate by realm, the invariant is identical: **the auth
> library's own bootstrap HTTP must run on a fetch that is NOT your token-attaching wrapper.*)

**The armed-then-fail FAIL-OPEN gap — a real roborev-HIGH.** A wiring fault can throw **after** the
boundary has been armed AND the token pinned, but **before** the UI commits to logged-in. That
leaves the *provider able to authenticate* (boundary armed, token live) while the *UI falls back to
logged-out* — a fail-OPEN split: the app looks logged out but the patched fetch still attaches the
credential. So on **every** failure path — interactive login, autologin teardown, and the
silent-restore **wiring-fault `catch`** — you must **FAIL-CLOSED**: `provider.reset()` **and** clear
the boundary (disarm + unpin), not merely return to the login screen. Treat "armed boundary + no
committed session" as an invariant violation and tear both down together.

**Ordering — persist the credential BEFORE publishing the logged-in UI (b7p).** Symmetric with the
logout delete-before-publish rule: a tab closed in the persist race window must not miss the durable
write. **Note which providers persist internally during `upgrade()`** — if the provider already wrote
the DPoP credential to durable storage as part of `upgrade()`, the ordering constraint is *already*
satisfied and an extra explicit persist is redundant; if it does not, persist explicitly before you
publish. Document the provider's behaviour rather than assuming.

**Per-app deltas to CHECK (each bit the proactive-fetch rollout):**

- **`resolvedIssuer()` (and the resolved pod/storage origin) shape varies.** Some providers expose the
  resolved value as a **sync string**, others as an **async `URL`** — the allow-set derivation (which
  reads the provider/profile to find the **pod-root/storage** origins, NOT to add the issuer) has to
  handle both; a hard-coded `.then`/`await` on the wrong one throws (and a missing storage origin
  silently shrinks the allow-set, re-introducing the 401-dance).
- **Where silent-restore lives changes the wiring.** If silent-restore runs **inline as a
  `SessionProvider` callback**, arm the boundary inline at the same point. If it's a **module-level
  function**, you must **thread `armBoundary` / `clearBoundary` closures** into it — it has no access
  to the provider's arming hooks otherwise, and forgetting this leaves restore green but the boundary
  un-armed (back to reactive).
- **`@jeswr/solid-elements/auth` STATICALLY imports `@jeswr/solid-session-restore`.** That dependency
  is therefore **required at install/build time even for an app that does not use session-restore** —
  importing `/auth` for `installProactiveAuthFetch` alone still drags it in. Either install it, or (in
  a bundler-constrained app) vendor only the boundary helpers (see the import-vs-vendor tradeoff below).
- **Namespace-scheme seed gotcha.** A data layer pinned to a specific namespace **scheme** — e.g.
  `https://schema.org/` (vs `http://schema.org/`), or a w3id / Activity Streams namespace — means e2e
  **seed RDF must use the EXACT scheme**, or the resources **parse fine but never match** the query and
  the view comes up empty (and a 401-budget test seeded this way can pass *vacuously* — see below).

**Import vs. vendor (the consolidated tradeoff).** The vite pod-apps **import** `@jeswr/solid-elements/auth`
cleanly and get `installProactiveAuthFetch` (plus the static `@jeswr/solid-session-restore` dep) for
free. **PM / Next.js VENDORED** the dependency-free boundary helpers instead, because importing
`/auth` dragged a **duplicate `@solid/reactive-authentication`** into the Next.js bundle (the helper's
transitive dep collided with the app's own copy). The boundary logic itself has no runtime deps, so a
small vendored copy is a legitimate escape hatch where the import bloats or duplicates the bundle —
keep it byte-for-byte equivalent to the package and note the upstream source so it can be re-synced.

#### The 401-budget Playwright test — assert the dance is gone AND can't creep back

A regression guard for the 401-dance has to prove **two** things: (a) at most one resource-server
`401` per storage root, and (b) the 401 count **does NOT scale with resource count** (the actual
regression — a reactive fallback re-introduces a per-resource 401 that an N=1 fixture would never
catch). Pattern:

- **Intercept RESPONSES** (not requests) and **tally `401`s whose URL is under the resource-server /
  storage root** — bucket per storage root. (Tally responses so you count what the *server* actually
  challenged, not what the client attempted.)
- **Seed N private resources and assert N is plural** (e.g. N ≥ 3 across more than one storage root),
  then assert `401s-per-root ≤ 1` **and** that the total does not grow with N. An N=1 fixture makes
  the "doesn't scale" half un-testable.
- **Assert the seeded resources are actually private first** (an anon `GET` → `401`/`403`), so the
  budget guard **cannot pass vacuously** — if the seed RDF didn't match (the namespace-scheme gotcha
  above) or the resources were public, a "0 unexpected 401s" result is meaningless.
- **Run against a LOCAL CSS and PIN the exact version** (e.g. `@solid/community-server@7.1.9`) — CSS's
  challenge behaviour (when it emits `401` + `WWW-Authenticate`) shifts across versions, so an unpinned
  CSS makes the budget non-deterministic.
- **A non-completing login is a HARD failure**, not a skip — a login that silently never finishes
  would let the test pass with zero authenticated reads (and thus zero 401s) vacuously. Make "logged
  in" an assertion; allow an explicit, opt-in skip only.

(Cited: the 401-budget guard added across the pod-mail/pod-money/pod-photos/pod-docs/pod-chat
e2e suites + Pod-Manager, 2026-06.)

### A dynamic-import-defined custom element is not upgraded at first mount — never eager-bind its methods

When the `<authorization-code-flow>` element's **defining module** (`@solid/reactive-authentication`,
whose top-level `customElements.define("authorization-code-flow", …)` upgrades the element) is
**code-split behind a dynamic `import()`** — the right thing to do in Next.js / a host shell, so the
auth chunk doesn't block the bundle — then on a **cold first mount** `define(…)` has not run yet, the
element is **not upgraded**, and `ui.getCode` is `undefined`. So `ui.getCode.bind(ui)` (or any eager
read of `.getCode`) at mount time **throws** and breaks first-load login. A fetch-mock test harness
hides this completely — there's no real dynamic import to race. Fix: publish a **lazy accessor** to the
holder — `(...args) => ui.getCode(...args)` reads the method at **call** time (login time, after the
import has resolved and the element is upgraded), preserving the element as `this`. As belt-and-braces
for a very-early login racing the import, `await customElements.whenDefined("authorization-code-flow")`
before the call if `ui.getCode` is still not a function (`whenDefined` resolves immediately once
registered). **Never access `.getCode` at mount** — only at call time. (Cited:
[`jeswr/pod-docs@6e589ca`](https://github.com/jeswr/pod-docs/commit/6e589ca).)

## Letting users pick their Solid server — behaviour spec + tested code

How should login *feel*? The reference behaviour comes from the Solid browser extension
([theodi/solid-browser-extension](https://github.com/theodi/solid-browser-extension)), which
implements the same reactive model. Two layers of **tested reference code** are bundled with
this skill:

1. **[`webid-token-provider.ts`](./webid-token-provider.ts)** — `WebIdDPoPTokenProvider`, a
   complete custom `TokenProvider` (a port of the published `DPoPTokenProvider` flow) whose
   issuer comes from the user's WebID: `getWebId` callback (a native-`<dialog>` reference
   implementation `promptWebIdDialog` is included) → profile dereference → `solid:oidcIssuer`
   resolution → `chooseIssuer` when several (default **throws** `AmbiguousIssuerError`, never
   silently first). Its `allowInsecureLoopback` option also makes **interactive login against
   local CSS work** — the one thing the published provider cannot do. **E2E-verified**: a
   headless Playwright run drives the full popup login (WebID dialog → CSS login → consent →
   authenticated read) against a live local CSS, 3/3 stable — see
   [`webid-token-provider.e2e.md`](./webid-token-provider.e2e.md) for the verification record. Its
   token-endpoint client-authentication helpers (`buildClientAuth` / `isEssNoUrlEncodeIssuer` /
   `isSupportedTokenEndpointAuthMethod`) are exercised adversarially by the vitest suite
   [`webid-token-provider.test.ts`](./webid-token-provider.test.ts) (20 tests — the exact-host-spoof
   and fail-closed-auth-method cases; see the security section above).
   ```ts
   const manager = new ReactiveFetchManager([
     new WebIdDPoPTokenProvider(callbackUri, ui.getCode.bind(ui), promptWebIdDialog,
       { allowInsecureLoopback: true }),  // loopback-only; remote issuers stay HTTPS-strict
   ]);
   manager.registerGlobally(); // 0.1.3: required to patch globalThis.fetch
   ```
2. **[`login-ux.ts`](./login-ux.ts)** (vitest suite [`login-ux.test.ts`](./login-ux.test.ts),
   9 tests) — the UX helpers the provider composes with: `validateWebId`, `resolveIssuers`,
   `fetchLoginCandidate` (WebID → issuers + display name + avatar in one read), and
   `RecentAccounts` (most-recent-first, deduplicated, corruption-safe, remembers the chosen
   issuer and storage per account).

Copy both into `src/lib/` and build your UI on them. The behaviour to implement:

1. **WebID-first entry.** The login surface asks for one thing: the user's **WebID** (a URL
   input). No identity-provider dropdown, no server list — users know their WebID, not their
   IdP's OIDC URL.
2. **Recent accounts.** Remember previously used accounts as `{ webId, displayName, avatar }`,
   most recent first, de-duplicated by WebID. Returning users see avatar buttons (photo or
   initials) and tap one to re-login; an **"Add account"** affordance reveals the WebID input.
   Keep this list on logout (logout clears the session, not the account memory).
3. **WebID → issuer.** Dereference the WebID and read `solid:oidcIssuer` from the profile —
   through `@jeswr/fetch-rdf` + `WebIdDataset`, **never** by regex-scraping Turtle (a known
   fragility of the extension's first implementation: it misses prefixed and multi-line forms).
   - **No issuer** → actionable error: "This WebID can't be used for Solid login — its profile
     has no `solid:oidcIssuer`."
   - **Multiple issuers** → let the user choose; do not take the first.
4. **Run the flow.** Trigger the authorization-code flow against the chosen issuer (the
   `<authorization-code-flow>` popup handles user interaction). Validate errors into clear UI
   states: malformed WebID, unreachable profile, cancelled popup (`CodeRequestCancelledError`).
5. **After login.** Fetch the profile and render the account (name/avatar via the
   `ProfileAgent` reference class in the `solid-object` skill); append it to recent accounts.
6. **Storage selection.** When the profile advertises more than one `pim:storage`, **ask the
   user which storage to use** — never pick one silently. Remember the choice per account.

## Integrating Solid-OIDC DPoP into an auth framework (Auth.js / next-auth v5)

Everything above is the **reactive-fetch** model (a `globalThis.fetch` patch you own). The other
common case is an app built on an **auth framework that runs the OAuth/OIDC flow itself** — Auth.js
(next-auth v5 / `@auth/core`). Auth.js owns the authorization-code/callback orchestration and has
**no DPoP support**, but Solid-OIDC tokens are **mandatorily DPoP-bound (RFC 9449)** — so you can't
just point Auth.js at a Solid issuer. The worked reference for this is
[`@jeswr/auth-solid`](https://github.com/jeswr/auth-solid) (composes
[`@jeswr/solid-dpop`](https://github.com/jeswr/solid-dpop) for the proof primitives — no hand-rolled
crypto); the load-bearing constraints:

- **The seam is the provider's `customFetch` symbol.** Auth.js routes *all* OAuth endpoint HTTP
  (discovery, JWKS, token, userinfo) through the [`customFetch`](https://authjs.dev/reference/core#customfetch)
  override on the provider config. That is the single integration point: install a fetch that
  **discriminates the token-endpoint leg** (a POST with a form-urlencoded grant body) and attaches a
  DPoP proof to it, passing every other leg straight through. Don't try to bolt DPoP on anywhere
  else — Auth.js does the rest of the flow.
- **The token-endpoint proof carries NO `ath`.** `ath` (the access-token hash) only belongs on the
  **resource leg** (pod requests), where an access token is being *presented* — at the token
  endpoint there is no access token yet, so the proof binds only `htu`/`htm` (RFC 9449 §4.2).
  (This is the inverse of the common server-side `ath`-compat gotcha: clients must *omit* `ath` here,
  not add it.) Handle the RFC 9449 §8 **`use_dpop_nonce` 401 retry exactly once** (a single retry,
  not a loop) at the token endpoint — the OP may demand a server-chosen nonce on the first attempt.
- **Map ONLY the verified `webid` claim to the user.** Read the WebID from the **verified ID-token
  claims** the framework passes to `profile()` (oauth4webapi validates the ID-token signature +
  `iss`/`aud`/`nonce` first) — **fail-closed: a login with no resolvable `webid` throws.** Never
  trust a `webid` field from the *unverified* access token.
- **The DPoP keypair must persist across the auth-code → callback → refresh lifecycle — document the
  tradeoff.** Pod requests after login (and the DPoP-`jkt`-bound refresh-token redemption after a
  restart) need the **same** DPoP private key that minted the grant's proofs. One option is to store
  the DPoP private JWK in the **JWT session** alongside the tokens (`@jeswr/auth-solid`'s default):
  Auth.js encrypts the JWT (A256GCM) with `AUTH_SECRET`, so set a strong secret — the cost is JWT
  size and the key living in the session cookie/store. The alternative is a **server-side key store**
  (a database session row holding `dpopKeyJwk` + tokens). Either way it is secret material — never
  log it, never surface it to the client (expose only the WebID on the session).
- **The packaging gotcha — `@auth/core`'s `customFetch` named export only exists from `0.37.0`.**
  npm's `latest` dist-tag for `@auth/core` can lag (observed `0.34.3`), and that version does **not**
  export `customFetch` — a bare `npm install @auth/core` then breaks the import with
  `does not provide an export named 'customFetch'`. Pin a peer floor `>=0.37` (install
  `@auth/core@^0.37`), or install `next-auth@^5` (its bundled `@auth/core` is recent and re-exports
  `customFetch`).

(Cited: [`@jeswr/auth-solid`](https://github.com/jeswr/auth-solid) — `Solid(config)` returns an
Auth.js `OIDCConfig` with the DPoP-injecting `customFetch`; composes `@jeswr/solid-dpop` for the
RFC 9449 proofs; verified-WebID-only, fail-closed; ships a `solidDpopFetch` for authed pod requests
from the persisted session.)

## Gotchas

| Gotcha | Detail |
|---|---|
| Construct + `registerGlobally()` **once, early** | The constructor does NOT patch `globalThis.fetch` in 0.1.3 — `registerGlobally()` does; do it before any library captures a `fetch` reference, or those calls bypass auth |
| Untyped `querySelector` fails to compile | The library doesn't augment `HTMLElementTagNameMap` — use `querySelector<AuthorizationCodeFlow>(…)` |
| `Unknown issuer` | Host outside the 0.1.2 built-in map — see above |
| `only requests to HTTPS are allowed` on local login | The 0.1.2 HTTP-issuer wall — use the bundled `WebIdDPoPTokenProvider` with `allowInsecureLoopback: true` for local CSS |
| CSS-only auth failure `iat is not recent enough` | A *second* auth layer sending ms-unit DPoP `iat`; this library is correct — remove the other layer |
| Worker mode | `ReactiveFetchWorkerManager` registers a repo-relative worker path; treat as not production-ready in 0.1.x |
| Probe correlation lost in the provider | The manager does `new Request(input, init)` before `upgrade()` — a `WeakMap<Request>`/expando/symbol is dropped; only `url`/`method`/`headers` survive |
| Cross-origin login breaks (prod only, mock-green) | A custom probe **header** triggers a CORS preflight pods reject — correlate with a `#probe-<uuid>` URL **fragment** (never sent on the wire) instead |
| Every probe fails `invalid_dpop_proof` on `htu` | `dpop` uses `htu` verbatim but the server strips query+fragment (RFC 9449 §4.2) — compute `htu` from scheme+authority+path only; keep the fragment URL only for in-process correlation |
| Concurrent / double-click login | Single-flight `login()` keyed on requested WebID: same-WebID shares the in-flight promise; different-WebID must reject, never resolve as the wrong identity |
| Logout re-authenticates as the old user | In-flight async settles after `reset()` and writes stale identity — generation-fence: capture an epoch up front, re-check it **after every await** before mutating state |
| New login carries the PREVIOUS account's DPoP token (cross-account leak) | A fresh manager/provider + `registerGlobally()` **per login** with no teardown stacks the patch and reuses account A's session for account B's first request. Use **one app-lifetime singleton** (patch once; **logout clears the provider's session state, not the fetch patch** — the wrapper is harmless with no armed session), **rebuild the provider with cleared sessions on logout AND before each login**, **login-generation-fence** the login path, and revoke only the **session-id you own** so an older login's late error can't log out a newer valid session. Test with a real logout→login-as-different-WebID switch |
| StrictMode double-patches fetch / dead popup | `registerGlobally()` must snapshot the pristine fetch **once** (a singleton); read the `<authorization-code-flow>` element via a module-level holder updated every mount, not a closed-over first-mount ref |
| A foreign-origin fetch carries (or risks) the pod credential | The global patch upgrades-and-retries any `401` — **`credentials:"omit"` alone does NOT stop it** (the patch is above the per-request flag). Capture `globalThis.fetch` **before** `registerGlobally()` (eager module-eval snapshot + an idempotent first-wins `captureNativeFetch()` boot hook) and use that pristine ref for third-party hosts (WebID index / matrix.org / forum) |
| First-load login throws on `ui.getCode` (mock-green) | The auth element's defining module is dynamic-`import()`ed and not upgraded at cold first mount, so `.getCode` is `undefined` — publish a **lazy accessor** `(...a) => ui.getCode(...a)` (read at call time), not `ui.getCode.bind(ui)`; `await customElements.whenDefined(…)` as belt-and-braces |
| `#autologin/<webid>` deep link does nothing | A popup auto-opened on load has no user gesture and is blocked — use a **full-page** redirect; persist DPoP JWK + PKCE verifier + state + nonce to `sessionStorage` across it; register **both** `/callback.html` and `/` in the client-id `redirect_uris` |
| Deep-link autologin logs in as the WRONG WebID | A live IdP cookie session for another account satisfies `prompt=none` — **enforce** that the ID-token WebID `webIdsEqual` the requested one and **throw before writing any session/issuer state** on mismatch; validate `state` on the error/abort return too |
| Silent restore breaks with `"key is not extractable"` | The DPoP **public** key must be `extractable: true` (oauth4webapi serialises it into the proof JWK, RFC 9449 §4.2) while the **private** key stays non-extractable. `generateKey(…, false, …)` gets this right; the full-page-redirect export/re-import must re-import private `false` / public `true` (NOT both `true`). Test: public exports to JWK, private `exportKey` rejects |
| Hand-rolled per-app session restore | Use the shared, audited **[`@jeswr/solid-session-restore`](https://github.com/jeswr/solid-session-restore)** (WebID-scoped IndexedDB store + pure `decideSilentRestore` + DPoP-bound `restoreSession`) — apps do thin wiring (confirm-then-persist, ordered awaited logout, `shouldDropRememberedPointer` reconciliation), never their own crypto/persistence |
| Per-resource 401-dance (an extra round-trip per URL, scales with resource count) | `ReactiveFetchManager` is reactive (bare → `401` → upgrade → retry, **per resource, no origin cache**). Proactively attach the token on the **first** request to an **allowed** origin via `installProactiveAuthFetch` (`@jeswr/solid-elements/auth`), keeping one bounded `401` re-upgrade — collapses N extra round-trips to one auth round-trip per storage root |
| Proactive attach leaks a token to a foreign (or issuer) origin | The allow-set is the whole boundary (the token goes on before any `401`): **`https:`-only**, loopback-`http:` only under an explicit dev/test opt-in, **empty set ⇒ attach to nothing** (fail-closed), **resource origins only**. Derive it from the **pod-root/storage origin(s)** (+ the WebID-document origin only when the pod serves it) — **NOT the OIDC issuer origin** (a pod token has no audience there, and issuer HTTP must stay on the pinned `customFetch`) |
| Patching fetch to attach tokens DEADLOCKS login | Internal OIDC HTTP (token endpoint, JWKS) re-enters the attach path. Pin `oauth4webapi`'s **`customFetch`** (and any internal OIDC fetch) to the **pristine/unpatched** fetch captured before `installProactiveAuthFetch`. Add an adversarial test that hangs/fails **without** the pin |
| ANY proactive global-`fetch` patch lets the OIDC library's own calls recurse | The general rule behind the deadlock above: a wrapper that attaches auth to `globalThis.fetch` also intercepts the OIDC library's **own** discovery/JWKS/token/refresh fetches (→ recursion, or a DPoP proof bound to the issuer's `htu` not a resource). **Capture a PRISTINE `fetch` BEFORE patching** (module-load snapshot — the `MODULE_PRISTINE_FETCH` pattern) and route the library's internal HTTP through it: pin `oauth4webapi`'s **`customFetch`** (`unique symbol`, set as `[customFetch]` — see `@jeswr/auth-solid`/`@jeswr/solid-openid-client`), **or** keep the OIDC flow in a separate realm on the raw fetch (the [browser extension](https://github.com/jeswr/solid-browser-extension)'s SW: `discovery / token / refresh / profile fetches use the RAW fetch, never the authenticatedFetch path`). Invariant either way: the auth library's bootstrap HTTP must NOT run on your token-attaching wrapper |
| Armed boundary + logged-out UI (fail-OPEN split) | A wiring fault throwing **after** the boundary armed + token pinned leaves the provider able to authenticate while the UI shows logged-out. On **every** failure path (login, autologin teardown, silent-restore wiring-fault `catch`) **FAIL-CLOSED**: `provider.reset()` **and** clear the boundary, not just return to login |
| Resolved issuer/storage shape varies (sync string vs async URL) | The allow-set derivation reads the provider/profile for the **pod-root/storage** origins (NOT to add the issuer) and must handle both forms — a wrong `await`/`.then` throws, and a missing storage origin silently shrinks the allow-set back into the 401-dance |
| Silent-restore as a module fn can't arm the boundary | Inline `SessionProvider`-callback restore arms the boundary inline; a **module-level** restore fn must have `armBoundary`/`clearBoundary` **closures threaded in** — otherwise restore is green but the boundary stays un-armed (reactive) |
| `@jeswr/solid-elements/auth` drags in `@jeswr/solid-session-restore` | The `/auth` subexport **statically imports** session-restore — that dep is required even for an app that doesn't use restore. In a bundler-constrained app (Next.js), importing `/auth` can duplicate `@solid/reactive-authentication`; **vendoring** the dependency-free boundary helpers is the escape hatch (keep it byte-equal + note the source) |
| 401-budget test passes vacuously | Assert the seeded resources are actually private first (anon `GET` → `401`/`403`), seed **N ≥ plural** across >1 storage root and assert the 401 count **doesn't scale with N**, pin the exact local CSS version, and make a non-completing login a **hard** failure (opt-in skip only). Tally **responses** under the storage root. Watch the namespace-**scheme** seed gotcha (`https://` vs `http://` schema.org) — wrong scheme ⇒ resources parse but don't match ⇒ guard passes on an empty view |
| Spoofable ESS host gate (substring `includes`) | Keying a per-vendor token-endpoint workaround on `issuer.includes("login.inrupt.com")` sends the bespoke (non-URL-encoded Basic) `client_secret` to a lookalike host (`login.inrupt.com.attacker.example`, `evil.example/login.inrupt.com/…`). Match the **EXACT hostname** — `new URL(issuer).hostname === "login.inrupt.com"` (unparseable → `false`) — never a substring |
| Client-auth method silently downgraded to `none` | `if (method === "client_secret_basic") {…} else None()` mis-authenticates a confidential client that declares `client_secret_jwt`/`private_key_jwt`/`tls_client_auth` (and succeeds-as-public on servers that allow it). **FAIL CLOSED**: throw on an unsupported method and on a confidential method with no secret. OMITTED method defaults to `client_secret_basic` **iff** a secret is present (else `none`); a PRESENT-but-invalid value (`null`) must compare **`=== undefined`** (never `?? "none"`) so it fails closed, not coalesces to public |
| Auth.js (next-auth v5) can't talk to a Solid issuer | Auth.js runs the OAuth flow itself with **no DPoP**, but Solid-OIDC tokens are mandatorily DPoP-bound. Inject the RFC 9449 proof through the provider's **`customFetch`** seam (it routes all OAuth HTTP), discriminating the **token-endpoint leg** only. See the Auth.js section + [`@jeswr/auth-solid`](https://github.com/jeswr/auth-solid) |
| Token-endpoint DPoP proof has `ath` (wrong) | `ath` (access-token hash) belongs **only on the resource leg** (pod requests presenting a token). At the token endpoint there is no access token yet — the proof binds `htu`/`htm` only (RFC 9449 §4.2). Handle the §8 `use_dpop_nonce` retry **exactly once** there |
| `does not provide an export named 'customFetch'` | `@auth/core`'s `customFetch` is a named export only from **0.37.0**, but npm's `latest` can lag (observed `0.34.3`). Pin `@auth/core@^0.37` (peer floor `>=0.37`) or install `next-auth@^5` (recent bundled `@auth/core` re-exports it) |
