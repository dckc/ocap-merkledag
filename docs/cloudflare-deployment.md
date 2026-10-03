# Deploying ocap-md on Cloudflare: High-Level Design

## Background

ocap-md was designed as a Sandstorm grain: a per-instance (grain) server
hosting a content-addressed Merkle DAG, with access control provided purely
by object capabilities. Sandstorm itself is now unmaintained, but its
creator (Kenton Varda) recreated its core ingredients at Cloudflare:

| Sandstorm concept | Cloudflare equivalent |
|---|---|
| Grain (per-user instance) | Durable Object instance |
| Capability-passing RPC | capnweb (same author, web-native ocap RPC) |
| Unix process + local disk | Workers + R2 + DO SQLite |
| Powerbox / capability sharing | Capability URLs minted by the app |

This doc describes how to deploy ocap-md on Workers, Durable Objects, R2,
and capnweb, replacing the websocket-capnp transport, the disk log files,
and the Sandstorm packaging. The ocap security model — *possession of a
reference is the permission* — carries over essentially unchanged.

## What ports cleanly, what doesn't

**Ports cleanly (design maps 1:1):**

- **Blobs → R2.** The store is content-addressed; `sha256` of canonical
  bytes is already the object key. The disk format's append-only log,
  trie "blob map," and xz compression (pkg/diskstore) are all
  *optimizations for local disk* and can be dropped entirely: R2's
  conditional writes (`onlyIf: etagDoesNotMatch`) give put-if-absent
  dedup, so the triemap/blob-map is no longer needed as a separate
  structure.
- **Manifest / RootPtr → Durable Object.** The manifest (diskstore.capnp
  `Manifest`: root content id, index addresses) reduces to a few rows of
  DO state: current root hash, format version. `RootPtr.get/set`
  (a TxCell) is naturally a serialized transaction on a singleton DO.
- **Ref capabilities → capnweb capabilities.** `Ref(T)`, `Storage`,
  `Map`, `RootPtr` become capnweb `RpcTarget` classes. capnweb has no
  schemas — the interfaces in pkg/schema/protocol.capnp translate to
  plain TS classes with methods; generics become TS types (erased, so
  validate at the boundary with `capnweb-validate`).
- **"One grain per backup" → one Store DO per store instance**, routed
  by store id from the URL/token.

**Does not port:**

- The Go code itself. Workers has first-class support for JS/TS, Python,
  and Rust; Go is only available via WASM, and the runtime assumptions in
  this repo (local filesystem, append-only logs, xz, binary capnp RPC,
  FUSE) don't survive. The core logic is small (hashsplit, blobtree,
  B+ tree nodes, ~a few kLOC in pkg/files, pkg/containers, pkg/blobtree)
  and ports to TypeScript; the hard part of the original webui — no
  browser capnp stack — is now solved by capnweb.
- FUSE mounting (`omd mount`). Needs a client on a machine the user
  controls; see "Client story" below.

## Architecture

```
                        ┌────────────────────────────────────┐
 Browser (preact UI)    │  Cloudflare                        │
 capnweb client ────────┼─▶ Worker "omd-edge"                 │
 (wss /api)            │   • serves static assets (UI)       │
                      │   • routes /api to Store DO          │
 omd CLI / agents      │   • authn gatekeeping (see below)   │
 (see client story)    │  ┌─ Durable Object class "Store" ┐  │
                      │  │ • root pointer (RootPtr)       │  │
                      │  │ • capability registry (SQL)   │  │
                      │  │ • blob index: hash → refcount │  │
                      │  │ • serializes put/get/root     │  │
                      │  └──────┬────────────────────────┘  │
                      │         │ R2 binding                │
                      │  R2 bucket "omd-blobs"               │
                      │   key = hex(sha256(canonical blob))  │
                      │  Cron Trigger → GC Worker            │
                      └────────────────────────────────────┘
```

### Worker: `omd-edge`

- Entry point; owns bindings (R2, DO namespace, secrets).
- Serves the preact webui via Workers Static Assets (replaces
  `webui.RegisterRoutes`).
- `/api` upgraded to WebSocket and handed to the user's Store DO
  (capnweb `newWebSocketRpcSession` on the client,
  `newWorkersRpcResponse` on the server). DO WebSocket hibernation keeps
  idle connections cheap.
- No business logic; all authority lives behind capabilities.

### Durable Object: `Store`

One instance per store (id derived from URL path or capability token).
SQLite-backed tables:

- `root(root_id, content_id, version)` — the manifest's `root` field.
- `capabilities(token, granted_node_hash, mode)` — see "Sharing".
- `blobs(hash, size, refcount)` — blob index; replaces the trie map and
  enables GC. Optionally also `children(hash, child_hash)` derived from
  `Stored.refs` to support reachability checks and mark-and-sweep
  without downloading blobs.

All writes serialized through the DO — this matches the single-writer
design the original manifest/checkpoint machinery implemented with
mutexes and log rotation, but gets transactions and crash safety from
SQLite instead of hand-rolled checkpointing.

### R2: `omd-blobs`

- Object key = hex digest. Value = canonical blob bytes (the
  `Protocol.Stored(AnyPointer)` segment, minus pack/xz — let R2's
  storage handle it; compress in the Worker only if measurements say so).
- `put(key, data, {onlyIf: {etagDoesNotMatch: "*"}})` for
  put-if-absent — global dedup for free, exactly like `DiskStore.Put`
  checking the trie first.
- sha256 via WebCrypto in the Worker/DO; also pass the digest to R2's
  checksum verification where available.

## Protocol translation

`protocol.capnp` → capnweb `RpcTarget` classes (server-side, in TS):

```
Storage.put(value) -> Ref      → class StorageTarget { put(value, refs) }
Ref.get / getStored            → class RefTarget { get(); getStored() }
Map.find(key) -> value         → class MapTarget { find(key) }
RootPtr (Cell/TxCell)          → class RootPtrTarget { get(); set(ref); txGet() }
RootApi (bootstrap)            → the object returned on connection bootstrap
```

The interesting mechanic — `Stored(T) { data, refs }` with refs aligned to
the cap-table — becomes simpler: `StorageTarget.put` accepts
`{ data, refs: [...] }` where each element of `refs` is a live Ref
*capability the caller actually holds*. capnweb passes objects by
reference, so "the refs list" and "the capabilities" are the same thing —
the brand-check that `getRefServer` does on the Go side
(pkg/diskstore/protocol/protocol.go:38) becomes an instanceof check, and
the "only store-hosted refs" rule is enforced the same way.

`getStored` on a Ref returns `{ data, refs: [RefTarget...] }` — the
server rehydrates child Ref capabilities lazily, one level at a time, so
the browser's live object graph grows only along the paths the user is
actually browsing. Browsing a directory = `Map.find` pipelined behind
`getStored` (capnweb pipelining collapses dependent calls into one round
trip, which matters for DAG-walking UIs).

## Security model

ocap-md has no ACLs; deployment must preserve that property rather than
bolt on path-based auth.

- **Owner access**: put the Worker behind Cloudflare Access (Zero Trust
  SSO) for the human owner; or issue the owner a long-lived capability
  URL. Access authenticates the *session*; the *authority* is still the
  bootstrap capability handed to the authenticated user.
- **Sharing (the headline feature)**: "give someone access to a small
  part of a large backup" becomes a **capability URL** — the Sandstorm
  sturdyref pattern, re-created with unguessable tokens:
  `https://omd.example.com/s/<128-bit-token>`. The Store DO's
  `capabilities` table maps token → (granted node hash, mode).
  Loading the URL establishes a capnweb session whose bootstrap is a
  Ref capability to *that node only* — the grantee can walk that
  subtree and nothing else, because `getStored` on a RefTarget only ever
  returns capabilities chained from granted refs, never raw
  hash-resolution (the unfinished `blobMap` interface from
  protocol.capnp:57 stays unfinished — it would be a global lookup and
  break the model).
- **Capability hygiene** (per capnweb's security guide): in-band
  auth (no ambient cookie authority at /api), runtime validation of
  untrusted input at the boundary (`capnweb-validate`), payload limits,
  and rate limiting, since pipelining makes calls cheap for attackers.
- **Hashes are not capabilities**: knowing a digest grants nothing
  without a Ref capability; the DO only resolves hashes reachable from
  granted nodes.

## Blob lifecycle

- **Put path** (backup agent or browser): hashsplit the stream
  (pkg/blobtree logic, ~100 LOC), build BlobTree nodes bottom-up, call
  `storage.put` per node; each put: canonicalize, sha256, conditional R2
  put (dedup), then record/++refcount in the DO index. Last step: hand
  the root Ref to `rootPtr.set`. Incremental backup falls out of dedup,
  as designed.
- **GC**: mark-and-sweep driven from the DO blob index (refcounts or a
  scheduled reachability walk from current root + all granted
  capabilities), executed by a Cron-Triggered Worker in batches; R2
  lifecycle rules as a backstop against leaks. Note the original design
  punts on this too (`types.Storage.Clear` is "TODO").
- **Large files**: stream into R2 (Workers streaming put / multipart),
  stream out on download; capnweb streaming for the API layer. Verify
  current Worker/R2 size and subrequest limits before committing to
  chunk sizes.

## Client story

- **Browser UI**: preact + capnweb client. This is finally buildable:
  the original blocker (no browser capnp RPC) is gone. The UI walks
  `File → dir BPlusTree(Text, File)` via Map.find, renders the tree,
  uploads via hashsplit + storage.put, sets the root — a browser-native
  `omd put`.
- **`omd` CLI (Go)**: capnweb has no Go implementation. Options, in
  increasing order of effort:
  1. Ship a small TS CLI (`tsx`/Bun) mirroring put/get, since the ported
     TS core is shared.
  2. Write a minimal Go client for capnweb's JSON wire protocol (it is
     deliberately simple; the protocol doc specifies the
     pre/post-processing). Keeps FUSE possible.
  3. **FUSE/`mount`**: keep the Go code, talk to it via a local daemon
     that speaks capnweb's protocol — or accept that mounting needs the
     TS core packaged as a native binary (e.g. via `workerd`-free runtimes
     like Node, wrapped in a small Go sidecar).
- **Escape hatch — Cloudflare Containers**: if porting stalls, run the
  *unmodified* Go `omd serve` (cmd/omd) as a Cloudflare Container fronted
  by a Worker. Full fidelity, zero code changes, but loses the browser
  capability story and DO/R2 economics. Reasonable as an interim step to
  validate the product before committing to the TS port.

## Alternatives considered

- **WASM-compiled Go**: Workers support Go via WASM, but the disk
  filesystem, append-only log, and binary capnp assumptions don't
  translate; you'd rewrite the storage layer anyway, so the port might
  as well be TS-native (and capnweb is a JS library).
- **D1 for the blob index**: wrong shape — the index needs
  single-writer serialization with the root pointer (same entity),
  which is exactly what a DO gives you; D1 adds a second consistency
  domain for no benefit.
- **Workers KV for blobs**: no conditional writes / no dedup semantics
  per key at the scale needed; R2 is the right primitive.
- **Cloudflare Artifacts** (versioned file trees): tempting for the
  "backup snapshot" framing, but it is not content-addressed and has no
  capability semantics; R2 + content-addressing preserves the dedup and
  sharing design.

## Open questions / risks

1. **DO SQLite scale**: a large backup set may reach millions of blob
   index rows; verify current DO SQLite limits and whether the index
   should shard (e.g. by hash prefix) across multiple DOs of a
   "BlobIndex" class, or move the index to a per-store D1 database with
   the DO retaining only the root pointer and capability registry.
2. **Cost model**: R2 storage is cheap but Worker duration on
   long-running DAG walks (browse, GC) matters; batch operations and lean
   on R2 conditional writes and DO alarms rather than busy loops.
3. **Session semantics**: capnweb sessions die with the WebSocket;
   capability URLs must restore full authority on reconnect (the
   `session-recovery` example is the template).
4. **GC correctness**: with sharing, "live" means reachable from the
   root *or any outstanding capability* — the capability registry must
   be authoritative for GC, or a shared subtree gets collected.
5. **Streaming + limits**: validate subrequest, memory, and message
   size limits against real backup workloads early; the original design
   used flow control (512 MiB limiter in cmd/omd/main.go:82) that has
   no direct analogue in the browser and needs rethinking.
