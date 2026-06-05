# `webid-token-provider.ts` — verification record

This is **verified** reference code, not a sketch. The provider was built into a real
Next.js + CSS app and driven through a full interactive OIDC login by a headless Playwright
test. It is the path the published `DPoPTokenProvider` (0.1.2) **cannot** complete against
local CSS — see the friction note at the end.

## What was tested

- **Harness:** `/tmp/solid-verify-app` — Next.js 16 app (port 3200) + Community Solid Server 7
  in-memory (port 3000), Playwright (chromium, headless), account+pod seeded by
  `e2e/global-setup.ts` (WebID `http://localhost:3000/alice/profile/card#me`, password
  `alice@example.com` / `test-password-123`).
- **Spec:** `e2e/webid-provider.spec.ts` —
  `WebID-driven DPoP login against local CSS: protected read succeeds`.
- **Wiring under test:** `src/lib/webid-auth.ts` constructs
  `new ReactiveFetchManager([ new WebIdDPoPTokenProvider(callbackUri, ui.getCode.bind(ui),
  () => promptWebIdDialog(...), { allowInsecureLoopback: true }) ])`, where `ui` is the
  published `<authorization-code-flow>` element. The provider file under test is identical to
  the shipped `webid-token-provider.ts` except the `./login-ux` import has no `.js` extension
  (Next's bundler does not rewrite `.js`→`.ts`; the shipped copy uses the ESM `.js` form, which
  is the form that strict-tsc-compiles against the published packages — also verified).

## What the test asserts (the real flow)

1. `/webid` renders; click **"Login with WebID"**.
2. The click fires a protected read of `http://localhost:3000/alice/my-app/notes.ttl`
   (confirmed **401** when unauthenticated — so reaching authenticated content *requires* the
   upgrade; a false pass is not possible).
3. The provider's `promptWebIdDialog` native `<dialog>` appears; the spec fills the seeded
   WebID and clicks **Continue**.
4. The provider dereferences the public profile (out-of-loop fetch — see fetch-recursion note),
   resolves the single `solid:oidcIssuer` (`http://localhost:3000/`), runs OIDC discovery +
   dynamic client registration + PKCE/DPoP with `allowInsecureRequests` enabled **because the
   issuer is loopback**, and calls `getCode`.
5. `<authorization-code-flow>` opens the OIDC popup. The provider sends `prompt=none` first; with
   no IdP cookie that popup fails fast and the element closes it, then the provider **retries
   without `prompt=none`** (silent-retry behaviour preserved from the published provider) and
   opens the interactive popup. The spec waits for the popup that actually shows the CSS login
   form, ignoring the transient one.
6. CSS login (`#email` / `#password` → "Log in") then consent (`/.account/oidc/consent/` →
   "Authorize"); `callback.html` `postMessage`s the code back.
7. The patched global `fetch` retries the protected read with a DPoP-bound token; the app renders
   `auth-status = "Authenticated read succeeded"` and the notes list. Both are asserted.

## Result

- `e2e/webid-provider.spec.ts`: **PASS**, including **3/3** under `--repeat-each=3` (stable, not
  flaky). Full suite **3 passed** (the two pre-existing `golden-path` tests still pass — no
  regression).
- `tsc --noEmit` (strict) over the app source incl. `webid-token-provider.ts`: **clean**.
- Strict `tsc --noEmit` of the **shipped** `webid-token-provider.ts` + `login-ux.ts` against the
  published packages (oauth4webapi 3.8.6, dpop 2.1.1, @solid/reactive-authentication 0.1.2,
  @jeswr/fetch-rdf 0.1.0, @solid/object 0.6.0, n3 2.0.3): **clean**.

## Versions / date

- Verified: **2026-06-05**.
- `@solid/reactive-authentication` 0.1.2, `oauth4webapi` 3.8.6, `dpop` 2.1.1,
  `@jeswr/fetch-rdf` 0.1.0, `@solid/object` 0.6.0, `n3` 2.0.3.
- Community Solid Server 7 (in-memory, default config), Next.js 16.2.7,
  `@playwright/test` 1.60.0 (chromium), Node v25.

## Key decisions / friction

- **Fetch recursion (solved):** `ReactiveFetchManager` snapshots `globalThis.fetch` at
  construction and calls *that* (not the providers) for actual network I/O — but `upgrade()` runs
  *after* the global is patched, so reading the profile through the patched global could re-enter
  the reactive loop on a 401. The provider snapshots `globalThis.fetch` in its **constructor**
  (before `new ReactiveFetchManager(...)` patches it) and uses that snapshot for the public
  profile read via `@jeswr/fetch-rdf`'s `fetch` option. A public profile won't 401 anyway, but
  this keeps the read provably out of the loop regardless of access-control surprises.
- **`allowInsecureLoopback` (the whole point):** the provider threads oauth4webapi's
  `allowInsecureRequests` symbol into every oauth4webapi call **only** when the issuer host is
  `localhost`/`127.0.0.1`/`[::1]`. This is exactly what the published 0.1.2 lacks (its
  `DPoPTokenProvider` never sets the flag), which is why interactive login against an HTTP local
  CSS issuer fails there with `OperationProcessingError: only requests to HTTPS are allowed`.
  With the flag under app control, the popup login **works** against local CSS — verified above.
- **`TokenProvider` type not re-exported:** 0.1.2's package entrypoint exports the concrete
  providers but not the `TokenProvider` interface. The shipped file restates the (tiny, stable)
  structural contract locally; `ReactiveFetchManager` accepts it structurally.
- **Issuer ambiguity:** the default `chooseIssuer` returns the single issuer and **throws**
  `AmbiguousIssuerError` on more than one — never silently first. Apps pass their own
  `chooseIssuer` to surface a picker.
- **No published-package bug blocked the build.** The only honest workaround is the loopback
  flag, which is a deliberate feature, not a patch around a defect.
