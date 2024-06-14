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
  std/[os, strutils],
  nimcrypto/sha2,
  kzg4844/kzg_ex as kzg,
  results,
  stint,
  ../constants,
  ../common/common

from std/sequtils import mapIt

{.push raises: [].}

type
  Bytes64 = array[64, byte]

const
  BLS_MODULUS_STR = "52435875175126190479447740508185965837690552500527637822603658699938581184513"
  BLS_MODULUS* = parse(BLS_MODULUS_STR, UInt256, 10).toBytesBE
  PrecompileInputLength = 192

proc pointEvaluationResult(): Bytes64 {.compileTime.} =
  result[0..<32] = FIELD_ELEMENTS_PER_BLOB.u256.toBytesBE[0..^1]
  result[32..^1] = BLS_MODULUS[0..^1]

const
  PointEvaluationResult* = pointEvaluationResult()
  POINT_EVALUATION_PRECOMPILE_GAS* = 50000.GasInt


# kzgToVersionedHash implements kzg_to_versioned_hash from EIP-4844
proc kzgToVersionedHash*(kzg: kzg.KZGCommitment): VersionedHash =
  result = sha256.digest(kzg.bytes)
  result.data[0] = VERSIONED_HASH_VERSION_KZG

# pointEvaluation implements point_evaluation_precompile from EIP-4844
# return value and gas consumption is handled by pointEvaluation in
# precompiles.nim
proc pointEvaluation*(input: openArray[byte]): Result[void, string] =
  # Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
  # Also verify that the provided commitment matches the provided versioned_hash.
  # The data is encoded as follows: versioned_hash | z | y | commitment | proof |

  if input.len != PrecompileInputLength:
    return err("invalid input length")

  var
    versionedHash: KzgBytes32
    z: KzgBytes32
    y: KzgBytes32
    commitment: KzgBytes48
    kzgProof: KzgBytes48

  versionedHash.bytes[0..<32] = input[0..<32]
  z.bytes[0..<32] = input[32..<64]
  y.bytes[0..<32] = input[64..<96]
  commitment.bytes[0..<48] = input[96..<144]
  kzgProof.bytes[0..<48]   = input[144..<192]

  if kzgToVersionedHash(commitment).data != versionedHash.bytes:
    return err("versionedHash should equal to kzgToVersionedHash(commitment)")

  # Verify KZG proof
  let res = kzg.verifyKzgProof(commitment, z, y, kzgProof)
  if res.isErr:
    return err(res.error)

  # The actual verify result
  if not res.get():
    return err("Failed to verify KZG proof")

  ok()

# calcExcessBlobGas implements calc_excess_data_gas from EIP-4844
proc calcExcessBlobGas*(parent: BlockHeader): uint64 =
  let
    excessBlobGas = parent.excessBlobGas.get(0'u64)
    blobGasUsed = parent.blobGasUsed.get(0'u64)

  if excessBlobGas + blobGasUsed < TARGET_BLOB_GAS_PER_BLOCK:
    0'u64
  else:
    excessBlobGas + blobGasUsed - TARGET_BLOB_GAS_PER_BLOCK

# fakeExponential approximates factor * e ** (num / denom) using a taylor expansion
# as described in the EIP-4844 spec.
func fakeExponential*(factor, numerator, denominator: UInt256): UInt256 =
  var
    i = 1.u256
    output = 0.u256
    numeratorAccum = factor * denominator

  while numeratorAccum > 0.u256:
    output += numeratorAccum
    numeratorAccum = (numeratorAccum * numerator) div (denominator * i)
    i = i + 1.u256

  output div denominator

proc getTotalBlobGas*(tx: Transaction): uint64 =
  GAS_PER_BLOB * tx.versionedHashes.len.uint64

proc getTotalBlobGas*(versionedHashesLen: int): uint64 =
  GAS_PER_BLOB * versionedHashesLen.uint64

# getBlobBaseFee implements get_data_gas_price from EIP-4844
func getBlobBaseFee*(excessBlobGas: uint64): UInt256 =
  fakeExponential(
    MIN_BLOB_GASPRICE.u256,
    excessBlobGas.u256,
    BLOB_GASPRICE_UPDATE_FRACTION.u256
  )

proc calcDataFee*(versionedHashesLen: int,
                  excessBlobGas: uint64): UInt256 =
  getTotalBlobGas(versionedHashesLen).u256 *
    getBlobBaseFee(excessBlobGas)

func blobGasUsed(txs: openArray[Transaction]): uint64 =
  for tx in txs:
    result += tx.getTotalBlobGas

# https://eips.ethereum.org/EIPS/eip-4844
func validateEip4844Header*(
    com: CommonRef, header, parentHeader: BlockHeader,
    txs: openArray[Transaction]): Result[void, string] {.raises: [].} =

  if not com.forkGTE(Cancun):
    if header.blobGasUsed.isSome:
      return err("unexpected EIP-4844 blobGasUsed in block header")

    if header.excessBlobGas.isSome:
      return err("unexpected EIP-4844 excessBlobGas in block header")

    return ok()

  if header.blobGasUsed.isNone:
    return err("expect EIP-4844 blobGasUsed in block header")

  if header.excessBlobGas.isNone:
    return err("expect EIP-4844 excessBlobGas in block header")

  let
    headerBlobGasUsed = header.blobGasUsed.get()
    blobGasUsed = blobGasUsed(txs)
    headerExcessBlobGas = header.excessBlobGas.get
    excessBlobGas = calcExcessBlobGas(parentHeader)

  if blobGasUsed > MAX_BLOB_GAS_PER_BLOCK:
    return err("blobGasUsed " & $blobGasUsed & " exceeds maximum allowance " & $MAX_BLOB_GAS_PER_BLOCK)

  if headerBlobGasUsed != blobGasUsed:
    return err("calculated blobGas not equal header.blobGasUsed")

  if headerExcessBlobGas != excessBlobGas:
    return err("calculated excessBlobGas not equal header.excessBlobGas")

  return ok()

proc validateBlobTransactionWrapper*(tx: PooledTransaction):
                                     Result[void, string] {.raises: [].} =
  if tx.networkPayload.isNil:
    return err("tx wrapper is none")

  # note: assert blobs are not malformatted
  let goodFormatted = tx.tx.versionedHashes.len ==
                      tx.networkPayload.commitments.len and
                      tx.tx.versionedHashes.len ==
                      tx.networkPayload.blobs.len and
                      tx.tx.versionedHashes.len ==
                      tx.networkPayload.proofs.len

  if not goodFormatted:
    return err("tx wrapper is ill formatted")

  let commitments = tx.networkPayload.commitments.mapIt(
                      kzg.KzgCommitment(bytes: it))

  # Verify that commitments match the blobs by checking the KZG proof
  let res = kzg.verifyBlobKzgProofBatch(
              tx.networkPayload.blobs.mapIt(kzg.KzgBlob(bytes: it)),
              commitments,
              tx.networkPayload.proofs.mapIt(kzg.KzgProof(bytes: it)))

  if res.isErr:
    return err(res.error)

  # Actual verification result
  if not res.get():
    return err("Failed to verify network payload of a transaction")

  # Now that all commitments have been verified, check that versionedHashes matches the commitments
  for i in 0 ..< tx.tx.versionedHashes.len:
    # this additional check also done in tx validation
    if tx.tx.versionedHashes[i].data[0] != VERSIONED_HASH_VERSION_KZG:
      return err("wrong kzg version in versioned hash at index " & $i)

    if tx.tx.versionedHashes[i] != kzgToVersionedHash(commitments[i]):
      return err("tx versioned hash not match commitments at index " & $i)

  ok()

proc loadKzgTrustedSetup*(): Result[void, string] =
  const
    vendorDir = currentSourcePath.parentDir.replace('\\', '/') & "/../../vendor"
    trustedSetupDir = vendorDir & "/nim-kzg4844/kzg4844/csources/src"
    trustedSetup = staticRead trustedSetupDir & "/trusted_setup.txt"

  Kzg.loadTrustedSetupFromString(trustedSetup)
