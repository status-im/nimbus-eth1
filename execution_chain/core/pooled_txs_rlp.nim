# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  eth/common/transactions_rlp {.all.},
  ./pooled_txs

export
  transactions_rlp,
  pooled_txs

proc append(w: var RlpWriter, blob: Blob) =
  w.append(blob.bytes)

proc append(w: var RlpWriter, blobsBundle: BlobsBundle) =
  if blobsBundle.wrapperVersion == WrapperVersionEIP7594:
    w.append(1.uint)
  w.append(blobsBundle.blobs)
  w.append(blobsBundle.commitments)
  w.append(blobsBundle.proofs)

proc append*(w: var RlpWriter, tx: PooledTransaction) =
  if tx.tx.txType != TxLegacy:
    w.append(tx.tx.txType)
  if tx.blobsBundle != nil:
    if tx.blobsBundle.wrapperVersion == WrapperVersionEIP4844:
      w.startList(4) # spec: rlp([tx_payload, blobs, commitments, proofs])
    else:
      # https://github.com/ethereum/EIPs/blob/dc71750143ffab2401b700c66c063d1cf7484df4/EIPS/eip-7594.md#networking
      # spec: rlp([tx_payload_body, wrapper_version, blobs, commitments, cell_proofs])
      w.startList(5)
  w.appendTxPayload(tx.tx)
  if tx.blobsBundle != nil:
    w.append(tx.blobsBundle)

proc read(rlp: var Rlp, T: type Blob): T {.raises: [RlpError].} =
  rlp.read(result.data)

proc readTxTyped(rlp: var Rlp, tx: var PooledTransaction) {.raises: [RlpError].} =
  let
    txType = rlp.readTxType()
    numFields =
      if txType == TxEip4844:
        rlp.listLen
      else:
        1
  if numFields == 4 or numFields == 5:
    rlp.tryEnterList() # spec: rlp([tx_payload, blobs, commitments, proofs])
  rlp.readTxPayload(tx.tx, txType)
  if numFields == 4 or numFields == 5:
    var bundle = BlobsBundle()
    if numFields == 4:
      bundle.wrapperVersion = WrapperVersionEIP4844
    else:
      let val = rlp.read(uint)
      if val != 1:
        raise newException(
          UnsupportedRlpError,
          "Wrapper version must be 1, got " & $val,
        )
      bundle.wrapperVersion = WrapperVersionEIP7594

    rlp.read(bundle.blobs)
    rlp.read(bundle.commitments)
    rlp.read(bundle.proofs)
    tx.blobsBundle = bundle

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
