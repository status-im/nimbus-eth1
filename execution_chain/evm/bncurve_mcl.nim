# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  results,
  stew/[assign2, byteutils],
  bncurve/arith,
  mcl/bn_abi,
  ./evm_errors,
  ./types

# one time initialization
doAssert(mclBn_init(MCL_BN_SNARK1, MCLBN_COMPILED_TIME_VAR) == 0.cint)

mclBn_verifyOrderG2(0.cint)

const
  ioMode = MCLBN_IO_SERIALIZE or MCLBN_IO_BIG_ENDIAN

  frobeniusXCoeff =
    "16c9e55061ebae204ba4cc8bd75a079432ae2a1d0b7c9dce1665d51c640fcba2" &
    "2fb347984f7911f74c0bec3cf559b143b78cc310c2c3330c99e39557176f553d"
  frobeniusYCoeff =
    "07c03cbcac41049a0704b5a7ec796f2b21807dc98fa25bd282d37f632623b0e3" &
    "063cf305489af5dcdc5ec698b6e2f9b9dbaae0eda9c95998dc54014671a0135a"

  sixZSquared =
    "000000000000000000000000000000006f4d8248eeb859fbf83e9682e87cfd46"

func isAllZero(data: openArray[byte]): bool =
  for c in data:
    if c != 0: return false
  true

# deserialize Fp from 32 byte big-endian number.
func deserialize(x: var BnFp, buf: openArray[byte]): bool =
  mclBnFp_setStr(x.addr, cast[ptr char](buf[0].addr), 32, ioMode) == 0.cint

func deserialize(x: var BnFp2, buf: openArray[byte]): bool =
  deserialize(x.d[1], buf) and deserialize(x.d[0], buf.toOpenArray(32, buf.len-1))

func deserialize(x: var BnFr, buf: openArray[byte]): bool =
  mclBnFr_setBigEndianMod(x.addr, buf[0].addr, 32.mclSize) == 0

func deserialize(P: var BnG1, buf: openArray[byte]): bool =
  if buf.isAllZero:
    mclBnG1_clear(P.addr)
    return true

  if not deserialize(P.x, buf) or not deserialize(P.y, buf.toOpenArray(32, buf.len-1)):
    return false

  mclBnFp_setInt32(P.z.addr, 1.cint)
  mclBnG1_isValid(P.addr) == 1.cint

func loadFp2(hex: static string): BnFp2 =
  const buf = hexToByteArray[64](hex)
  doAssert deserialize(result, buf)

func loadFr(hex: static string): BnFr =
  const buf = hexToByteArray[32](hex)
  doAssert deserialize(result, buf)

let
  frobeniusX = loadFp2(frobeniusXCoeff)
  frobeniusY = loadFp2(frobeniusYCoeff)
  frobeniusEigenvalue = loadFr(sixZSquared)

func conjugate(y: var BnFp2, x: BnFp2) =
  y.d[0] = x.d[0]
  mclBnFp_neg(y.d[1].addr, x.d[1].addr)

func frobenius(D: var BnG2, S: BnG2) =
  var
    cx {.noinit.}: BnFp2
    cy {.noinit.}: BnFp2

  {.cast(noSideEffect).}:
    cx = frobeniusX
    cy = frobeniusY

  conjugate(D.x, S.x)
  conjugate(D.y, S.y)
  conjugate(D.z, S.z)
  mclBnFp2_mul(D.x.addr, D.x.addr, cx.addr)
  mclBnFp2_mul(D.y.addr, D.y.addr, cy.addr)

func isInSubgroup(P: BnG2): bool =
  var
    lhs {.noinit.}: BnG2
    rhs {.noinit.}: BnG2
    eigenvalue {.noinit.}: BnFr

  {.cast(noSideEffect).}:
    eigenvalue = frobeniusEigenvalue

  frobenius(lhs, P)
  mclBnG2_mul(rhs.addr, P.addr, eigenvalue.addr)
  mclBnG2_isEqual(lhs.addr, rhs.addr) == 1.cint

func deserialize(P: var BnG2, buf: openArray[byte]): bool =
  if buf.isAllZero:
    mclBnG2_clear(P.addr)
    return true

  if not deserialize(P.x, buf) or not deserialize(P.y, buf.toOpenArray(64, buf.len-1)):
    return false

  mclBnFp_setInt32(P.z.d[0].addr, 1.cint)
  mclBnFp_clear(P.z.d[1].addr)
  mclBnG2_isValid(P.addr) == 1.cint and P.isInSubgroup()

# serialize Fp as 32 byte big-endian number.
func serialize(buf: var openArray[byte], x: BnFp): bool =
  # sigh, getStr output buf is zero terminated
  var tmp {.noinit.}: array[33, byte]
  result = mclBnFp_getStr(cast[ptr char](tmp[0].addr), 32, x.addr, ioMode) == 32.mclSize
  assign(buf.toOpenArray(0, 31), tmp.toOpenArray(0, 31))

# Serialize P.x|P.y.
# Set _buf to all zeros if P == 0.
func serialize(buf: var openArray[byte], P: BnG1): bool =
  if mclBnG1_isZero(P.addr) == 1.cint:
    zeroMem(buf[0].addr, 64)
    return true

  var Pn {.noinit.}: BnG1
  mclBnG1_normalize(Pn.addr, P.addr)
  serialize(buf, Pn.x) and serialize(buf.toOpenArray(32, buf.len-1), Pn.y)

func bn256ecAddImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[128, byte]
    p1 {.noinit.}: BnG1
    p2 {.noinit.}: BnG1
    apo {.noinit.}: BnG1

  # Padding data
  let len = min(c.msg.data.len, 128) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))

  if not p1.deserialize(input.toOpenArray(0, 63)):
    return err(prcErr(PrcInvalidPoint))

  if not p2.deserialize(input.toOpenArray(64, 127)):
    return err(prcErr(PrcInvalidPoint))

  mclBnG1_add(apo.addr, p1.addr, p2.addr)

  c.output.setLen(64)
  if not serialize(c.output, apo):
    zeroMem(c.output[0].addr, 64)

  ok()

func bn256ecMulImpl*(c: Computation): EvmResultVoid  =
  var
    input: array[96, byte]
    p1 {.noinit.}: BnG1
    fr {.noinit.}: BnFr
    apo {.noinit.}: BnG1

  # Padding data
  let len = min(c.msg.data.len, 96) - 1
  assign(input.toOpenArray(0, len), c.msg.data.toOpenArray(0, len))

  if not p1.deserialize(input.toOpenArray(0, 63)):
    return err(prcErr(PrcInvalidPoint))

  if not fr.deserialize(input.toOpenArray(64, 95)):
    return err(prcErr(PrcInvalidPoint))

  mclBnG1_mul(apo.addr, p1.addr, fr.addr)

  c.output.setLen(64)
  if not serialize(c.output, apo):
    zeroMem(c.output[0].addr, 64)

  ok()

const millerLoopChunk = 16

func bn256ecPairingImpl*(c: Computation): EvmResultVoid  =
  # Calculate number of pairing pairs
  let count = c.msg.data.len div 192
  var
    g1 {.noinit.}: array[millerLoopChunk, BnG1]
    g2 {.noinit.}: array[millerLoopChunk, BnG2]
    acc {.noinit.}: BnGT
    one {.noinit.}: BnGT
    tmp {.noinit.}: BnGT
    n = 0

  mclBnGT_setInt(acc.addr, 1.mclInt)
  mclBnGT_setInt(one.addr, 1.mclInt)

  for i in 0..<count:
    let s = i * 192

    # Loading AffinePoint[G1], bytes from [0..63]
    if not g1[n].deserialize(c.msg.data.toOpenArray(s, s+63)):
      return err(prcErr(PrcInvalidPoint))

    # Loading AffinePoint[G2], bytes from [64..191]
    if not g2[n].deserialize(c.msg.data.toOpenArray(s+64, s+191)):
      return err(prcErr(PrcInvalidPoint))

    if mclBnG1_isZero(g1[n].addr) == 1.cint or
       mclBnG2_isZero(g2[n].addr) == 1.cint:
      continue

    inc n
    if n == millerLoopChunk:
      mclBn_millerLoopVec(tmp.addr, g1[0].addr, g2[0].addr, mclSize n)
      mclBnGT_mul(acc.addr, acc.addr, tmp.addr)
      n = 0

  if n > 0:
    mclBn_millerLoopVec(tmp.addr, g1[0].addr, g2[0].addr, mclSize n)
    mclBnGT_mul(acc.addr, acc.addr, tmp.addr)

  mclBn_finalExp(tmp.addr, acc.addr)

  c.output.setLen(32)
  if mclBnGT_isEqual(tmp.addr, one.addr) == 1.cint:
    # we can discard here because we supply buffer of proper size
    discard BNU256.one().toBytesBE(c.output)

  ok()
