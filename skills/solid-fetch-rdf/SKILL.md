---
name: solid-fetch-rdf
description: >-
  Use when code fetches or parses RDF from a Solid pod — importing @jeswr/fetch-rdf, calling fetchRdf/parseRdf, handling RdfFetchError, or keeping the ETag for a conditional write. Documents the published 0.1.x API: this package is not in context7 and its README lags the npm dist.
---

# @jeswr/fetch-rdf — fetch + parse Solid RDF

The only sanctioned way to GET and parse a Solid RDF resource (companion guide:
[`AGENTS.md`](https://github.com/jeswr/solid-ai-coding/blob/main/AGENTS.md)). One HTTP GET + content-type-dispatched parse, returning an
in-memory dataset plus the validators you need for conditional writes. Never parse RDF inline
(`new Parser().parse(await res.text())`) and never use `rdf-parse`.

```sh
npm install @jeswr/fetch-rdf      # deps (content-type, jsonld-streaming-parser, n3) come with it
```

Pure ESM, Node ≥ 20. The README's "until we publish, use a git dep" note is stale — it **is**
published.

## API surface (complete, v0.1.0)

```ts
import {
  fetchRdf, parseRdf, extractMediaType,
  SUPPORTED_RDF_MEDIA_TYPES, DEFAULT_ACCEPT,
  RdfFetchError,
} from "@jeswr/fetch-rdf";
import type { FetchRdfOptions, ParseRdfOptions, FetchedRdf, RdfFetchErrorOptions } from "@jeswr/fetch-rdf";
```

```ts
function fetchRdf(url: string, options?: FetchRdfOptions): Promise<FetchedRdf>;
function parseRdf(body: string | ReadableStream<Uint8Array>, contentTypeHeader: string | null,
                  options?: ParseRdfOptions): Promise<Store>;   // n3.Store

interface FetchRdfOptions {
  fetch?: typeof fetch;   // defaults to globalThis.fetch — see auth note below
  accept?: string;        // defaults to DEFAULT_ACCEPT: "text/turtle, application/ld+json;q=0.9"
  headers?: HeadersInit;  // merged in; any `accept` here is overridden by the option above
  signal?: AbortSignal;
}
interface ParseRdfOptions { baseIRI?: string }  // set this to the resource URL

interface FetchedRdf {
  dataset: DatasetCore;        // n3.Store at runtime; type via @rdfjs/types
  etag: string | null;         // strong validator — keep for If-Match on writes
  contentType: string | null;  // media type, parameters stripped, lowercased
  response: Response;          // raw response for further headers
  url: string;                 // final URL after redirects
}
```

## Usage

```ts
const { dataset, etag } = await fetchRdf(resourceUrl);
```

- **Auth**: pass no `fetch` — `@solid/reactive-authentication` patches `globalThis.fetch`, so
  authentication is automatic. The package's own TSDoc suggests passing a fetch from
  `@uvdsl/solid-oidc-client-browser` — **ignore that** (banned in this stack).
- **Errors**: non-2xx, network, and parse failures all throw `RdfFetchError` with `.status`,
  `.url`, `.contentType`, `.cause`. Branch with `instanceof` + `.status`, never string-match:

  ```ts
  try { await fetchRdf(url); }
  catch (e) {
    if (e instanceof RdfFetchError && e.status === 404) { /* create the resource */ }
    else throw e;
  }
  ```

- **Pure parse** (body already in hand): `await parseRdf(turtle, "text/turtle", { baseIRI: url })`.
  A `null` content-type defaults to `text/turtle`.
- **Formats** (`SUPPORTED_RDF_MEDIA_TYPES`): `text/turtle`, `application/n-triples`,
  `application/n-quads`, `application/trig` (via n3) and `application/ld+json` (via
  jsonld-streaming-parser). Anything else throws — no RDF/XML by design.

## What this package does NOT do

- **No writes.** The write path is yours: mutate the dataset through `@rdfjs/wrapper` typed
  accessors, serialise with `n3.Writer`, conditional `PUT` with `If-Match: <etag>` — see
  `AGENTS.md` §Writing data.
- **No wrapping.** Feed `dataset` to `@solid/object` / your `TermWrapper` subclasses
  (`new WebIdDataset(dataset, DataFactory)`) — see the `solid-object` skill.

## Gotchas

| Gotcha | Detail |
|---|---|
| `headers.accept` is ignored | Set the `accept` *option*, not an `accept` header |
| `etag` may be `null` | Some servers (legacy NSS) send no ETag — handle the degraded no-`If-Match` write path (see `solid-server-matrix`) |
| `dataset` typed as `DatasetCore` | It is an `n3.Store` at runtime, but write code against the RDF/JS interface |
| README lags | Trust this skill + the `.d.ts` in `node_modules` over the repo README |
| AS2 `application/activity+json` is rejected by `parseRdf`, and `parseRdf` alone is not safe for AS2 server-side | ActivityStreams 2.0 senders use `application/activity+json`, not in `SUPPORTED_RDF_MEDIA_TYPES`. The bytes are JSON-LD-compatible, but AS2 embeds a remote `@context` URL — using `parseRdf` after a content-type normalisation risks a live outbound context fetch (SSRF). Use the underlying `jsonld` layer with a guarded `documentLoader` instead. See the "Receiver-side" section below. (Receiver/server-side; learned building the LDN suggest-inbox in jeswr/solid-webid-index.) |
| A foreign pod's claim about *you* is **untrusted** | `fetchRdf` returns whatever the bytes say. A resource in someone else's pod asserting "this task is assigned to *you*" / "*you* are a member" is an unverified claim — anyone can write that triple. Before acting on cross-pod data, verify provenance: authorised source **and** the data resides in that source's own `pim:storage`. See "Receiver-side: trusting cross-pod claims" below. (Learned building the Pod Manager assigned-to-me view, jeswr/solid-pod-manager.) |

## Receiver-side: parsing AS2 LDN notifications safely

_(Server-side / LDN consumer context — not relevant to browser Solid apps.)_

When your server receives an [ActivityStreams 2.0](https://www.w3.org/TR/activitystreams-core/)
Linked Data Notification (LDN), two traps arise that must **both** be fixed together:

**1. Content-type mismatch.** AS2 senders use `Content-Type: application/activity+json`, which is
not in `SUPPORTED_RDF_MEDIA_TYPES` and causes `parseRdf` to throw. The bytes are valid JSON-LD.
Normalise the content-type using a proper case-insensitive, parameter-aware check:

```ts
// Extract base media type: lower-case, strip parameters (";charset=..."), trim whitespace.
function baseMediaType(header: string): string {
  return header.split(";")[0].trim().toLowerCase();
}

const rawContentType = req.headers["content-type"] ?? "";
const effectiveContentType =
  baseMediaType(rawContentType) === "application/activity+json"
    ? "application/ld+json"
    : rawContentType;
```

**2. Remote `@context` fetch = SSRF + reliability hazard (and `parseRdf` cannot prevent it).**
The AS2 `@context` URL (`https://www.w3.org/ns/activitystreams`) is embedded in every AS2
document. `parseRdf` does **not** expose a `documentLoader` option, so if you call
`parseRdf(body, "application/ld+json")` directly, the underlying JSON-LD layer will attempt a
live outbound HTTP fetch for that context on every notification — an SSRF vector and a hard
runtime dependency on a remote server. **Do not use `parseRdf` directly for AS2 on a server
request path.** Instead, parse through the underlying JSON-LD layer with a `documentLoader` that
serves the bundled context and hard-refuses all other remote fetches:

```ts
import jsonld from "jsonld";
import { Store, Parser } from "n3";
import AS2_CONTEXT from "./contexts/activitystreams.json" assert { type: "json" };

const AS2_CONTEXT_URL = "https://www.w3.org/ns/activitystreams";

const safeDocumentLoader = async (url: string) => {
  if (url === AS2_CONTEXT_URL) {
    return { contextUrl: null, documentUrl: url, document: AS2_CONTEXT };
  }
  throw new Error(`Remote context fetch refused (SSRF guard): ${url}`);
};

const doc = JSON.parse(await req.text());

// Request N-Quads string output (a stable serialisation format); parse with n3 for typed quads.
// No outbound network calls — context is served from the bundled safeDocumentLoader.
const nquadsString = await jsonld.toRDF(doc, {
  documentLoader: safeDocumentLoader,
  format: "application/n-quads",  // returns string when format is given
}) as unknown as string;

const store = new Store();
const parser = new Parser({ format: "application/n-quads" });
store.addQuads(parser.parse(nquadsString));
```

`jsonld.expand` produces expanded JSON-LD objects (not RDF/JS quads); use `jsonld.toRDF` when you
need an RDF dataset to query. Use `parseRdf` only when the incoming body is known to be Turtle or
flat JSON-LD with no remote context references (e.g. you control the sender). For any untrusted
AS2 input on a server, the `jsonld` + guarded `documentLoader` path above is the safe default.

(Learned building the LDN suggest-inbox in jeswr/solid-webid-index.)

## Receiver-side: trusting cross-pod claims (provenance)

_(Any app that consumes data **assigned or shared from other pods** — an "assigned to me" task
view, a shared-with-me list, group membership. Browser or server.)_

`fetchRdf` is content-agnostic: it returns whatever triples the bytes contain. A resource in
**someone else's** pod that says `:task-9 wf:assignee <https://me.example/profile#me>` is making a
*claim about you* — and anyone who can write to that pod can write that triple. Discovery is a
hint, not a grant (`solid-type-index` makes the same point), and here the same holds for
assignment/membership: **a foreign pod's claim is untrusted until you verify its provenance.** Do
not surface "assigned to me" / "you're a member" off raw cross-pod reads.

Two tiers of trust:

1. **Owner-controlled own-pod data is trusted.** Data within the user's *own* `pim:storage`
   (their `agent.storageUrls`) **that only the owner can write** is theirs — render it directly.
   The boundary is *who could have written the bytes*, not merely the URL: a **world-/group-
   appendable resource inside your own pod** (a public inbox, a shared writable container) holds
   bytes a *third party* posted, so a claim there is **not** trusted by location — treat it as
   foreign and run tier 2 on the sender. Trust by ownership of the write capability, not by pod
   membership.
2. **Foreign-pod data is shown only when both hold:**
   - **(a) authorised source** — the asserting WebID is one the user actually trusts: a
     `foaf:knows` contact / saved address-book entry. A *stranger's* pod claiming an assignment is
     rejected outright.
   - **(b) resides in that source's own storage, owner-write-only** — the resource URL falls
     under the *source's own* advertised `pim:storage` (read from **the source's** profile) **and**
     only that source could have written it. This closes two gaps at once: a third, untrusted pod
     that merely *names* a trusted friend as the assigner fails (the bytes live outside the
     friend's storage); and the *same* public-inbox/shared-writable-container gap as tier 1 — a
     world-/group-appendable container *inside* the friend's pod holds bytes a third party posted,
     so a claim there is not provenance-verified just because it sits under the friend's storage.
     (Same principle as the house rules "a profile hosted in a storage does not imply the user owns
     it" and "trust `solid:oidcIssuer` only from the WebID document itself" — provenance is decided
     by *who could have written the bytes*, not by what they assert.)

**Fail closed** on any ambiguity (unreadable source profile or ACL, no `pim:storage`, off-storage
URL, public-/group-writable path): drop the registration, do not show it. **Bound discovery to the
authorised set** — only walk the contacts the user trusts; never follow an arbitrary `assigner`
WebID a foreign document hands you.
And keep the **pure trust decision separate from I/O** so it is exhaustively unit-testable without
a live pod:

```ts
// Pure, synchronous, no fetch — exhaustively unit-testable.
// `authorizedStorages`: Map<sourceWebId, string[]>  (each source's own pim:storage,
//   read from THAT source's profile; only sources the user foaf:knows / has saved).

// Containment must be checked on URL structure, NOT string prefix:
// `startsWith("https://pod.example/alice")` would wrongly match
// `https://pod.example/alice-evil/...`. Compare origin + path on segment boundaries.
function isUnderStorage(resourceUrl: string, storageRoot: string): boolean {
  let res: URL, root: URL;
  try { res = new URL(resourceUrl); root = new URL(storageRoot); }
  catch { return false; }                                    // unparseable → fail closed
  const httpish = (u: URL) => u.protocol === "https:" || u.protocol === "http:";
  if (!httpish(res) || !httpish(root)) return false;         // reject file:/data:/etc — fail closed
  if (res.origin !== root.origin) return false;              // same scheme+host+port
  const rootPath = root.pathname.endsWith("/") ? root.pathname : root.pathname + "/";
  return res.pathname === rootPath.slice(0, -1) || res.pathname.startsWith(rootPath);
}

function isTrustedCrossPodClaim(
  resourceUrl: string,
  assertedBy: string,              // the source WebID the registration attributes the data to
  ownStorages: readonly string[],  // the user's own pim:storage — owner-WRITE-ONLY roots only
  authorizedStorages: ReadonlyMap<string, readonly string[]>,
  // Returns true only when the named principal is the SOLE writer of the resource — i.e. the
  // path is NOT public-/group-appendable (an inbox, a shared writable container). Implement via
  // the resource's effective ACL/ACR (a write capability for none but `principal`); fail closed
  // if the ACL is unreadable. Same check for the user (tier 1) and the source (tier 2).
  ownerWriteOnlyFor: (url: string, principal: string) => boolean,
  ownerWebId: string,              // the current user's WebID (the tier-1 sole writer)
): boolean {
  const under = (url: string, roots: readonly string[]) =>
    roots.some((root) => isUnderStorage(url, root));

  // tier 1: own pod AND only the owner could have written it → trusted.
  if (under(resourceUrl, ownStorages) && ownerWriteOnlyFor(resourceUrl, ownerWebId)) return true;
  const sourceStorages = authorizedStorages.get(assertedBy); // tier 2a: authorised source?
  if (!sourceStorages) return false;                         //   stranger → reject
  // tier 2b: under the source's OWN storage AND only the source could have written it.
  return under(resourceUrl, sourceStorages) && ownerWriteOnlyFor(resourceUrl, assertedBy);
}

// I/O layer (separately tested against a live pod): resolve each candidate source's own
// pim:storage from its profile, build `authorizedStorages` from the trusted contact set,
// then filter the fetched registrations through the pure predicate before any authenticated read.
```

The predicate governs **who** may assign data to you; it is not a network-layer control. Cross-pod
reads still carry the DNS-rebinding risk that a server-side DNS-pinning relay closes (see
`solid-auth`) — provenance and SSRF/DNS-pinning are independent guards; apply both.

(Learned building the Pod Manager assigned-to-me view, jeswr/solid-pod-manager.)
