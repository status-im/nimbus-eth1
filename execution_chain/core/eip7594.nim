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
  web3/primitives,
  ../constants,
  ./eip4844,
  ./pooled_txs,
  /lazy_kzg as kzg

from std/sequtils import mapIt

proc validateBlobTransactionWrapper7594*(tx: PooledTransaction):
                                     Result[void, string] {.raises: [].} =
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

  let commitments = tx.blobsBundle.commitments.mapIt(
                      kzg.KzgCommitment(bytes: it.data))

  for i in 0 ..< tx.tx.versionedHashes.len:
    # this additional check also done in tx validation
    if tx.tx.versionedHashes[i].data[0] != VERSIONED_HASH_VERSION_KZG:
      return err("wrong kzg version in versioned hash at index " & $i)

    if tx.tx.versionedHashes[i] != kzgToVersionedHash(commitments[i]):
      return err("tx versioned hash not match commitments at index " & $i)

  var
    cells = newSeqOfCap[KzgCell](getProofsLen)
    cellIndices = newSeqOfCap[uint64](getProofsLen)

  for blob in tx.blobsBundle.blobs:
    let cf = ?kzg.computeCellsAndKzgProofs(kzg.KzgBlob(bytes: blob.bytes))
    cells.add cf.cells
    for i in 0..<CELLS_PER_EXT_BLOB:
      cellIndices.add i.uint64

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