# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/[base, hashes],
  kzg4844/kzg_abi,
  stew/endians2,
  nimcrypto/sha2,
  results,
  ../execution_chain/core/eip4844,
  ../execution_chain/core/lazy_kzg as kzg

export base, hashes

type
  BlobID* = uint64
  BlobIDs* = seq[BlobID]

  BlobCommitment* = object
    blob*: kzg.KzgBlob
    commitment*: kzg.KzgCommitment

  BlobTxWrapData* = object
    hashes*: seq[Hash32]
    blobs*: seq[kzg.KzgBlob]
    commitments*: seq[kzg.KzgCommitment]
    proofs*: seq[kzg.KzgProof]

proc fillBlob(blobId: BlobID): KzgBlob =
  if blobId == 0:
    # Blob zero is empty blob, so leave as is
    return

  # Fill the blob with deterministic data
  let blobIdBytes = toBytesBE blobId

  # First 32 bytes are the hash of the blob ID
  var currentHashed = sha256.digest(blobIdBytes)

  for chunkIdx in 0..<FIELD_ELEMENTS_PER_BLOB:
    copyMem(result.bytes[chunkIdx*32].addr, currentHashed.data[0].addr, 32)

    # Check that no 32 bytes chunks are greater than the BLS modulus
    for i in 0..<32:
      #blobByteIdx = ((chunkIdx + 1) * 32) - i - 1
      let blobByteIdx = (chunkIdx * 32) + i
      if result.bytes[blobByteIdx] < BLS_MODULUS[i]:
        # go to next chunk
        break
      elif result.bytes[blobByteIdx] >= BLS_MODULUS[i]:
        if BLS_MODULUS[i] > 0:
          # This chunk is greater than the modulus, and we can reduce it in this byte position
          result.bytes[blobByteIdx] = BLS_MODULUS[i] - 1
          # go to next chunk
          break
        else:
          # This chunk is greater than the modulus, but we can't reduce it in this byte position, so we will try in the next byte position
          result.bytes[blobByteIdx] = BLS_MODULUS[i]

    # Hash the current hash
    currentHashed = sha256.digest(currentHashed.data)

proc generateBlob(blobid: BlobID): BlobCommitment =
  result.blob = blobid.fillBlob()
  let res = blobToKzgCommitment(result.blob)
  if res.isErr:
    doAssert(false, res.error)
  result.commitment = res.get

proc getVersionedHash*(blobid: BlobID, commitmentVersion: byte): Hash32 =
  let res = blobid.generateBlob()
  result = Hash32 sha256.digest(res.commitment.bytes).data
  result.data[0] = commitmentVersion

proc blobDataGenerator*(startBlobId: BlobID, blobCount: int): BlobTxWrapData =
  result.blobs = newSeq[kzg.KzgBlob](blobCount)
  result.commitments = newSeq[kzg.KzgCommitment](blobCount)
  result.hashes = newSeq[Hash32](blobCount)
  result.proofs = newSeq[kzg.KzgProof](blobCount)

  for i in 0..<blobCount:
    let res = generateBlob(startBlobId + BlobID(i))
    result.blobs[i] = res.blob
    result.commitments[i] = res.commitment
    result.hashes[i] = kzgToVersionedHash(result.commitments[i].bytes)
    let z = computeBlobKzgProof(result.blobs[i], result.commitments[i])
    if z.isErr:
      doAssert(false, z.error)
    result.proofs[i] = z.get()

proc blobDataGenerator7594*(startBlobId: BlobID, blobCount: int): BlobTxWrapData =
  result.blobs = newSeq[kzg.KzgBlob](blobCount)
  result.commitments = newSeq[kzg.KzgCommitment](blobCount)
  result.hashes = newSeq[Hash32](blobCount)
  result.proofs = newSeqOfCap[kzg.KzgProof](blobCount * CELLS_PER_EXT_BLOB)

  for i in 0..<blobCount:
    let res = generateBlob(startBlobId + BlobID(i))
    result.blobs[i] = res.blob
    result.commitments[i] = res.commitment
    result.hashes[i] = kzgToVersionedHash(result.commitments[i].bytes)
    let z = kzg.computeCellsAndKzgProofs(result.blobs[i])
    if z.isErr:
      doAssert(false, z.error)
    result.proofs.add z.value.proofs
