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
  ../constants,
  ./eip4844,
  ./pooled_txs,
  /lazy_kzg as kzg

from std/sequtils import mapIt

proc validateBlobTransactionWrapper7594*(tx: PooledTransaction):
                                     Result[void, string] =
  doAssert(tx.blobsBundle.isNil.not)
  doAssert(tx.blobsBundle.wrapperVersion == WrapperVersionEIP7594)

  # note: assert blobs are not malformatted
  let goodFormatted = tx.tx.versionedHashes.len ==
                      tx.blobsBundle.commitments.len and
                      tx.tx.versionedHashes.len ==
                      tx.blobsBundle.blobs.len

  if not goodFormatted:
    return err("tx wrapper is ill formatted")

  let
    expectedProofsLen = CELLS_PER_EXT_BLOB * tx.blobsBundle.blobs.len
    getProofsLen = tx.blobsBundle.proofs.len

  if not getProofsLen == expectedProofsLen:
    return err("cell proofs len mismatch, expect: " &
      $expectedProofsLen &
      ", get: " & $getProofsLen)

  for i in 0 ..< tx.tx.versionedHashes.len:
    # this additional check also done in tx validation
    if tx.tx.versionedHashes[i].data[0] != VERSIONED_HASH_VERSION_KZG:
      return err("wrong kzg version in versioned hash at index " & $i)

    if tx.tx.versionedHashes[i] != kzgToVersionedHash(tx.blobsBundle.commitments[i].data):
      return err("tx versioned hash not match commitments at index " & $i)

  let
    # Instead of converting blobs on stack, we put it on the heap.
    # Even a single blob on stack will crash the program when we call
    # e.g. `let cf = ?kzg.computeCellsAndKzgProofs(kzg.KzgBlob(bytes: blob.data))`
    blobs = tx.blobsBundle.blobs.mapIt(kzg.KzgBlob(bytes: it.data))

  var
    cells = newSeqOfCap[KzgCell](getProofsLen)
    cellIndices = newSeqOfCap[uint64](getProofsLen)
    commitments = newSeqOfCap[kzg.KzgCommitment](getProofsLen)

  # https://github.com/ethereum/execution-apis/blob/5d634063ccfd897a6974ea589c00e2c1d889abc9/src/engine/osaka.md#specification
  for k in 0..<blobs.len:
    for i in 0..<CELLS_PER_EXT_BLOB:
      # bullet 3.iii.a
      commitments.add kzg.KzgCommitment(bytes: tx.blobsBundle.commitments[k].data)
      # bullet 3.iii.b
      cellIndices.add i.uint64

    # bullet 3.iii.c
    let cf = ?kzg.computeCellsAndKzgProofs(blobs[k])
    cells.add cf.cells

  let res = kzg.verifyCellKzgProofBatch(
    commitments,
    cellIndices,
    cells,
    tx.blobsBundle.proofs.mapIt(kzg.KzgProof(bytes: it.data))
  )

  if res.isErr:
    return err(res.error)

  # Actual verification result
  if not res.get():
    return err("Failed to verify blobs bundle of a transaction")

  ok()
