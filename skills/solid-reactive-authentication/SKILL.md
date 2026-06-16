---
name: solid-reactive-authentication
description: >-
  Use when implementing Solid login — importing @solid/reactive-authentication, mounting <authorization-code-flow>, designing the WebID entry / identity-provider selection UX, or debugging 'Unknown issuer' or auth-after-reload behaviour. Documents the published 0.1.x API: not in context7, and the repo demos track unreleased APIs.
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
("optional `SessionStore` so reloads restore via a refresh grant") tracks; until the library ships
it, a consumer holds the IndexedDB store itself. (Cited: prod-solid-server auth architecture +
the Pod-Manager / suite "silent session restore on load" UX invariant, jeswr/solid-pod-manager.)

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
   [`webid-token-provider.e2e.md`](./webid-token-provider.e2e.md) for the verification record.
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
| StrictMode double-patches fetch / dead popup | `registerGlobally()` must snapshot the pristine fetch **once** (a singleton); read the `<authorization-code-flow>` element via a module-level holder updated every mount, not a closed-over first-mount ref |
