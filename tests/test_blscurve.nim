# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Differential test for `sumAffines`, the variable-time affine+affine -> Jacobian
# point addition used by the BLS12-381 G1ADD/G2ADD precompiles. It is hand-rolled
# consensus-critical arithmetic, so it is validated here against blst's
# independent projective point addition (`add`) over a large pseudo-random
# sample plus the special cases: doubling, P + (-P), and points at infinity.

{.used.}

import
  std/random,
  unittest2,
  stew/byteutils,
  stint, stint/endians2,
  ../execution_chain/evm/blscurve

const Pmod = StUint[384].fromHex(
  "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab")

# --- reference: blst's projective complete addition (independent of sumAffines) ---
proc refAdd(ab, bb: array[128, byte]): array[128, byte] =
  var pa, pb {.noinit.}: BLS_G1P
  doAssert pa.decodePoint(ab) and pb.decodePoint(bb)
  var acc, t {.noinit.}: BLS_G1
  acc.fromAffine(pa)
  t.fromAffine(pb)
  acc.add(t)
  doAssert encodePoint(acc, result)

proc refAdd(ab, bb: array[256, byte]): array[256, byte] =
  var pa, pb {.noinit.}: BLS_G2P
  doAssert pa.decodePoint(ab) and pb.decodePoint(bb)
  var acc, t {.noinit.}: BLS_G2
  acc.fromAffine(pa)
  t.fromAffine(pb)
  acc.add(t)
  doAssert encodePoint(acc, result)

# --- system under test ---
proc newAdd(ab, bb: array[128, byte]): array[128, byte] =
  var pa, pb {.noinit.}: BLS_G1P
  doAssert pa.decodePoint(ab) and pb.decodePoint(bb)
  var acc {.noinit.}: BLS_G1
  acc.sumAffines(pa, pb)
  doAssert encodePoint(acc, result)

proc newAdd(ab, bb: array[256, byte]): array[256, byte] =
  var pa, pb {.noinit.}: BLS_G2P
  doAssert pa.decodePoint(ab) and pb.decodePoint(bb)
  var acc {.noinit.}: BLS_G2
  acc.sumAffines(pa, pb)
  doAssert encodePoint(acc, result)

# --- pseudo-random valid curve point generators (raw[16..] with top byte 0 => < p) ---
proc randG1(r: var Rand): array[128, byte] =
  var raw: array[64, byte]
  for i in 17..63: raw[i] = byte(r.next() and 0xff)
  var fp {.noinit.}: BLS_FP
  doAssert fp.decodeFE(raw)
  doAssert encodePoint(fp.mapFPToG1(), result)

proc randG2(r: var Rand): array[256, byte] =
  var raw: array[128, byte]
  for i in 17..63:  raw[i] = byte(r.next() and 0xff)
  for i in 81..127: raw[i] = byte(r.next() and 0xff)
  var fp {.noinit.}: BLS_FP2
  doAssert fp.decodeFE(raw)
  doAssert encodePoint(fp.mapFPToG2(), result)

# negate: (x, y) -> (x, p - y) on the relevant coordinate slots
proc negFE(dst: var openArray[byte]) =
  var y: StUint[384]
  y.initFromBytesBE(dst)
  let ny = (if y.isZero: y else: Pmod - y)
  dst[0 ..< 48] = ny.toBytesBE()

proc negG1(pb: array[128, byte]): array[128, byte] =
  result = pb
  negFE(result.toOpenArray(80, 127))

proc negG2(pb: array[256, byte]): array[256, byte] =
  result = pb
  negFE(result.toOpenArray(144, 191))
  negFE(result.toOpenArray(208, 255))

suite "BLS12-381 sumAffines (G1ADD/G2ADD affine addition)":
  const
    G1Rounds = 12_000
    G2Rounds =  6_000
  let
    infG1 = default(array[128, byte])
    infG2 = default(array[256, byte])

  test "G1: differential vs projective add + edge cases":
    var r = initRand(0x1234_5678_9abc_def0'i64)
    var mismatches = 0
    template chk(a, b: array[128, byte], tag: string) =
      if refAdd(a, b) != newAdd(a, b):
        if mismatches == 0:
          checkpoint("G1 mismatch (" & tag & "): a=" & a.toHex & " b=" & b.toHex)
        inc mismatches
    for _ in 0 ..< G1Rounds:
      let a = randG1(r)
      let b = randG1(r)
      chk(a, b, "random")
      chk(a, a, "double")          # P + P
      chk(a, negG1(a), "neg")      # P + (-P) -> inf
      chk(a, infG1, "P+inf")
      chk(infG1, a, "inf+P")
    chk(infG1, infG1, "inf+inf")
    check mismatches == 0

  test "G2: differential vs projective add + edge cases":
    var r = initRand(0x0fed_cba9_8765_4321'i64)
    var mismatches = 0
    template chk(a, b: array[256, byte], tag: string) =
      if refAdd(a, b) != newAdd(a, b):
        if mismatches == 0:
          checkpoint("G2 mismatch (" & tag & "): a=" & a.toHex & " b=" & b.toHex)
        inc mismatches
    for _ in 0 ..< G2Rounds:
      let a = randG2(r)
      let b = randG2(r)
      chk(a, b, "random")
      chk(a, a, "double")
      chk(a, negG2(a), "neg")
      chk(a, infG2, "P+inf")
      chk(infG2, a, "inf+P")
    chk(infG2, infG2, "inf+inf")
    check mismatches == 0
