# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/eth_types,
  stint,
  kzg4844/kzg_ex as kzg,
  stew/endians2,
  nimcrypto/sha2,
  stew/results,
  ../../../../nimbus/core/eip4844

type
  BlobID* = uint64
  BlobIDs* = seq[BlobID]

  BlobCommitment* = object
    blob*: kzg.KzgBlob
    commitment*: kzg.KZGCommitment

  BlobTxWrapData* = object
    hashes*: seq[Hash256]
    blobs*: seq[kzg.KzgBlob]
    commitments*: seq[kzg.KZGCommitment]
    proofs*: seq[kzg.KzgProof]

func getBlobList*(startId: BlobID, count: int): BlobIDs =
  result = newSeq[BlobID](count)
  for i in 0..<count:
    result[i] = startId + BlobID(i)

func getBlobList*(startId: BlobID, count: int, addition: BlobID): BlobIDs =
  result = newSeq[BlobID](count+1)
  for i in 0..<count:
    result[i] = startId + BlobID(i)
  result[^1] = addition

func getBlobListByIndex*(startIndex: BlobID, endIndex: BlobID): BlobIDs =
  var count = uint64(0)
  if endIndex > startIndex:
    count = uint64(endIndex - startIndex + 1)
  else:
    count = uint64(startIndex - endIndex + 1)

  result = newSeq[BlobID](count)
  if endIndex > startIndex:
    for i in 0..<count:
      result[i] = startIndex + BlobID(i)
  else:
    for i in 0..<count:
      result[i] = endIndex - BlobID(i)

func verifyBlob*(blobId: BlobID, blob: kzg.KzgBlob): bool =
  if blobId == 0:
    # Blob zero is empty blob
    var emptyFieldElem: kzg.KzgBlob
    return emptyFieldElem == blob

  # Check the blob against the deterministic data
  let blobIdBytes = toBytesBE blobId

  # First 32 bytes are the hash of the blob ID
  var currentHashed = sha256.digest(blobIdBytes)

  for chunkIdx in 0..<FIELD_ELEMENTS_PER_BLOB:
    var expectedFieldElem = currentHashed.data

    # Check that no 32 bytes chunks are greater than the BLS modulus
    for i in 0..<32:
      # blobByteIdx = 32 - i - 1
      let blobByteIdx = i
      if expectedFieldElem[blobByteIdx] < BLS_MODULUS[i]:
        # done with this field element
        break
      elif expectedFieldElem[blobByteIdx] >= BLS_MODULUS[i]:
        if BLS_MODULUS[i] > 0:
          # This chunk is greater than the modulus, and we can reduce it in this byte position
          expectedFieldElem[blobByteIdx] = BLS_MODULUS[i] - 1
          # done with this field element
          break
        else:
          # This chunk is greater than the modulus, but we can't reduce it in this byte position, so we will try in the next byte position
          expectedFieldElem[blobByteIdx] = BLS_MODULUS[i]

    if not equalMem(blob[chunkIdx*32].unsafeaddr, expectedFieldElem[0].addr, 32):
      return false

    # Hash the current hash
    currentHashed = sha256.digest(currentHashed.data)

  return true

proc fillBlob(blobId: BlobID): KzgBlob =
  if blobId == 0:
    # Blob zero is empty blob, so leave as is
    return

  # Fill the blob with deterministic data
  let blobIdBytes = toBytesBE blobId

  # First 32 bytes are the hash of the blob ID
  var currentHashed = sha256.digest(blobIdBytes)

  for chunkIdx in 0..<FIELD_ELEMENTS_PER_BLOB:
    copyMem(result[chunkIdx*32].addr, currentHashed.data[0].addr, 32)

    # Check that no 32 bytes chunks are greater than the BLS modulus
    for i in 0..<32:
      #blobByteIdx = ((chunkIdx + 1) * 32) - i - 1
      let blobByteIdx = (chunkIdx * 32) + i
      if result[blobByteIdx] < BLS_MODULUS[i]:
        # go to next chunk
        break
      elif result[blobByteIdx] >= BLS_MODULUS[i]:
        if BLS_MODULUS[i] > 0:
          # This chunk is greater than the modulus, and we can reduce it in this byte position
          result[blobByteIdx] = BLS_MODULUS[i] - 1
          # go to next chunk
          break
        else:
          # This chunk is greater than the modulus, but we can't reduce it in this byte position, so we will try in the next byte position
          result[blobByteIdx] = BLS_MODULUS[i]

    # Hash the current hash
    currentHashed = sha256.digest(currentHashed.data)

proc generateBlob(blobid: BlobID): BlobCommitment =
  result.blob = blobid.fillBlob()
  let res = blobToKzgCommitment(result.blob)
  if res.isErr:
    doAssert(false, res.error)
  result.commitment = res.get

proc getVersionedHash*(blobid: BlobID, commitmentVersion: byte): Hash256 =
  let res = blobid.generateBlob()
  result = sha256.digest(res.commitment)
  result.data[0] = commitmentVersion

proc blobDataGenerator*(startBlobId: BlobID, blobCount: int): BlobTxWrapData =
  result.blobs = newSeq[kzg.KzgBlob](blobCount)
  result.commitments = newSeq[kzg.KZGCommitment](blobCount)
  result.hashes = newSeq[Hash256](blobCount)
  result.proofs = newSeq[kzg.KzgProof](blobCount)

  for i in 0..<blobCount:
    let res = generateBlob(startBlobId + BlobID(i))
    result.blobs[i] = res.blob
    result.commitments[i] = res.commitment
    result.hashes[i] = kzgToVersionedHash(result.commitments[i])
    let z = computeBlobKzgProof(result.blobs[i], result.commitments[i])
    if z.isErr:
      doAssert(false, z.error)
    result.proofs[i] = z.get()
