# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  unittest2,
  stew/[arrayops, byteutils],
  results,
  eth/common/hashes,
  kzg4844/kzg,
  kzg4844/kzg_abi,
  ../execution_chain/core/eip4844 {.all.},
  ../execution_chain/evm/blscurve

proc referencePointEvaluation(input: openArray[byte]): Result[void, string] =
  if input.len != 192:
    return err("invalid input length")

  template copyFrom(T: type, input, a, b): auto =
    type X = (type T().bytes)
    T(bytes: X.initCopyFrom(input.toOpenArray(a, b)))

  let
    versionedHash = KzgBytes32.copyFrom(input, 0, 31)
    z = KzgBytes32.copyFrom(input, 32, 63)
    y = KzgBytes32.copyFrom(input, 64, 95)
    commitment = KzgBytes48.copyFrom(input, 96, 143)
    kzgProof = KzgBytes48.copyFrom(input, 144, 191)

  if kzgToVersionedHash(commitment.bytes).data != versionedHash.bytes:
    return err("versionedHash should equal to kzgToVersionedHash(commitment)")

  let res = kzg.verifyKzgProof(commitment, z, y, kzgProof)
  if res.isErr:
    return err(res.error)

  if not res.get():
    return err("Failed to verify KZG proof")

  ok()

proc makeBlob(seed: int): KzgBlob =
  for i in 0 ..< FIELD_ELEMENTS_PER_BLOB:
    let v = (i * 2654435761 + seed) and 0xffffff
    result.bytes[i * 32 + 31] = byte(v and 0xff)
    result.bytes[i * 32 + 30] = byte((v shr 8) and 0xff)
    result.bytes[i * 32 + 29] = byte((v shr 16) and 0xff)

proc makeInput(seed: int): seq[byte] =
  let
    blob = makeBlob(seed)
    commitment = blobToKzgCommitment(blob).expect("commitment")

  var z: KzgBytes32
  z.bytes[31] = byte(seed and 0xff)
  z.bytes[30] = byte((seed shr 8) and 0xff)

  let
    proofAndY = computeKzgProof(blob, z).expect("proof")
    versionedHash = kzgToVersionedHash(commitment.bytes)

  result = newSeq[byte](192)
  result[0 .. 31] = versionedHash.data
  result[32 .. 63] = z.bytes
  result[64 .. 95] = proofAndY.y.bytes
  result[96 .. 143] = commitment.bytes
  result[144 .. 191] = proofAndY.proof.bytes

proc withCommitment(input: seq[byte], commitment: openArray[byte]): seq[byte] =
  result = input
  result[96 .. 143] = commitment
  let versionedHash = kzgToVersionedHash(
    array[48, byte].initCopyFrom(commitment))
  result[0 .. 31] = versionedHash.data

proc toBytes(p: BLS_G2P): seq[byte] =
  var g {.noinit.}: BLS_G2
  g.fromAffine(p)
  result = newSeq[byte](256)
  doAssert encodePoint(g, result)

proc checkAgreement(input: seq[byte]) =
  let
    expected = referencePointEvaluation(input)
    actual = pointEvaluation(input)
  check expected.isOk == actual.isOk

suite "KZG point evaluation precompile":
  loadTrustedSetupFromString(kzg.trustedSetup, 8).expect("trusted setup")

  const
    infinityG1 = "c0" & repeat("00", 47)
    notInG1 = "8123456789abcdef" & repeat("0123456789abcdef", 5)
    blsModulus =
      "73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001"

  let inputs = block:
    var res: seq[seq[byte]]
    for seed in 1 .. 4:
      res.add makeInput(seed)
    res

  test "tau G2 comes from the loaded trusted setup":
    # the known EIP-4844 ceremony value, as an independent check on what the
    # library hands back
    const knownTauG2 =
      "b5bfd7dd8cdeb128843bc287230af38926187075cbfbefa81009a2ce615ac53d" &
      "2914e5870cb452d2afaaab24f3499f72185cbfee53492714734429b7b38608e2" &
      "3926c911cceceac9a36851477ba4c60b087041de621000edc98edada20c1def2"

    var expected {.noinit.}: BLS_G2P
    check expected.uncompress(hexToByteArray[96](knownTauG2))

    let tau = kzgSetupG2Tau()
    check tau.isOk
    check tau.get().toBytes == expected.toBytes

  test "valid proofs are accepted":
    for input in inputs:
      check pointEvaluation(input).isOk
      checkAgreement(input)

  test "tampered fields are rejected":
    for offset in [0, 32, 64, 96, 144]:
      var input = inputs[0]
      input[offset + 31] = input[offset + 31] xor 1
      check pointEvaluation(input).isErr
      checkAgreement(input)

  test "mismatched versioned hash is rejected":
    var input = inputs[0]
    input[0 .. 31] = inputs[1][0 .. 31]
    check pointEvaluation(input).isErr
    checkAgreement(input)

  test "invalid input lengths are rejected":
    for len in [0, 191, 193]:
      var input = inputs[0]
      input.setLen(len)
      check pointEvaluation(input).isErr
      checkAgreement(input)

  test "non canonical z and y are rejected":
    let overModulus = [blsModulus, repeat("ff", 32)]
    for offset in [32, 64]:
      for value in overModulus:
        var input = inputs[0]
        input[offset ..< offset + 32] = value.hexToSeqByte()
        check pointEvaluation(input).isErr
        checkAgreement(input)

  test "commitment and proof outside G1 are rejected":
    var input = withCommitment(inputs[0], notInG1.hexToSeqByte())
    check pointEvaluation(input).isErr
    checkAgreement(input)

    input = inputs[0]
    input[144 .. 191] = notInG1.hexToSeqByte()
    check pointEvaluation(input).isErr
    checkAgreement(input)

  test "the point at infinity is handled like c-kzg":
    var input = withCommitment(inputs[0], infinityG1.hexToSeqByte())
    checkAgreement(input)

    input = inputs[0]
    input[144 .. 191] = infinityG1.hexToSeqByte()
    checkAgreement(input)

    input = withCommitment(inputs[0], infinityG1.hexToSeqByte())
    input[144 .. 191] = infinityG1.hexToSeqByte()
    checkAgreement(input)

  test "a zero z and y are handled like c-kzg":
    var input = inputs[0]
    input[32 .. 95] = newSeq[byte](64)
    checkAgreement(input)

  test "proof of a zero polynomial verifies":
    let
      blob = default(KzgBlob)
      commitment = blobToKzgCommitment(blob).expect("commitment")

    var z: KzgBytes32
    z.bytes[31] = 3

    let
      proofAndY = computeKzgProof(blob, z).expect("proof")
      versionedHash = kzgToVersionedHash(commitment.bytes)

    var input = newSeq[byte](192)
    input[0 .. 31] = versionedHash.data
    input[32 .. 63] = z.bytes
    input[64 .. 95] = proofAndY.y.bytes
    input[96 .. 143] = commitment.bytes
    input[144 .. 191] = proofAndY.proof.bytes

    check pointEvaluation(input).isOk
    checkAgreement(input)
