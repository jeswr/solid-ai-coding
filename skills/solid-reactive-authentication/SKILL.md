---
name: solid-reactive-authentication
description: >-
  Use when implementing Solid login — importing @solid/reactive-authentication, mounting <authorization-code-flow>, designing the WebID entry / identity-provider selection UX, or debugging 'Unknown issuer' or auth-after-reload behaviour. Documents the published 0.1.x API: not in context7, and the repo demos track unreleased APIs.
---

# @solid/reactive-authentication — auth via a patched fetch

Mental model first (companion guide: [`AGENTS.md`](../../AGENTS.md) §Authentication): there is
**no session object and no authenticated-fetch wrapper**. `ReactiveFetchManager` patches
`globalThis.fetch` once at construction; afterwards every plain `fetch()` (including inside
`@jeswr/fetch-rdf`) transparently upgrades on `401` — find a matching provider, attach a
DPoP-bound token, retry.

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
new ReactiveFetchManager([
  new DPoPTokenProvider(new URL("/callback.html", location.href).toString(), ui.getCode.bind(ui)),
]);
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
popup). Do not build your own token persistence, and prefer client-side navigation so the page
(and its tokens) survive between views.

## Letting users pick their Solid server — behaviour specification

How should login *feel*? The reference behaviour comes from the Solid browser extension
([theodi/solid-browser-extension](https://github.com/theodi/solid-browser-extension)), which
implements the same reactive model. Implement this UX in your app's own UI (no library-specific
code prescribed — the published library resolves issuers internally today; wire your issuer
choice in when the configurable callback ships):

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
| Construct `ReactiveFetchManager` **once, early** | It patches the global; libraries that captured `fetch` earlier bypass auth |
| Untyped `querySelector` fails to compile | The library doesn't augment `HTMLElementTagNameMap` — use `querySelector<AuthorizationCodeFlow>(…)` |
| `Unknown issuer` | Host outside the 0.1.2 built-in map — see above |
| `only requests to HTTPS are allowed` on local login | The 0.1.2 HTTP-issuer wall — see above; interactive login needs an HTTPS issuer |
| CSS-only auth failure `iat is not recent enough` | A *second* auth layer sending ms-unit DPoP `iat`; this library is correct — remove the other layer |
| Worker mode | `ReactiveFetchWorkerManager` registers a repo-relative worker path; treat as not production-ready in 0.1.x |
