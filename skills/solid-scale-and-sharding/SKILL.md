---
name: solid-scale-and-sharding
description: >-
  Store and query many small resources in a Solid pod without hitting the walls
  — container-layout sharding (by date / by hash), an explicit index resource
  maintained on write, and the hard limits (no server-side SPARQL on most pods,
  glob removed, inconsistent ETags). Use when an app has collection data — notes,
  bookmarks, messages, sensor readings, chat history — i.e. more than a handful
  of records of the same kind. Pairs with the house stack (@jeswr/fetch-rdf,
  @solid/object, @rdfjs/wrapper, n3); read AGENTS.md first.
---

# Solid scale and sharding

A Solid pod is a **document store, not a query engine.** There is no `WHERE`,
no `ORDER BY`, no `LIMIT` you can push to the server on a standard pod. If your
app has collection data, you design the *layout* and a *client-maintained index*
up front — retrofitting after you have a flat container of thousands of files is
painful and slow.

This skill assumes the house stack and conventions in
[`AGENTS.md`](../../AGENTS.md): read/parse with `@jeswr/fetch-rdf`, typed access
via `@solid/object` + `@rdfjs/wrapper`, mutations through `TermWrapper`
subclasses, conditional `PUT` for writes. **Never** hand-build triples or use
`@inrupt/*` / `@ldo/*`.

## Set expectations first: the hard limits

| Limit | What it means for you | Evidence |
|---|---|---|
| **No server-side SPARQL on CSS/ESS pods** | You cannot filter/sort/aggregate on the server. Every query is "fetch documents, process client-side". | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320), [forum 6886](https://forum.solidproject.org/t/social-bookmarking-as-an-example-where-we-need-queries-instead-of-documents/6886) |
| **Large flat containers are slow** | A container with **1,411 documents** took **>1 s** just to GET the listing; loading every document took **~3 min** in one reported app. Listing cost grows with membership. | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320) |
| **`glob` / wildcard read removed** | No bulk "GET all children's contents in one request". The old NSS glob extension is removed from the spec; attempting it on a big container OOM'd the server (`500`). Treat glob as gone. | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320) (reports the spec issue + OOM); spec-level status **unverified against a current spec section** — do not rely on glob regardless |
| **ETags inconsistent across servers** | NSS historically did **not** support ETags at all, so `If-Match` conditional writes silently degrade there. CSS/ESS do return ETags; don't assume cross-server. | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320) |
| **GET can mutate a container (NSS)** | On node-solid-server, a GET changed the container's `purl:modified` (lock files per read). Don't use a container's modified-time as a cache key on NSS. | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320) — **NSS-specific; not observed on CSS/ESS (unverified there)** |

The canonical forum thread — "state of the art for querying large containers" —
is **still declared open**: the experts (Noel De Martin, Joseph Guillaume) reach
no clean answer beyond "shard and index client-side." This is a known wall, not
a gap in your knowledge. Set the expectation with whoever you're building for.

## The single-file vs file-per-record trade-off

Every collection app faces the same fork, and **both ends are wrong at scale**:

| Approach | Breaks because | Source |
|---|---|---|
| **One big file** (all records in `notes.ttl`) | Easy to query in memory, but you re-download the whole thing on every read and re-PUT it on every write. A real bookmark collection hit **~12 MB** — "loading this over a mobile connection, several times a day". | [forum 6886](https://forum.solidproject.org/t/social-bookmarking-as-an-example-where-we-need-queries-instead-of-documents/6886) |
| **One file per record, flat** | Avoids the monolith, but the container listing and per-document fetches get slow (see 1,411-doc figures above), and you must build your own index. | [forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320), [forum 7730](https://forum.solidproject.org/t/need-help-store-large-amount-of-small-data/7730) |

The answer is **neither**: shard records across **sub-containers**, and maintain
a small **index resource** so reads don't have to walk the whole tree.

## Pattern 1 — shard the container layout

Pick a sharding key so no single container holds more than **a few hundred**
members. (The 1,411-doc thread shows the pain starting in the low thousands; aim
well under that. Exact safe ceiling is **server-dependent and unverified** —
treat "hundreds, not thousands" as the design rule.)

| Strategy | Layout | Use when | Notes |
|---|---|---|---|
| **Shard by date** | `notes/2026/06/05/<id>.ttl` | Time-series, append-mostly data (messages, sensor readings, journal, chat) | Natural pagination ("last 7 days" = a bounded set of containers). Most common. |
| **Shard by hash** | `notes/a3/<id>.ttl` (first 1–2 hex chars of a hash of the id) | Random-access by id, no time dimension (bookmarks keyed by URL hash) | Even spread; fixed fan-out (16 or 256 buckets). Choose width so members/bucket stays in the hundreds at your target scale. |
| **Shard by category** | `notes/work/<id>.ttl`, `notes/personal/<id>.ttl` | Records have a small, stable set of natural buckets | Only if buckets stay balanced; skew reintroduces the flat-container problem. |

Rules:

- **Container URLs end in `/`** — always (a missing slash triggers a redirect
  that can break auth replays and relative IRIs — see AGENTS.md write path).
- Create intermediate containers as needed (PUT/POST per server convention);
  don't assume deep paths auto-create on every server.
- Derive shard paths from the pod root you discovered via `pim:storage`
  (`agent.storageUrls`), under a path your app owns — never mint IRIs at domains
  you don't control.

## Pattern 2 — maintain an explicit index resource

A flat-container listing is the *only* server-provided "query" and it's just
membership — no record fields, and slow at scale. So keep a compact **index
resource** your app updates on every write: one small file holding the few fields
you filter/sort/paginate on (id, title, created-date, tags, shard path), pointing
at the full record resources.

- Read path: GET the index once, filter/sort/paginate **in memory**, then fetch
  only the record documents you actually display.
- Write path: when you create/update a record, update the index in the **same
  read-modify-write cycle** — read index (keep ETag) → mutate via a
  `TermWrapper` subclass → conditional `PUT` (`If-Match`) → on `412`, re-fetch and
  re-apply. This keeps the index consistent with the records.
- Model index entries through a `TermWrapper` subclass with typed accessors (the
  house pattern); never assemble quads inline or string-concat Turtle.
- The index itself can be sharded (e.g. one index per date-container) if it grows
  past a single comfortable file — apply Pattern 1 to the index too.
- **Consistency caveat:** the index is *eventually consistent by convention* —
  there is no cross-document transaction in Solid. A crash between the record PUT
  and the index PUT leaves them out of sync; make index rebuilds (re-derive from
  a container walk) a recoverable operation, and prefer updating the index
  **after** the record write so a failure leaves an unindexed-but-valid record
  rather than a dangling index entry.

> **N3 Patch is a future option, not today's tool.** Servers advertising `PATCH`
> in `Allow` accept N3 Patch, and the forum suggests it for partial updates
> ([forum 7730](https://forum.solidproject.org/t/need-help-store-large-amount-of-small-data/7730)).
> But no sanctioned library in the house stack builds N3 Patch bodies yet, and
> hand-building them is banned (AGENTS.md). Use conditional `PUT` until a library
> ships — don't follow the "just use raw `fetch()` for N3 Patch" forum advice.

## Pattern 3 — client-side querying (Comunica): when, and when not

There is **no server SPARQL endpoint** on a standard pod, so "SPARQL over a pod"
means **client-side link-traversal**: Comunica fetches documents by following
links and evaluates the query in the client. The maintained, agent-ready
integration is the Comunica MCP monorepo —
[`comunica/comunica-feature-mcp`](https://github.com/comunica/comunica-feature-mcp)
(maintained by **Ghent University – imec**), which ships **six MCP servers**
including **SPARQL-Solid (with authentication)** and **SPARQL Link-Traversal
(Solid)**. **It is query-only** — no resource create/update/delete, no container
management, no ACL authoring. Use it for the read lane; do your writes through the
house write path.

| Use Comunica link-traversal when | Avoid it when |
|---|---|
| A one-off / ad-hoc read across a *bounded* set of documents you already know how to reach | A hot read path in interactive UI — traversal is slow; reported full-collection loads ran into **minutes** ([forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320)) |
| Exploration / debugging / an agent answering a question over a pod | You can satisfy the read from your own index resource (Pattern 2) — the index is far faster |
| Federated reads across several pods where you genuinely need graph traversal | The data set is unbounded or grows without limit — traversal cost is unbounded too |

Rule of thumb: **your index resource is the fast path; Comunica is the
expressive-but-slow fallback.** Don't put link-traversal on a render-blocking
path. Don't rebuild a SPARQL-over-Solid layer yourself — integrate the Comunica
MCP if you need querying.

## Pattern 4 — the Type Index is a coarse locator, not a query layer

The Solid Type Index (`solid:publicTypeIndex` / `solid:privateTypeIndex` in the
WebID profile) tells *other apps* **where** a class of data lives — it maps an
`rdf:type` to a container or instance. It is a **discovery pointer, not a query
substitute**: it does not let you filter or sort records, and it is
convention-only (not server-enforced — apps must cooperate). Use it to locate the
container/shard root, then apply Patterns 1–2 inside. (Reading/writing the Type
Index itself is out of scope here — see the companion `solid-type-index` skill.)

## Pagination and listing performance notes

- LDP container listing returns **membership only** (`ldp:contains`), not the
  contents of children. There is **no server-side `LIMIT`/offset** — you get the
  whole membership set and slice client-side. This is precisely why a large flat
  container is slow ([forum 3320](https://forum.solidproject.org/t/state-of-the-art-for-querying-large-containers/3320)).
- **Paginate via layout, not via the listing**: date-sharding gives natural pages
  (a container per day/month); your index resource gives ordered, sliceable
  entries. Both beat listing a giant container and slicing the result.
- List a container with the house stack:

  ```ts
  import { fetchRdf } from "@jeswr/fetch-rdf";
  import { ContainerDataset } from "@solid/object";
  import { DataFactory } from "n3";

  const { dataset } = await fetchRdf(shardUrl);            // shardUrl ends in "/"
  const container = new ContainerDataset(dataset, DataFactory).container;
  for (const r of container?.contains ?? []) {
    // r.id, r.name, r.isContainer — membership only; fetch r.id for contents
  }
  ```

- Don't fan out an unbounded number of parallel GETs for children; bound
  concurrency and fetch only what the current page needs.
- Cache aggressively client-side, but **don't key the cache on a container's
  modified-time on NSS** (a GET mutates it — see the limits table).

## Decision checklist for an agent

1. **How many records, and growing?** Handful and static → one file is fine; skip
   this skill. More than ~hundreds, or unbounded growth → shard + index.
2. **Time dimension?** Yes → shard by date. No, random-access by id → shard by
   hash. Small stable buckets → shard by category.
3. **What do you filter/sort/paginate on?** Put exactly those fields in an index
   resource; maintain it on every write via a `TermWrapper` subclass + conditional
   PUT.
4. **Need expressive cross-document queries?** Use the Comunica MCP
   (query-only, slow) — off the render path. Otherwise read from your index.
5. **Cross-app discovery?** Register the shard root in the Type Index (see
   `solid-type-index`); it locates, it does not query.
