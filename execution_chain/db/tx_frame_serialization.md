# TxFrame Serialization

`CoreDbTxRef` (txFrame) holds the in-memory delta for a single block's execution — trie vertex changes, account/storage leaf caches, and KVT metadata writes. This document describes how that delta is serialized to the KVT database and restored on startup, avoiding block replay.

---

## Combined Value Layout

The value stored under `txFrameKey(blockHash)` is the concatenation of two blobs:

```
[aristo_blob_len : 4 bytes BE]
[aristo_blob     : aristo_blob_len bytes]
[kvt_blob_len    : 4 bytes BE]
[kvt_blob        : kvt_blob_len bytes]
```

Each blob has its own version byte and internal structure described below.

---

## Aristo Blob (`aristo_tx_blobify.nim`)

Serializes the delta recorded in `AristoTxRef`: `sTab`, `kMap`, `accLeaves`, `stoLeaves`, `vTop`, `blockNumber`.

All multi-byte integers are **big-endian**.

### Layout

```
version          : 1 byte   = 0x01
vTop             : 8 bytes  (VertexID as uint64)
blockNumber_flag : 1 byte   (0x00 = none, 0x01 = some)
blockNumber      : 8 bytes  (uint64, only meaningful when flag = 0x01)

sTab_count       : 4 bytes
  [repeated sTab_count times]
  rvid_len       : 1 byte
  rvid_blob      : rvid_len bytes
  is_nil         : 1 byte   (0x00 = deletion marker, 0x01 = present)
  [only when is_nil = 0x01]
  vtx_blob_len   : 2 bytes
  vtx_blob       : vtx_blob_len bytes

accLeaves_count  : 4 bytes
  [repeated accLeaves_count times]
  acc_path       : 32 bytes (Hash32 — keccak256 of address)
  is_nil         : 1 byte   (0x00 = deletion marker, 0x01 = present)
  [only when is_nil = 0x01]
  leaf_blob_len  : 2 bytes
  leaf_blob      : leaf_blob_len bytes

stoLeaves_count  : 4 bytes
  [repeated stoLeaves_count times]
  sto_path       : 32 bytes (Hash32 — keccak256 of slot key mixed with address)
  is_nil         : 1 byte   (0x00 = deletion marker, 0x01 = present)
  [only when is_nil = 0x01]
  leaf_blob_len  : 2 bytes
  leaf_blob      : leaf_blob_len bytes
```

### rvid_blob

`RootedVertexID` is encoded using the existing `blobify(rvid: RootedVertexID): RVidBuf` from `aristo_blobify.nim`. It is a compact variable-length big-endian encoding:

```
root_len   : 1 byte     (number of significant bytes in root VertexID)
root       : root_len bytes
[vid]      : remaining bytes, omitted when root == vid
```

Maximum size: 17 bytes. `rvid_len` records the actual length.

### vtx_blob

Vertices are encoded using the existing `blobifyTo(vtx: VertexRef, key: HashKey, data: var VertexBuf)` from `aristo_blobify.nim`. This format is shared with the Aristo RocksDB backend.

The `HashKey` for a vertex is looked up in `kMap`; if absent, `VOID_HASH_KEY` is used. The key is embedded inside `vtx_blob` for branch nodes (indicated by a bit in the last byte), so **no separate `kMap` section is needed** — `kMap` is implicitly reconstructed on decode via `deblobify(blob, HashKey)`.

Vertex type encoding (last byte of vtx_blob):

```
bits [7:6]  meaning
  00        Branch — no embedded hash key
  10        Branch — 32-byte hash key prepended
  01        Leaf   (AccLeaf or StoLeaf, distinguished by payload mask)
```

AccLeaf and StoLeaf blobs are produced by `blobifyTo(AccLeafRef, ...)` and `blobifyTo(StoLeafRef, ...)` respectively. The path prefix (`pfx: NibblesBuf`) is encoded as a hex-prefix byte sequence appended before the type byte.

Maximum vtx_blob size: 117 bytes (`MAX_VERTEX_BLOB_SIZE`).

### leaf_blob (accLeaves / stoLeaves)

Account and storage leaves stored in the `accLeaves` / `stoLeaves` caches are serialized as full `VertexRef` values using the same `blobifyTo(vtx, VOID_HASH_KEY, data)` call (no embedded hash key since these are cache entries, not trie nodes requiring a key). On decode, `deblobify(blob, VertexRef)` reconstructs the `AccLeafRef` or `StoLeafRef` including the `pfx` (path prefix) field.

### nil entries

A `nil` value in `sTab`, `accLeaves`, or `stoLeaves` is a deletion marker (the key was explicitly set to nil in this frame to shadow a non-nil value in a parent frame). These are serialized with `is_nil = 0x00` and no following blob, and restored as `nil` on decode.

---

## KVT Blob (`kvt_tx_blobify.nim`)

Serializes the pending key-value writes in `KvtTxRef.sTab`: transactions, receipts, contract code, and other KVT metadata.

All multi-byte integers are **big-endian**.

### Layout

```
version    : 1 byte   = 0x01
sTab_count : 4 bytes
  [repeated sTab_count times]
  key_len  : 2 bytes
  key      : key_len bytes
  val_len  : 4 bytes
  val      : val_len bytes
```

Keys and values are raw byte sequences. Key types are identified by the first byte matching `DBKeyKind` values (`storage_types.nim`), but the serializer treats them as opaque blobs.

---

## Serialization Process

1. After a block is finalized and checkpointed, call `storeTxFrame(frame, blockHash)`.
2. Internally:
   - `blobifyTxFrame(frame.aTx)` walks `sTab`, `kMap`, `accLeaves`, `stoLeaves` and produces the Aristo blob.
   - `blobifyKvtTxFrame(frame.kTx)` walks `sTab` and produces the KVT blob.
   - The two blobs are length-prefixed and concatenated.
   - The result is written to KVT via `frame.put(txFrameKey(blockHash), combinedBlob)`.
3. On the next `persist` call the entry is flushed to RocksDB alongside the block's trie changes.

---

## Deserialization Process (startup restore)

1. On startup, after opening the database, call `loadTxFrame(coreDb, blockHash)` where `blockHash` is the canonical head hash.
2. Internally:
   - Read the combined blob from the base KVT frame (which reads from the persisted database).
   - Parse the 4-byte Aristo length, decode the Aristo blob via `deblobifyTxFrame`.
   - Parse the 4-byte KVT length, decode the KVT blob via `deblobifyKvtTxFrame`.
   - Create a new `CoreDbTxRef` via `coreDb.txFrameBegin()` (rooted at the current base).
   - Populate `aTx.sTab`, `aTx.kMap`, `aTx.accLeaves`, `aTx.stoLeaves`, `aTx.vTop`, `aTx.blockNumber` from the decoded Aristo data.
   - Populate `kTx.sTab` from the decoded KVT data.
3. Return the populated frame. The caller attaches it to the processing pipeline (checkpoint, snapshot, etc.) as the warm frame for the next block.

---

## Size Estimates

For a typical Ethereum mainnet block (~200 transactions):

| Component | Typical entries | Bytes/entry | Subtotal |
|-----------|----------------|-------------|----------|
| sTab — branch nodes | ~1 000 | ~80 | ~80 KB |
| sTab — leaf nodes (acc + sto) | ~1 500 | ~115 | ~172 KB |
| accLeaves cache | ~500 | ~87 | ~43 KB |
| stoLeaves cache | ~1 000 | ~71 | ~71 KB |
| KVT sTab (txs, receipts, code) | ~400–600 | ~500 avg | ~200 KB |
| Length prefixes and rvid headers | — | — | ~10 KB |
| **Total** | | | **~576 KB** |

Practical range:
- Empty block: < 5 KB
- Average mainnet block: 500–700 KB
- Dense DeFi block: 1–3 MB

A cache window of 64 recent frames requires roughly **40 MB** total KVT storage.
