# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Compares the KZG point evaluation precompile against the c-kzg backed
# implementation it replaced, and isolates the contribution of each step:
#
#   opt1  move z from G2 to G1 in the pairing equation
#   opt2  precomputed miller loop lines for the two constant G2 operands
#   opt3  fixed base comb table for [y]G1
#
# Run with: ./env.sh nim c -r -d:release tests/bench_kzg_point_eval.nim

import
  std/[times, monotimes, strutils],
  stew/arrayops,
  results,
  eth/common/hashes,
  kzg4844/kzg,
  kzg4844/kzg_abi,
  ../execution_chain/core/eip4844 {.all.},
  ../execution_chain/evm/blscurve

proc loadLines(Q: BLS_G2P): BLS_LINES =
  result.precomputeLines(Q)

# the staged variants below need [tau]G2 too; take it from the same place the
# precompile does rather than restating it
proc setupTauG2(): BLS_G2P =
  loadTrustedSetupFromString(kzg.trustedSetup, 8).expect("trusted setup")
  kzgSetupG2Tau().expect("tau G2 from the loaded setup")

let
  tauG2 = setupTauG2()
  genG2 = generatorG2()
  genG1 = generatorG1()
  tauLines = loadLines(tauG2)
  genLines = loadLines(genG2)
  genTable = initFixedBase(genG1)

# The implementation on master, verbatim apart from being inlined here.
proc masterPointEvaluation(input: openArray[byte]): Result[void, string] =
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

proc staged(input: openArray[byte],
            useLines: static bool, useComb: static bool): bool =
  if input.len != 192:
    return false

  let
    versionedHash = array[32, byte].initCopyFrom(input.toOpenArray(0, 31))
    commitmentBytes = array[48, byte].initCopyFrom(input.toOpenArray(96, 143))
  if kzgToVersionedHash(commitmentBytes).data != versionedHash:
    return false

  var commitment, proof: BLS_G1P
  if not commitment.uncompress(input.toOpenArray(96, 143)):
    return false
  if not proof.uncompress(input.toOpenArray(144, 191)):
    return false
  if not commitment.isInf and not commitment.subgroupCheck:
    return false
  if not proof.isInf and not proof.subgroupCheck:
    return false

  var z, y: BLS_SCALAR
  if not z.fromBytesCanonical(input.toOpenArray(32, 63)):
    return false
  if not y.fromBytesCanonical(input.toOpenArray(64, 95)):
    return false

  var yG1: BLS_G1
  when useComb:
    yG1 = genTable.mul(y)
  else:
    yG1.fromAffine(genG1)
    yG1.mul(y)
  yG1.neg()

  var zProof: BLS_G1
  zProof.fromAffine(proof)
  zProof.mul(z)

  var lhs: BLS_G1
  lhs.fromAffine(commitment)
  lhs.add(yG1)
  lhs.add(zProof)
  lhs.neg()

  var lhsAffine: BLS_G1P
  lhsAffine.toAffine(lhs)

  var acc: BLS_ACC
  when useLines:
    acc = millerLoop(lhsAffine, genLines)
    acc.mul(millerLoop(proof, tauLines))
  else:
    acc = millerLoop(lhsAffine, genG2)
    acc.mul(millerLoop(proof, tauG2))

  acc.check()

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

proc report(name: string, perOp: float, baseline: float) =
  var line = alignLeft(name, 30) & align(formatFloat(perOp, ffDecimal, 4), 8) &
    " ms/op"
  if baseline > 0.0:
    line.add "   " & align(formatFloat(100.0 * (1.0 - perOp / baseline),
      ffDecimal, 1), 5) & "% vs master"
  echo line

proc main() =
  var inputs: seq[seq[byte]]
  for s in 1 .. 8:
    inputs.add makeInput(s)

  for input in inputs:
    doAssert masterPointEvaluation(input).isOk
    doAssert pointEvaluation(input).isOk
    doAssert staged(input, false, false)
    doAssert staged(input, true, false)
    doAssert staged(input, false, true)
    doAssert staged(input, true, true)

  var bad = inputs[0]
  bad[95] = bad[95] xor 1
  doAssert masterPointEvaluation(bad).isErr
  doAssert pointEvaluation(bad).isErr
  echo "all variants agree with the master implementation"
  echo ""

  const
    warmup = 200
    iters = 2000

  for i in 0 ..< warmup:
    doAssert masterPointEvaluation(inputs[i mod inputs.len]).isOk
    doAssert pointEvaluation(inputs[i mod inputs.len]).isOk

  template run(body: untyped): float =
    block:
      let start = getMonoTime()
      for i {.inject.} in 0 ..< iters:
        body
      (getMonoTime() - start).inNanoseconds.float / 1e6 / iters.float

  let master = run:
    doAssert masterPointEvaluation(inputs[i mod inputs.len]).isOk
  report("master (c-kzg)", master, 0.0)

  report("opt1", run((doAssert staged(inputs[i mod inputs.len], false, false))),
    master)
  report("opt1 + opt2", run((
    doAssert staged(inputs[i mod inputs.len], true, false))), master)
  report("opt1 + opt3", run((
    doAssert staged(inputs[i mod inputs.len], false, true))), master)

  let current = run:
    doAssert pointEvaluation(inputs[i mod inputs.len]).isOk
  report("opt1 + opt2 + opt3 (this)", current, master)

main()
