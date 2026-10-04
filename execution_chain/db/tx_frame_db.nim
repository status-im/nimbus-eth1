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
  ./aristo/aristo_tx_blobify,
  ./kvt/[kvt_desc],
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
  ## Write the Aristo delta of `src` to shared KVT under the block hash.
  let
    aristoBlob = blobifyTxFrame(src.aTx)

  var blob = newSeqOfCap[byte](4 + aristoBlob.len)
  blob.add aristoBlob.len.uint32.toBytesBE
  blob.add aristoBlob

  target.putMove(txFrameKey(blockHash).toOpenArray, blob)

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

  if blob.len < 4:
    return err(DataInvalid.toError("blob too short"))

  # Length fields are read as uint32 and all size arithmetic is performed in
  # uint64 to avoid truncation or signed overflow on 32-bit platforms.
  let
    blobLen = uint64(blob.len)
    aLen    = uint64(uint32.fromBytesBE(blob.toOpenArray(0, 3)))
  if blobLen < 4'u64 + aLen:
    return err(DataInvalid.toError("aristo region truncated"))

  if aLen == 0 or blobLen != 4'u64 + aLen:
    return err(DataInvalid.toError("invalid aristo region length"))

  let aData = deblobifyTxFrame(blob.toOpenArray(4, int(4'u64 + aLen) - 1)).valueOr:
    return err(error.toError("aristo deblobify"))

  let frame = parent.txFrameBegin()
  frame.aTx.sTab        = aData.sTab
  frame.aTx.kMap        = aData.kMap
  frame.aTx.accLeaves   = aData.accLeaves
  frame.aTx.stoLeaves   = aData.stoLeaves
  frame.aTx.vTop        = aData.vTop
  frame.aTx.blockNumber = aData.blockNumber

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
