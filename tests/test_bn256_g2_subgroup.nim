# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import unittest2

include ../execution_chain/evm/bncurve_mcl

{.pop.}

const twistB =
  "009713b03af0fed4cd2cafadeed8fdf4a74fa084e52d1852e4a2bd0685c315d2" &
  "2b149d40ceb8aaae81be18991be06ac3b5b4c5e559dbefa33267e6dc24a138e5"

proc curvePoint(P: var BnG2, b: BnFp2, i: int): bool =
  var t {.noinit.}: BnFp2
  mclBnFp_setInt32(P.x.d[0].addr, i.cint)
  mclBnFp_setInt32(P.x.d[1].addr, (i * 7 + 1).cint)
  mclBnFp2_sqr(t.addr, P.x.addr)
  mclBnFp2_mul(t.addr, t.addr, P.x.addr)
  mclBnFp2_add(t.addr, t.addr, b.addr)
  if mclBnFp2_squareRoot(P.y.addr, t.addr) != 0.cint:
    return false
  mclBnFp_setInt32(P.z.d[0].addr, 1.cint)
  mclBnFp_clear(P.z.d[1].addr)
  mclBnG2_isValid(P.addr) == 1.cint

suite "bn256 G2 subgroup check":
  test "agrees with mcl isValidOrder on curve points":
    var b {.noinit.}: BnFp2
    check deserialize(b, hexToByteArray[64](twistB))

    var
      onCurve = 0
      inSubgroup = 0
    for i in 1 .. 500:
      var P {.noinit.}: BnG2
      if not curvePoint(P, b, i):
        continue
      inc onCurve
      let expected = mclBnG2_isValidOrder(P.addr) == 1.cint
      check P.isInSubgroup() == expected
      if expected:
        inc inSubgroup

    check onCurve > 100
    check inSubgroup == 0

  test "accepts points mapped into G2":
    var accepted = 0
    for i in 1 .. 50:
      var
        P {.noinit.}: BnG2
        seed = "subgroup-" & $i
      check mclBnG2_hashAndMapTo(P.addr, seed[0].addr, seed.len.mclSize) == 0.cint
      check mclBnG2_isValidOrder(P.addr) == 1.cint
      check P.isInSubgroup()
      inc accepted
    check accepted == 50

  test "accepts the identity"      :
    var P {.noinit.}: BnG2
    mclBnG2_clear(P.addr)
    check P.isInSubgroup()

  test "rejects a curve point outside G2":
    var b {.noinit.}: BnFp2
    check deserialize(b, hexToByteArray[64](twistB))

    var
      P {.noinit.}: BnG2
      found = false
    for i in 1 .. 500:
      if curvePoint(P, b, i) and mclBnG2_isValidOrder(P.addr) != 1.cint:
        found = true
        break
    check found
    check not P.isInSubgroup()
