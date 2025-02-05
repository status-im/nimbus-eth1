# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import blscurve/bls_backend, stint

import blscurve/blst/[blst_lowlevel]

type
  BLS_G1* = blst_p1
  BLS_G2* = blst_p2
  BLS_FP* = blst_fp
  BLS_FP2* = blst_fp2
  BLS_SCALAR* = blst_scalar
  BLS_FE* = blst_fp
  BLS_FE2* = blst_fp2
  BLS_ACC* = blst_fp12
  BLS_G1P* = blst_p1_affine
  BLS_G2P* = blst_p2_affine

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

func fromBytes*(ret: var BLS_SCALAR, raw: openArray[byte]): bool =
  const L = 32
  if raw.len < L:
    return false
  let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
  blst_scalar_from_bendian(toCV(ret), pa[])
  true

func fromBytes(ret: var BLS_FP, raw: openArray[byte]): bool =
  const L = 48
  if raw.len < L:
    return false
  let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
  debugEcho "Original Data: ", pa[]
  blst_fp_from_bendian(toCV(ret), pa[])
  debugEcho "Montogomery domain: ", ret
  true

func toBytes(fp: BLS_FP, output: var openArray[byte]): bool =
  const L = 48
  if output.len < L:
    return false
  let pa = cast[ptr array[L, byte]](output[0].unsafeAddr)
  blst_bendian_from_fp(pa[], toCC(fp))
  true

func pack(g: var BLS_G1, x, y: BLS_FP): bool =
  let src = blst_p1_affine(x: x, y: y)
  blst_p1_from_affine(toCV(g), toCC(src))
  blst_p1_on_curve(toCV(g)).int == 1

func unpack(g: BLS_G1, x, y: var BLS_FP): bool =
  var dst: blst_p1_affine
  blst_p1_to_affine(toCV(dst), toCC(g))
  x = dst.x
  y = dst.y
  true

func pack(g: var BLS_G2, x0, x1, y0, y1: BLS_FP): bool =
  let src = blst_p2_affine(x: blst_fp2(fp: [x0, x1]), y: blst_fp2(fp: [y0, y1]))
  blst_p2_from_affine(toCV(g), toCC(src))
  blst_p2_on_curve(toCV(g)).int == 1

func unpack(g: BLS_G2, x0, x1, y0, y1: var BLS_FP): bool =
  var dst: blst_p2_affine
  blst_p2_to_affine(toCV(dst), toCC(g))
  x0 = dst.x.fp[0]
  x1 = dst.x.fp[1]
  y0 = dst.y.fp[0]
  y1 = dst.y.fp[1]
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

func mapFPToG1*(fp: BLS_FE): BLS_G1 {.inline.} =
  blst_map_to_g1(toCV(result), toCC(fp), nil)

func mapFPToG2*(fp: BLS_FE2): BLS_G2 {.inline.} =
  blst_map_to_g2(toCV(result), toCC(fp), nil)

func pack(g: var BLS_G1P, x, y: BLS_FP): bool =
  g = blst_p1_affine(x: x, y: y)
  blst_p1_affine_on_curve(toCV(g)).int == 1

func pack(g: var BLS_G2P, x0, x1, y0, y1: BLS_FP): bool =
  g = blst_p2_affine(x: blst_fp2(fp: [x0, x1]), y: blst_fp2(fp: [y0, y1]))
  blst_p2_affine_on_curve(toCV(g)).int == 1

func subgroupCheck*(P: BLS_G1P): bool {.inline.} =
  blst_p1_affine_in_g1(toCC(P)).int == 1

func subgroupCheck*(P: BLS_G2P): bool {.inline.} =
  blst_p2_affine_in_g2(toCC(P)).int == 1

func millerLoop*(P: BLS_G1P, Q: BLS_G2P): BLS_ACC {.inline.} =
  blst_miller_loop(toCV(result), toCC(Q), toCC(P))

proc mul*(a: var BLS_ACC, b: BLS_ACC) {.inline.} =
  blst_fp12_mul(toCV(a), toCC(a), toCC(b))

func check*(x: BLS_ACC): bool {.inline.} =
  var ret: BLS_ACC
  blst_final_exp(toCV(ret), toCC(x))
  blst_fp12_is_one(toCV(ret)).int == 1

# decodeFieldElement expects 64 byte input with zero top 16 bytes,
# returns lower 48 bytes.
func decodeFieldElement*(res: var BLS_FP, input: openArray[byte]): bool =
  if input.len != 64:
    return false

  # check top bytes
  for i in 0..<16:
    if input[i] != 0.byte:
      return false

  res.fromBytes input.toOpenArray(16, 63)

func decodeFE*(res: var BLS_FE, input: openArray[byte]): bool =
  const
    fieldModulus = StUint[512].fromHex "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
  if not res.decodeFieldElement(input):
    return false
  var z: StUint[512]
  z.initFromBytesBE(input)
  z < fieldModulus

func decodeFE*(res: var BLS_FE2, input: openArray[byte]): bool =
  if input.len != 128:
    return false

  if res.fp[0].decodeFE(input.toOpenArray(0, 63)) and
     res.fp[1].decodeFE(input.toOpenArray(64, 127)):
     result = true

# DecodePoint given encoded (x, y) coordinates in 128 bytes returns a valid G1 Point.
func decodePoint*(g: var (BLS_G1 | BLS_G1P), data: openArray[byte]): bool =
  if data.len != 128:
    return false

  var x, y: BLS_FP
  if x.decodeFieldElement(data.toOpenArray(0, 63)) and
     y.decodeFieldElement(data.toOpenArray(64, 127)):
     result = g.pack(x, y)

# EncodePoint encodes a point into 128 bytes.
func encodePoint*(g: BLS_G1, output: var openArray[byte]): bool =
  if output.len != 128:
    return false

  var x, y: BLS_FP
  if g.unpack(x, y) and
     x.toBytes(output.toOpenArray(16, 63)) and
     y.toBytes(output.toOpenArray(64+16, 127)):
     result = true

# DecodePoint given encoded (x, y) coordinates in 256 bytes returns a valid G2 Point.
func decodePoint*(g: var (BLS_G2 | BLS_G2P), data: openArray[byte]): bool =
  if data.len != 256:
    return false

  var x0, x1, y0, y1: BLS_FP
  if x0.decodeFieldElement(data.toOpenArray(0, 63)) and
     x1.decodeFieldElement(data.toOpenArray(64, 127)) and
     y0.decodeFieldElement(data.toOpenArray(128, 191)) and
     y1.decodeFieldElement(data.toOpenArray(192, 255)):
     result = g.pack(x0, x1, y0, y1)

# EncodePoint encodes a point into 256 bytes.
func encodePoint*(g: BLS_G2, output: var openArray[byte]): bool =
  if output.len != 256:
    return false

  var x0, x1, y0, y1: BLS_FP
  if g.unpack(x0, x1, y0, y1) and
     x0.toBytes(output.toOpenArray(16, 63)) and
     x1.toBytes(output.toOpenArray(80, 127)) and
     y0.toBytes(output.toOpenArray(144, 192)) and
     y1.toBytes(output.toOpenArray(208, 255)):
     result = true
