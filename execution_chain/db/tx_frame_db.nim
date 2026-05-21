# nimbus-eth1
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## CoreDb tx-frame database persistence
## =====================================
##
## Stores the delta of a `CoreDbTxRef` (Aristo sTab/kMap/leaves + KVT sTab)
## into the KVT database under a block-hash key, enabling startup restore
## without replaying blocks -- analogous to `fcState` load in `fcu_db.nim`.
##
## Storage key : `txFrameKey(blockHash)` (DBKeyKind.txFrame = 16)
## Value layout (big-endian lengths):
##   aristo_blob_len : 4 bytes
##   aristo_blob     : aristo_blob_len bytes
##   kvt_blob_len    : 4 bytes
##   kvt_blob        : kvt_blob_len bytes
##
## Serialization Process
## =====================
##
## 1. After a block is finalized and checkpointed, call `storeTxFrame(frame, blockHash)`.
## 2. Internally:
##    - `blobifyTxFrame(frame.aTx)` walks `sTab`, `kMap`, `accLeaves`, `stoLeaves` and produces the Aristo blob.
##    - `blobifyKvtTxFrame(frame.kTx)` walks `sTab` and produces the KVT blob.
##    - The two blobs are length-prefixed and concatenated.
##    - The result is written to KVT via `frame.put(txFrameKey(blockHash), combinedBlob)`.
## 3. On the next `persist` call the entry is flushed to RocksDB alongside the block's trie changes.
##
## Deserialization Process (startup restore)
## =========================================
##
## 1. On startup, after opening the database, call `loadTxFrame(coreDb, blockHash)` where `blockHash` is 
##    the canonical head hash.
## 2. Internally:
##    - Read the combined blob from the base KVT frame (which reads from the persisted database).
##    - Parse the 4-byte Aristo length, decode the Aristo blob via `deblobifyTxFrame`.
##    - Parse the 4-byte KVT length, decode the KVT blob via `deblobifyKvtTxFrame`.
##    - Create a new `CoreDbTxRef` via `coreDb.txFrameBegin()` (rooted at the current base).
##    - Populate `aTx.sTab`, `aTx.kMap`, `aTx.accLeaves`, `aTx.stoLeaves`, `aTx.vTop`, `aTx.blockNumber` from 
##        the decoded Aristo data.
##    - Populate `kTx.sTab` from the decoded KVT data.
## 3. Return the populated frame. The caller attaches it to the processing pipeline (checkpoint, snapshot, etc.) as 
##      the warm frame for the next block.
##
## Practical range:
## ================
##  - Empty block: < 5 KB
##  - Average mainnet block: 500–700 KB
##  - Dense DeFi block: 1–3 MB

{.push raises: [].}

import
  stew/endians2,
  eth/common/hashes,
  results,
  ./core_db/[base, base_desc],
  ./aristo/aristo_tx_blobify,
  ./kvt/[kvt_desc, kvt_tx_blobify],
  ./storage_types

export base, base_desc, results

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc storeTxFrame*(
    target: CoreDbTxRef;
    src: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[void] =
  ## Serialise the Aristo and KVT deltas of `src` and write the result to
  ## KVT under `txFrameKey(blockHash)` into `target`.  Used by the chain
  ## persistence layer to write each block's frame into the base frame.
  let
    aristoBlob = blobifyTxFrame(src.aTx)
    kvtBlob    = blobifyKvtTxFrame(src.kTx)

  var blob = newSeqOfCap[byte](8 + aristoBlob.len + kvtBlob.len)
  blob.add aristoBlob.len.uint32.toBytesBE
  blob.add aristoBlob
  blob.add kvtBlob.len.uint32.toBytesBE
  blob.add kvtBlob

  target.put(txFrameKey(blockHash).toOpenArray, blob)

proc storeTxFrame*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[void] =
  ## Serialise both the Aristo and KVT deltas of `db` and write the result
  ## to KVT under `txFrameKey(blockHash)`.  The entry is written into the
  ## same frame so it is persisted together with the block data.
  storeTxFrame(db, db, blockHash)

proc loadTxFrame*(
    db: CoreDbRef;
    blockHash: Hash32;
      ): CoreDbRc[CoreDbTxRef] =
  ## Read the stored delta for `blockHash` and return a new `CoreDbTxRef`
  ## rooted at the current database base, with the stored delta applied.
  ##
  ## Intended for startup: call this instead of replaying blocks to warm up
  ## the in-memory frame for the canonical head.  The returned frame is a
  ## direct child of the base; the caller should attach it to the processing
  ## pipeline (checkpoint, snapshot, etc.) as needed.
  let base = db.baseTxFrame()
  let blob = base.get(txFrameKey(blockHash).toOpenArray).valueOr:
    return err(error)

  if blob.len < 8:
    return err(DataInvalid.toError("loadTxFrame: blob too short"))

  # Length fields are read as uint32 and all size arithmetic is performed in
  # uint64 to avoid truncation or signed overflow on 32-bit platforms.
  let
    blobLen = uint64(blob.len)
    aLen    = uint64(uint32.fromBytesBE(blob.toOpenArray(0, 3)))
  if blobLen < 4'u64 + aLen + 4'u64:
    return err(DataInvalid.toError("loadTxFrame: aristo region truncated"))
  let kOff = 4'u64 + aLen
  let kLen = uint64(uint32.fromBytesBE(blob.toOpenArray(int(kOff), int(kOff) + 3)))
  if blobLen < kOff + 4'u64 + kLen:
    return err(DataInvalid.toError("loadTxFrame: kvt region truncated"))

  let aRc = deblobifyTxFrame(blob.toOpenArray(4, int(4'u64 + aLen) - 1))
  if aRc.isErr:
    return err(aRc.error.toError("loadTxFrame aristo"))
  let aData = aRc.value

  let kRc = deblobifyKvtTxFrame(blob.toOpenArray(int(kOff + 4'u64), int(kOff + 4'u64 + kLen) - 1))
  if kRc.isErr:
    return err(kRc.error.toError("loadTxFrame kvt"))
  let kData = kRc.value

  let frame  = db.txFrameBegin()
  frame.aTx.sTab        = aData.sTab
  frame.aTx.kMap        = aData.kMap
  frame.aTx.accLeaves   = aData.accLeaves
  frame.aTx.stoLeaves   = aData.stoLeaves
  frame.aTx.vTop        = aData.vTop
  frame.aTx.blockNumber = aData.blockNumber
  frame.kTx.sTab        = kData

  ok frame

proc loadTxFrameAsChild*(
    srcBase: CoreDbTxRef;
    parent: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[CoreDbTxRef] =
  ## Read the stored delta for `blockHash` from `srcBase`'s KVT and return
  ## a new `CoreDbTxRef` rooted as a child of `parent`, with the stored
  ## delta applied.  Used by the chain persistence layer to materialise
  ## per-block frames in the chain hierarchy without re-executing blocks.
  let blob = srcBase.get(txFrameKey(blockHash).toOpenArray).valueOr:
    return err(error)

  if blob.len < 8:
    return err(DataInvalid.toError("loadTxFrameAsChild: blob too short"))

  # Length fields are read as uint32 and all size arithmetic is performed in
  # uint64 to avoid truncation or signed overflow on 32-bit platforms.
  let
    blobLen = uint64(blob.len)
    aLen    = uint64(uint32.fromBytesBE(blob.toOpenArray(0, 3)))
  if blobLen < 4'u64 + aLen + 4'u64:
    return err(DataInvalid.toError("loadTxFrameAsChild: aristo region truncated"))
  let kOff = 4'u64 + aLen
  let kLen = uint64(uint32.fromBytesBE(blob.toOpenArray(int(kOff), int(kOff) + 3)))
  if blobLen < kOff + 4'u64 + kLen:
    return err(DataInvalid.toError("loadTxFrameAsChild: kvt region truncated"))

  let aRc = deblobifyTxFrame(blob.toOpenArray(4, int(4'u64 + aLen) - 1))
  if aRc.isErr:
    return err(aRc.error.toError("loadTxFrameAsChild aristo"))
  let aData = aRc.value

  let kRc = deblobifyKvtTxFrame(blob.toOpenArray(int(kOff + 4'u64), int(kOff + 4'u64 + kLen) - 1))
  if kRc.isErr:
    return err(kRc.error.toError("loadTxFrameAsChild kvt"))
  let kData = kRc.value

  let frame = parent.txFrameBegin()
  frame.aTx.sTab        = aData.sTab
  frame.aTx.kMap        = aData.kMap
  frame.aTx.accLeaves   = aData.accLeaves
  frame.aTx.stoLeaves   = aData.stoLeaves
  frame.aTx.vTop        = aData.vTop
  frame.aTx.blockNumber = aData.blockNumber
  frame.kTx.sTab        = kData

  ok frame

proc deleteTxFrame*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[void] =
  ## Remove the stored frame entry for `blockHash`.
  db.del(txFrameKey(blockHash).toOpenArray)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
