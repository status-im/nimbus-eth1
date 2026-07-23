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
  std/[random, monotimes, times, strformat],
  unittest2,
  ../execution_chain/evm/blscurve

const
  G1Sizes = [2, 4, 8, 16, 32, 64, 128]
  G2Sizes = [2, 4, 8, 16, 32, 64]
  G1MulBudget = 2048
  G2MulBudget = 512

var rng = initRand(0x1337)

proc randFieldElem(): array[64, byte] =
  for i in 16..63:
    result[i] = byte rng.rand(0xFF)
  result[16] = byte rng.rand(0x0F)

proc randScalar(): BLS_SCALAR =
  var raw {.noinit.}: array[32, byte]
  for i in 0..31:
    raw[i] = byte rng.rand(0xFF)
  doAssert result.fromBytes(raw)

proc randG1Point(): BLS_G1P =
  var fp {.noinit.}: BLS_FP
  doAssert fp.decodeFE(randFieldElem())
  var enc = newSeq[byte](128)
  doAssert encodePoint(mapFPToG1(fp), enc)
  doAssert result.decodePoint(enc)

proc randG2Point(): BLS_G2P =
  var
    fp2 {.noinit.}: BLS_FP2
    raw {.noinit.}: array[128, byte]
  let
    a = randFieldElem()
    b = randFieldElem()
  for i in 0..63:
    raw[i] = a[i]
    raw[64+i] = b[i]
  doAssert fp2.decodeFE(raw)
  var enc = newSeq[byte](256)
  doAssert encodePoint(mapFPToG2(fp2), enc)
  doAssert result.decodePoint(enc)

proc naiveMultiExp(points: openArray[BLS_G1P],
                   scalars: openArray[BLS_SCALAR]): BLS_G1 =
  for i in 0..<points.len:
    var t {.noinit.}: BLS_G1
    t.fromAffine(points[i])
    t.mul(scalars[i])
    if i == 0: result = t
    else: result.add(t)

proc naiveMultiExp(points: openArray[BLS_G2P],
                   scalars: openArray[BLS_SCALAR]): BLS_G2 =
  for i in 0..<points.len:
    var t {.noinit.}: BLS_G2
    t.fromAffine(points[i])
    t.mul(scalars[i])
    if i == 0: result = t
    else: result.add(t)

proc toBytes(p: BLS_G1): seq[byte] =
  result = newSeq[byte](128)
  doAssert encodePoint(p, result)

proc toBytes(p: BLS_G2): seq[byte] =
  result = newSeq[byte](256)
  doAssert encodePoint(p, result)

var sink: byte

template measure(iters: int, body: untyped): float =
  let start = getMonoTime()
  for _ in 0..<iters:
    body
  float((getMonoTime() - start).inNanoseconds) / float(iters)

suite "BLS12-381 multi-scalar multiplication":
  test "G1 pippenger matches naive sum of scalar muls":
    for K in G1Sizes:
      var
        points = newSeq[BLS_G1P](K)
        scalars = newSeq[BLS_SCALAR](K)
      for i in 0..<K:
        points[i] = randG1Point()
        scalars[i] = randScalar()

      var acc {.noinit.}: BLS_G1
      acc.multiExp(points, scalars)
      check acc.toBytes == naiveMultiExp(points, scalars).toBytes

  test "G2 pippenger matches naive sum of scalar muls":
    for K in G2Sizes:
      var
        points = newSeq[BLS_G2P](K)
        scalars = newSeq[BLS_SCALAR](K)
      for i in 0..<K:
        points[i] = randG2Point()
        scalars[i] = randScalar()

      var acc {.noinit.}: BLS_G2
      acc.multiExp(points, scalars)
      check acc.toBytes == naiveMultiExp(points, scalars).toBytes

  test "G1 MSM benchmark":
    echo &"""{"K":>6} {"naive (us)":>14} {"pippenger (us)":>16} {"speedup":>9}"""
    for K in G1Sizes:
      var
        points = newSeq[BLS_G1P](K)
        scalars = newSeq[BLS_SCALAR](K)
      for i in 0..<K:
        points[i] = randG1Point()
        scalars[i] = randScalar()

      let iters = max(2, G1MulBudget div K)
      let naive = measure(iters):
        sink = sink xor naiveMultiExp(points, scalars).toBytes[127]
      let fast = measure(iters):
        var acc {.noinit.}: BLS_G1
        acc.multiExp(points, scalars)
        sink = sink xor acc.toBytes[127]

      let speedup = naive / fast
      echo &"{K:>6} {naive/1000.0:>14.1f} {fast/1000.0:>16.1f} {speedup:>8.2f}x"
      if K >= 64:
        check speedup > 1.5

  test "G2 MSM benchmark":
    echo &"""{"K":>6} {"naive (us)":>14} {"pippenger (us)":>16} {"speedup":>9}"""
    for K in G2Sizes:
      var
        points = newSeq[BLS_G2P](K)
        scalars = newSeq[BLS_SCALAR](K)
      for i in 0..<K:
        points[i] = randG2Point()
        scalars[i] = randScalar()

      let iters = max(2, G2MulBudget div K)
      let naive = measure(iters):
        sink = sink xor naiveMultiExp(points, scalars).toBytes[255]
      let fast = measure(iters):
        var acc {.noinit.}: BLS_G2
        acc.multiExp(points, scalars)
        sink = sink xor acc.toBytes[255]

      let speedup = naive / fast
      echo &"{K:>6} {naive/1000.0:>14.1f} {fast/1000.0:>16.1f} {speedup:>8.2f}x"
      if K >= 32:
        check speedup > 1.5
