# nimbus-eth1
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Stores each block's Aristo delta in the shared KVT database so fork
## choice can be restored without executing blocks again. Block bodies and
## receipts already live in KVT and are not part of the frame blob.
##
## Layout: a 4-byte big-endian Aristo length followed by the Aristo blob.
## Writes and deletes take effect immediately; loading does not consume a blob.

{.push raises: [].}

import
  stew/endians2,
  eth/common/hashes,
  results,
  ./core_db/[base, base_desc],
  ./aristo/[aristo_desc, aristo_tx_blobify, aristo_tx_frame],
  ./kvt/[kvt_desc],
  ./storage_types

export base, base_desc, results, TxFrameData

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc storeTxFrame*(
    target: CoreDbTxRef;
    src: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[void] =
  ## Write the Aristo delta of `src` to shared KVT under the block hash.
  let
    aristoBlob = blobifyTxFrame(src.aTx)

  var blob = newSeqOfCap[byte](4 + aristoBlob.len)
  blob.add aristoBlob.len.uint32.toBytesBE
  blob.add aristoBlob

  target.put(txFrameKey(blockHash).toOpenArray, blob)

proc getTxFrameBlob(
    srcBase: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[seq[byte]] =
  ## The stored entry for `blockHash`, its aristo region is `blob[4 .. ^1]`
  let blob = srcBase.get(txFrameKey(blockHash).toOpenArray).valueOr:
    return err(error)

  if blob.len < 4:
    return err(DataInvalid.toError("blob too short"))

  # Length fields are read as uint32 and all size arithmetic is performed in
  # uint64 to avoid truncation or signed overflow on 32-bit platforms.
  let
    blobLen = uint64(blob.len)
    aLen    = uint64(uint32.fromBytesBE(blob.toOpenArray(0, 3)))
  if aLen == 0 or blobLen != 4'u64 + aLen:
    return err(DataInvalid.toError("invalid aristo region length"))

  ok blob

proc txFrameFrom*(parent: CoreDbTxRef; data: var TxFrameData): CoreDbTxRef =
  ## A child of `parent` holding the decoded delta, moved out of `data`
  let frame = parent.txFrameBegin()
  frame.aTx.sTab        = move(data.sTab)
  frame.aTx.kMap        = move(data.kMap)
  frame.aTx.accLeaves   = move(data.accLeaves)
  frame.aTx.stoLeaves   = move(data.stoLeaves)
  frame.aTx.vTop        = data.vTop
  frame.aTx.blockNumber = data.blockNumber
  frame

proc loadTxFrameAsChild*(
    srcBase: CoreDbTxRef;
    parent: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[CoreDbTxRef] =
  ## Read the stored delta for `blockHash` from `srcBase`'s KVT and return
  ## a new `CoreDbTxRef` rooted as a child of `parent`, with the stored
  ## delta applied.  Used by the chain persistence layer to materialise
  ## per-block frames in the chain hierarchy without re-executing blocks.
  let blob = ?srcBase.getTxFrameBlob(blockHash)

  var aData = deblobifyTxFrame(blob.toOpenArray(4, blob.high)).valueOr:
    return err(error.toError("aristo deblobify"))

  ok parent.txFrameFrom(aData)

proc foldTxFrame*(
    srcBase: CoreDbTxRef;
    data: var TxFrameData;
    blockHash: Hash32;
      ): CoreDbRc[Opt[uint64]] =
  ## Add the stored delta for `blockHash` under the newer deltas already
  ## folded into `data`. Returns the stored block number.
  let blob = ?srcBase.getTxFrameBlob(blockHash)

  let number = blob.toOpenArray(4, blob.high).deblobifyTxFrameInto(data).valueOr:
    return err(error.toError("aristo deblobify"))

  ok number

proc spill*(tx: CoreDbTxRef) =
  tx.aTx.dispose()

func isSpilled*(tx: CoreDbTxRef): bool =
  tx.aTx.level == disposedLevel

proc deleteTxFrame*(
    db: CoreDbTxRef;
    blockHash: Hash32;
      ): CoreDbRc[void] =
  ## Remove the stored frame entry for `blockHash`.
  db.del(txFrameKey(blockHash).toOpenArray)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
