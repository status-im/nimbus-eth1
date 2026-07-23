# Nimbus
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import blscurve/bls_backend, stint

import blscurve/blst/[blst_lowlevel]

const
  FixedBasePoints = 8
  FixedBaseWBits = 8
  FixedBaseNBits = 256 div FixedBasePoints
  FixedBaseTableLen = FixedBasePoints shl (FixedBaseWBits - 1)

type
  BLS_G1* = blst_p1
  BLS_G2* = blst_p2
  BLS_FP* = blst_fp
  BLS_FP2* = blst_fp2
  BLS_SCALAR* = blst_scalar
  BLS_ACC* = blst_fp12
  BLS_G1P* = blst_p1_affine
  BLS_G2P* = blst_p2_affine
  BLS_LINES* = array[68, cblst_fp6]

  BLS_G1_TABLE* = object
    table: array[FixedBaseTableLen, BLS_G1P]

template toCV(x: auto): auto =
  when x is BLS_G1:
    toCV(x, cblst_p1)
  elif x is BLS_G2:
    toCV(x, cblst_p2)
  elif x is BLS_FP:
    toCV(x, cblst_fp)
  elif x is BLS_FP2:
    toCV(x, cblst_fp2)
  elif x is BLS_SCALAR:
    toCV(x, cblst_scalar)
  elif x is BLS_ACC:
    toCV(x, cblst_fp12)
  elif x is BLS_G1P:
    toCV(x, cblst_p1_affine)
  elif x is BLS_G2P:
    toCV(x, cblst_p2_affine)

template toCC(x: auto): auto =
  when x is BLS_G1:
    toCC(x, cblst_p1)
  elif x is BLS_G2:
    toCC(x, cblst_p2)
  elif x is BLS_FP:
    toCC(x, cblst_fp)
  elif x is BLS_FP2:
    toCC(x, cblst_fp2)
  elif x is BLS_SCALAR:
    toCC(x, cblst_scalar)
  elif x is BLS_ACC:
    toCC(x, cblst_fp12)
  elif x is BLS_G1P:
    toCC(x, cblst_p1_affine)
  elif x is BLS_G2P:
    toCC(x, cblst_p2_affine)

func isOverModulus(data: openArray[byte]): bool =
  const
    fieldModulus = StUint[512].fromHex "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
  var z: StUint[512]
  z.initFromBytesBE(data)
  z >= fieldModulus

func fromBytes*(ret: var BLS_SCALAR, raw: openArray[byte]): bool =
  const L = 32
  if raw.len < L:
    return false
  # Reduced mod the curve order so that blst_p1_mult can take its GLV path.
  # The result only reports whether the scalar is non-zero, which is valid
  # input, so it is discarded.
  discard blst_scalar_from_be_bytes(toCV(ret), raw.toOpenArray(0, L-1))
  true

func fromBytesCanonical*(ret: var BLS_SCALAR, raw: openArray[byte]): bool =
  const L = 32
  if raw.len != L:
    return false
  let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
  blst_scalar_from_bendian(toCV(ret), pa[])
  blst_scalar_fr_check(toCV(ret)).int == 1

func fromBytes(ret: var BLS_FP, raw: openArray[byte]): bool =
  const L = 48
  if raw.len < L:
    return false
  let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
  if isOverModulus(pa[]):
    return false
  blst_fp_from_bendian(toCV(ret), pa[])
  true

func toBytes(fp: BLS_FP, output: var openArray[byte]): bool =
  const L = 48
  if output.len < L:
    return false
  let pa = cast[ptr array[L, byte]](output[0].unsafeAddr)
  blst_bendian_from_fp(pa[], toCC(fp))
  true

func nbits(s: BLS_SCALAR): uint =
  var k = sizeof(s.b) - 1
  while k >= 0 and s.b[k] == 0: dec k
  if k < 0: return 0
  var
    bts = k shl 3
    c = s.b[k]

  while c != 0:
    c = c shr 1
    inc bts

  result = bts.uint

func add*(a: var BLS_G1, b: BLS_G1) {.inline.} =
  blst_p1_add_or_double(toCV(a), toCC(a), toCC(b))

func mul*(a: var BLS_G1, b: BLS_SCALAR) {.inline.} =
  blst_p1_mult(toCV(a), toCV(a), b.b[0].unsafeAddr, b.nbits)

func add*(a: var BLS_G2, b: BLS_G2) {.inline.} =
  blst_p2_add_or_double(toCV(a), toCC(a), toCC(b))

func mul*(a: var BLS_G2, b: BLS_SCALAR) {.inline.} =
  blst_p2_mult(toCV(a), toCV(a), b.b[0].unsafeAddr, b.nbits)

func double*(a: var BLS_G1) {.inline.} =
  blst_p1_double(toCV(a), toCV(a))

func neg*(a: var BLS_G1) {.inline.} =
  blst_p1_cneg(toCV(a), true)

func fromAffine*(a: var BLS_G1, b: BLS_G1P) {.inline.} =
  blst_p1_from_affine(toCV(a), toCC(b))

func fromAffine*(a: var BLS_G2, b: BLS_G2P) {.inline.} =
  blst_p2_from_affine(toCV(a), toCC(b))

func toAffine*(a: var BLS_G1P, b: BLS_G1) {.inline.} =
  blst_p1_to_affine(toCV(a), toCC(b))

func toAffine*(a: var BLS_G2P, b: BLS_G2) {.inline.} =
  blst_p2_to_affine(toCV(a), toCC(b))

func generatorG1*(): BLS_G1P {.inline.} =
  cast[ptr BLS_G1P](blst_p1_affine_generator())[]

func generatorG2*(): BLS_G2P {.inline.} =
  cast[ptr BLS_G2P](blst_p2_affine_generator())[]

func uncompress*(g: var BLS_G1P, data: openArray[byte]): bool =
  const L = 48
  if data.len != L:
    return false
  let pa = cast[ptr array[L, byte]](data[0].unsafeAddr)
  blst_p1_uncompress(toCV(g), pa[]) == BLST_SUCCESS

func uncompress*(g: var BLS_G2P, data: openArray[byte]): bool =
  const L = 96
  if data.len != L:
    return false
  let pa = cast[ptr array[L, byte]](data[0].unsafeAddr)
  blst_p2_uncompress(toCV(g), pa[]) == BLST_SUCCESS

const
  MSMScalarBits = 256

func scratchLen(numBytes: uint): int {.inline.} =
  (numBytes.int + sizeof(limb_t) - 1) div sizeof(limb_t)

func initFixedBase*(g: BLS_G1P): BLS_G1_TABLE =
  doAssert blst_p1s_mult_wbits_precompute_sizeof(
    FixedBaseWBits, FixedBasePoints).int == sizeof(result.table)

  var
    points {.noinit.}: array[FixedBasePoints, BLS_G1P]
    acc {.noinit.}: BLS_G1
  acc.fromAffine(g)

  for i in 0 ..< FixedBasePoints:
    points[i].toAffine(acc)
    for _ in 0 ..< FixedBaseNBits:
      acc.double()

  let p = [toCC(points[0], cblst_p1_affine), nil]
  blst_p1s_mult_wbits_precompute(toCV(result.table[0], cblst_p1_affine),
    FixedBaseWBits, p[0].unsafeAddr, FixedBasePoints)

func mul*(t: BLS_G1_TABLE, s: BLS_SCALAR): BLS_G1 =
  var scratch {.noinit.}: array[FixedBasePoints, BLS_G1]
  let sc = [toCC(s, byte), nil]
  blst_p1s_mult_wbits(toCV(result, cblst_p1),
    toCC(t.table[0], cblst_p1_affine), FixedBaseWBits, FixedBasePoints,
    sc[0].unsafeAddr, FixedBaseNBits, toCV(scratch[0], limb_t))

func multiExp*(acc: var BLS_G1, points: openArray[BLS_G1P],
               scalars: openArray[BLS_SCALAR]) =
  var scratch = newSeq[limb_t](
    scratchLen(blst_p1s_mult_pippenger_scratch_sizeof(points.len.uint)))
  let
    p = [toCC(points[0], cblst_p1_affine), nil]
    s = [toCC(scalars[0], byte), nil]

  blst_p1s_mult_pippenger(toCV(acc), p[0].unsafeAddr, points.len.uint,
    s[0].unsafeAddr, MSMScalarBits, scratch[0].addr)

func multiExp*(acc: var BLS_G2, points: openArray[BLS_G2P],
               scalars: openArray[BLS_SCALAR]) =
  var scratch = newSeq[limb_t](
    scratchLen(blst_p2s_mult_pippenger_scratch_sizeof(points.len.uint)))
  let
    p = [toCC(points[0], cblst_p2_affine), nil]
    s = [toCC(scalars[0], byte), nil]

  blst_p2s_mult_pippenger(toCV(acc), p[0].unsafeAddr, points.len.uint,
    s[0].unsafeAddr, MSMScalarBits, scratch[0].addr)

func mapFPToG1*(fp: BLS_FP): BLS_G1 {.inline.} =
  blst_map_to_g1(toCV(result), toCC(fp), nil)

func mapFPToG2*(fp: BLS_FP2): BLS_G2 {.inline.} =
  blst_map_to_g2(toCV(result), toCC(fp), nil)

func subgroupCheck*(P: BLS_G1): bool {.inline.} =
  blst_p1_in_g1(toCC(P)).int == 1

func subgroupCheck*(P: BLS_G2): bool {.inline.} =
  blst_p2_in_g2(toCC(P)).int == 1

func subgroupCheck*(P: BLS_G1P): bool {.inline.} =
  blst_p1_affine_in_g1(toCC(P)).int == 1

func subgroupCheck*(P: BLS_G2P): bool {.inline.} =
  blst_p2_affine_in_g2(toCC(P)).int == 1

func isInf*(P: BLS_G1P): bool {.inline.} =
  blst_p1_affine_is_inf(toCC(P)).int == 1

func isInf*(P: BLS_G2P): bool {.inline.} =
  blst_p2_affine_is_inf(toCC(P)).int == 1

func millerLoop*(P: BLS_G1P, Q: BLS_G2P): BLS_ACC {.inline.} =
  blst_miller_loop(toCV(result), toCC(Q), toCC(P))

func precomputeLines*(lines: var BLS_LINES, Q: BLS_G2P) {.inline.} =
  blst_precompute_lines(lines, toCC(Q))

func millerLoop*(P: BLS_G1P, lines: BLS_LINES): BLS_ACC {.inline.} =
  blst_miller_loop_lines(toCV(result), lines, toCC(P))

proc mul*(a: var BLS_ACC, b: BLS_ACC) {.inline.} =
  blst_fp12_mul(toCV(a), toCC(a), toCC(b))

func check*(x: BLS_ACC): bool {.inline.} =
  var ret: BLS_ACC
  blst_final_exp(toCV(ret), toCC(x))
  blst_fp12_is_one(toCV(ret)).int == 1

# decodeFE expects 64 byte input with zero top 16 bytes,
# returns lower 48 bytes.
func decodeFE*(res: var BLS_FP, input: openArray[byte]): bool =
  if input.len != 64:
    return false

  # check top bytes
  for i in 0..<16:
    if input[i] != 0.byte:
      return false

  res.fromBytes input.toOpenArray(16, 63)

func decodeFE*(res: var BLS_FP2, input: openArray[byte]): bool =
  if input.len != 128:
    return false

  if res.fp[0].decodeFE(input.toOpenArray(0, 63)) and
     res.fp[1].decodeFE(input.toOpenArray(64, 127)):
     result = true

# DecodePoint given encoded (x, y) coordinates in 128 bytes returns a valid G1 Point.
func decodePoint*(g: var BLS_G1P, data: openArray[byte]): bool =
  if data.len != 128:
    return false

  if not g.x.decodeFE(data.toOpenArray(0, 63)):
    return false
  if not g.y.decodeFE(data.toOpenArray(64, 127)):
    return false

  blst_p1_affine_on_curve(toCV(g)).int == 1

func decodePoint*(g: var BLS_G1, data: openArray[byte]): bool =
  if data.len != 128:
    return false

  var src {.noinit.}: blst_p1_affine
  if not src.x.decodeFE(data.toOpenArray(0, 63)):
    return false

  if not src.y.decodeFE(data.toOpenArray(64, 127)):
    return false

  blst_p1_from_affine(toCV(g), toCC(src))
  blst_p1_on_curve(toCV(g)).int == 1

# EncodePoint encodes a point into 128 bytes.
func encodePoint*(g: BLS_G1, output: var openArray[byte]): bool =
  if output.len != 128:
    return false

  var dst {.noinit.}: blst_p1_affine
  blst_p1_to_affine(toCV(dst), toCC(g))
  if not dst.x.toBytes(output.toOpenArray(16, 63)):
    return false

  if not dst.y.toBytes(output.toOpenArray(64+16, 127)):
    return false

  true

# DecodePoint given encoded (x, y) coordinates in 256 bytes returns a valid G2 Point.
func decodePoint*(g: var BLS_G2P, data: openArray[byte]): bool =
  if data.len != 256:
    return false

  if not g.x.fp[0].decodeFE(data.toOpenArray(0, 63)):
    return false

  if not g.x.fp[1].decodeFE(data.toOpenArray(64, 127)):
    return false

  if not g.y.fp[0].decodeFE(data.toOpenArray(128, 191)):
    return false

  if not g.y.fp[1].decodeFE(data.toOpenArray(192, 255)):
    return false

  blst_p2_affine_on_curve(toCV(g)).int == 1

func decodePoint*(g: var BLS_G2, data: openArray[byte]): bool =
  if data.len != 256:
    return false

  var src {.noinit.}: blst_p2_affine
  if not src.x.fp[0].decodeFE(data.toOpenArray(0, 63)):
    return false

  if not src.x.fp[1].decodeFE(data.toOpenArray(64, 127)):
    return false

  if not src.y.fp[0].decodeFE(data.toOpenArray(128, 191)):
    return false

  if not src.y.fp[1].decodeFE(data.toOpenArray(192, 255)):
    return false

  blst_p2_from_affine(toCV(g), toCC(src))
  blst_p2_on_curve(toCV(g)).int == 1

# EncodePoint encodes a point into 256 bytes.
func encodePoint*(g: BLS_G2, output: var openArray[byte]): bool =
  if output.len != 256:
    return false

  var dst {.noinit.}: blst_p2_affine
  blst_p2_to_affine(toCV(dst), toCC(g))

  if not dst.x.fp[0].toBytes(output.toOpenArray(16, 63)):
    return false

  if not dst.x.fp[1].toBytes(output.toOpenArray(80, 127)):
    return false

  if not dst.y.fp[0].toBytes(output.toOpenArray(144, 192)):
    return false

  if not dst.y.fp[1].toBytes(output.toOpenArray(208, 255)):
    return false

  true
