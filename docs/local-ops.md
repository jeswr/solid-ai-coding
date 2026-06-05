# Local Solid operations — CSS setup, seeding, auth, troubleshooting

The operational companion to `AGENTS.md` §Servers. Everything here is **execution-verified**
against `@solid/community-server@7` (June 2026). Architecture and library patterns live in
`AGENTS.md`; this doc is for making the local environment actually work.

## Quickstart

```sh
# WAC instance — default config is in-memory + WAC. CSS must own :3000 (auth issuer map).
npx @solid/community-server@7 -p 3000

# ACP instance (this repo ships the preset CSS lacks)
npx @solid/community-server@7 -p 3001 -c config/css-memory-acp.json

# the app dev server moves to another port — next dev defaults to :3000 and would clash
next dev -p 3200
```

Run in-memory (pristine on restart, no filesystem pollution); pin major 7 — the bare package
name resolves to an 8.0 alpha. Prefer `npm run dev` = the `dev.mjs` orchestrator from the
`solid-test-infrastructure` skill: CSS + seeded accounts + a printed credentials banner + app.

## Seeded accounts at boot — `--seedConfig`

CSS creates accounts + pods at startup from a JSON file
([docs](https://communitysolidserver.github.io/CommunitySolidServer/7.x/usage/seeding-pods/)):

```sh
npx @solid/community-server@7 -p 3000 --seedConfig config/css-seed-example.json
```

`config/css-seed-example.json` in this repo seeds alice + bob. Limitation: it sets email,
password, and pod — it does **not** put a display name in the profile, and the stock pod
template leaves the profile bare (next section).

## The bare-profile problem — two verified fixes

A pod created by stock CSS 7 has a profile containing only
`a foaf:Person; solid:oidcIssuer <…>` — **no `pim:storage`** (so apps following the
`pim:storage`-only discovery rule find no write path) and no `foaf:name`. Fix it one of two
ways:

### Option 1 — custom pod templates (config-time; the house pattern)

CSS generates pod resources from Handlebars templates. Stock
`templates/pod/base/profile/card$.ttl.hbs` omits `pim:storage`; this repo ships a verified
override in [`config/pod-templates/`](../config/pod-templates/) whose profile template adds
`pim:storage <{{base.path}}>` (available variables come from `PodSettings`: `base.path`,
`webId`, `name`, `email`, `oidcIssuer`). Every pod — seeded or user-registered — is then born
complete:

```sh
# templateFolder in the config is relative to your CWD — run from the repo root, or edit it
npx @solid/community-server@7 -p 3000 \
  -c config/css-memory-wac-templates.json --seedConfig config/css-seed-example.json
```

How the override works (Components.js): the shipped
[`config/css-memory-wac-templates.json`](../config/css-memory-wac-templates.json) is CSS's
`default.json` with the `css:config/identity/pod/static.json` import **removed**, and its three
nodes redefined in `@graph` — `PodManager` (`GeneratedPodManager`), `PodResourcesGenerator`
(`StaticFolderGenerator` pointing at the custom `templateFolder`), and
`TemplatedResourcesGenerator` (`SubfolderResourcesGenerator`, `subfolders: ["base", "wac"]`).
You cannot redefine an `@id` while the import that defines it is still present — exclude first,
then redefine. (Names like `TemplatedPodGenerator` or `urn:…:PodGenerator` do not exist —
AI-generated configs like to invent them.)

### Option 2 — client-credentials seeding (run-time; for fixtures and existing pods)

Mint client credentials via the account API, exchange for a DPoP-bound token, `PUT` the
completed profile. The `solid-test-infrastructure` skill ships this working twice over:
`global-setup.ts` (Playwright) and `dev.mjs` (dev environment, prints the credentials).
Verification: `curl -H "Accept: text/turtle" http://localhost:3000/<pod>/profile/card` shows
`pim:storage`.

## The account API (manual recipe)

`POST /.account/account/` with body `{}` (**an empty body 500s**; keep the cookie) →
`GET /.account/` for the control URLs → `POST <controls.password.create>` `{email, password}` →
`POST <controls.account.pod>` `{name}` → optionally
`POST <controls.account.clientCredentials>` `{name, webId}` for token credentials. The WebID is
`http://localhost:3000/<pod>/profile/card#me`.

## Local interactive login — the working drop-in

Published `@solid/reactive-authentication` 0.1.2 cannot complete interactive login against
local CSS (`only requests to HTTPS are allowed` — hard-coded `http://` issuer, no override).
The bundled `WebIdDPoPTokenProvider` (`solid-reactive-authentication` skill — copy
`webid-token-provider.ts` + `login-ux.ts` into `src/lib/`) is the e2e-verified fix:

```ts
import { WebIdDPoPTokenProvider, promptWebIdDialog } from "@/lib/webid-token-provider";
import { ReactiveFetchManager } from "@solid/reactive-authentication";
import type { AuthorizationCodeFlow } from "@solid/reactive-authentication";

const ui = document.querySelector<AuthorizationCodeFlow>("authorization-code-flow")!;
new ReactiveFetchManager([
  new WebIdDPoPTokenProvider(
    new URL("/callback.html", location.href).toString(),
    ui.getCode.bind(ui),
    promptWebIdDialog,                  // WebID-first entry dialog (or your own UI)
    { allowInsecureLoopback: true },    // loopback only; remote issuers stay HTTPS-strict
  ),
]);
```

For **non-interactive** auth (CI, seed scripts): client-credentials DPoP tokens (Option 2
above) — no browser involved.

## Troubleshooting local CSS

| Symptom | Diagnosis | Fix |
|---|---|---|
| Boot fails resolving a `css:config/...` import | The import doesn't exist in CSS 7 (often AI-invented) | Diff your imports against CSS's own `config/default.json` for your version |
| Boot fails: duplicate / conflicting component definition | You redefined an `@id` whose defining import is still present | Remove the stock import, then redefine (see Option 1) |
| `POST /.account/account/` → 500 `Unexpected end of JSON input` | Empty request body | Send `{}` with `content-type: application/json` |
| Profile loads but app finds no name / no write path | Bare fresh profile | Option 1 or Option 2 above |
| Login popup → `only requests to HTTPS are allowed` | 0.1.2 HTTP-issuer wall | `WebIdDPoPTokenProvider` + `allowInsecureLoopback` (above) |
| `Unknown issuer <url>` thrown on first authenticated fetch | Resource host outside the published provider's fixed map | Same fix — the bundled provider resolves issuers from the WebID instead |
| Auth works on PodSpaces, CSS rejects `iat is not recent enough` | A second auth layer sending ms-unit DPoP `iat` | Remove it; the sanctioned libraries send seconds |
| Writes 412 | Stale ETag — someone else wrote | Re-fetch, re-apply, re-PUT (`AGENTS.md` §Writing data) |
| Pod data vanished after restart | In-memory backend — by design | Re-seed (instant), or `-c @css:config/file.json -f ./data` when persistence is genuinely needed |
| `:3000` already in use | A previous CSS (or the app) owns it | Kill the listener; the app belongs on `:3200` |
