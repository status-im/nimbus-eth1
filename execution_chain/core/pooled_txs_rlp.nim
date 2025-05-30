# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/transactions_rlp {.all.},
  ./pooled_txs

export
  transactions_rlp,
  pooled_txs

proc append(w: var RlpWriter, blob: Blob) =
  w.append(blob.bytes)

proc append(w: var RlpWriter, blobsBundle: BlobsBundle) =
  w.append(blobsBundle.blobs)
  w.append(blobsBundle.commitments)
  w.append(blobsBundle.proofs)

proc append*(w: var RlpWriter, tx: PooledTransaction) =
  if tx.tx.txType != TxLegacy:
    w.append(tx.tx.txType)
  if tx.blobsBundle != nil:
    w.startList(4) # spec: rlp([tx_payload, blobs, commitments, proofs])
  w.appendTxPayload(tx.tx)
  if tx.blobsBundle != nil:
    w.append(tx.blobsBundle)

proc read(rlp: var Rlp, T: type Blob): T {.raises: [RlpError].} =
  rlp.read(result.bytes)

proc read(rlp: var Rlp, T: type BlobsBundle): T {.raises: [RlpError].} =
  result = BlobsBundle()
  rlp.read(result.blobs)
  rlp.read(result.commitments)
  rlp.read(result.proofs)

proc readTxTyped(rlp: var Rlp, tx: var PooledTransaction) {.raises: [RlpError].} =
  let
    txType = rlp.readTxType()
    hasBlobsBundle =
      if txType == TxEip4844:
        rlp.listLen == 4
      else:
        false
  if hasBlobsBundle:
    rlp.tryEnterList() # spec: rlp([tx_payload, blobs, commitments, proofs])
  rlp.readTxPayload(tx.tx, txType)
  if hasBlobsBundle:
    rlp.read(tx.blobsBundle)

proc read*(rlp: var Rlp, T: type PooledTransaction): T {.raises: [RlpError].} =
  if rlp.isList:
    rlp.readTxLegacy(result.tx)
  else:
    rlp.readTxTyped(result)

proc read*(
    rlp: var Rlp, T: (type seq[PooledTransaction]) | (type openArray[PooledTransaction])
): seq[PooledTransaction] {.raises: [RlpError].} =
  if not rlp.isList:
    raise newException(
      RlpTypeMismatch, "PooledTransaction list expected, but source RLP is not a list"
    )
  for item in rlp:
    var tx: PooledTransaction
    if item.isList:
      item.readTxLegacy(tx.tx)
    else:
      var rr = rlpFromBytes(rlp.read(seq[byte]))
      rr.readTxTyped(tx)
    result.add tx

proc append*(
    rlpWriter: var RlpWriter, txs: seq[PooledTransaction] | openArray[PooledTransaction]
) =
  rlpWriter.startList(txs.len)
  for tx in txs:
    if tx.tx.txType == TxLegacy:
      rlpWriter.append(tx)
    else:
      rlpWriter.append(rlp.encode(tx))
