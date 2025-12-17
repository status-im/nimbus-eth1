# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  results,
  stew/assign2,
  bncurve/arith,
  mcl/bn_abi,
  ./evm_errors,
  ./types

# one time initialization
doAssert(mclBn_init(MCL_BN_SNARK1, MCLBN_COMPILED_TIME_VAR) == 0.cint)

const
  ioMode = MCLBN_IO_SERIALIZE or MCLBN_IO_BIG_ENDIAN

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

func deserialize(P: var BnG2, buf: openArray[byte]): bool =
  if buf.isAllZero:
    mclBnG2_clear(P.addr)
    return true

  if not deserialize(P.x, buf) or not deserialize(P.y, buf.toOpenArray(64, buf.len-1)):
    return false

  mclBnFp_setInt32(P.z.d[0].addr, 1.cint)
  mclBnFp_clear(P.z.d[1].addr)
  mclBnG2_isValid(P.addr) == 1.cint

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

func bn256ecPairingImpl*(c: Computation): EvmResultVoid  =
  let msglen = c.msg.data.len
  if msglen == 0:
    # we can discard here because we supply buffer of proper size
    c.output.setLen(32)
    discard BNU256.one().toBytesBE(c.output)
  else:
    # Calculate number of pairing pairs
    let count = msglen div 192
    # Pairing accumulator
    var
      acc {.noinit.}: BnGT
      one {.noinit.}: BnGT
      tmp {.noinit.}: BnGT

    mclBnGT_setInt(acc.addr, 1.mclInt)
    mclBnGT_setInt(one.addr, 1.mclInt)

    var
      p1 {.noinit.}: BnG1
      p2 {.noinit.}: BnG2

    for i in 0..<count:
      let s = i * 192

      # Loading AffinePoint[G1], bytes from [0..63]
      if not p1.deserialize(c.msg.data.toOpenArray(s, s+63)):
        return err(prcErr(PrcInvalidPoint))

      # Loading AffinePoint[G2], bytes from [64..191]
      if not p2.deserialize(c.msg.data.toOpenArray(s+64, s+191)):
        return err(prcErr(PrcInvalidPoint))

      # Accumulate pairing result
      mclBn_pairing(tmp.addr, p1.addr, p2.addr)
      mclBnGT_mul(acc.addr, acc.addr, tmp.addr)

    c.output.setLen(32)
    if mclBnGT_isEqual(acc.addr, one.addr) == 1.cint:
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytesBE(c.output)

  ok()
