# Nimbus
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import blscurve/bls_backend, stint, stint/endians2

import blscurve/blst/[blst_lowlevel]

type
  BLS_G1* = blst_p1
  BLS_G2* = blst_p2
  BLS_FP* = blst_fp
  BLS_FP2* = blst_fp2
  BLS_SCALAR* = blst_scalar
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

const
  # BLS12-381 base field modulus p, big-endian. Derived from the canonical hex
  # at compile time so the value has a single source of truth.
  FieldModulusBE = StUint[384].fromHex(
    "0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab"
  ).toBytesBE()

func isOverModulus(data: openArray[byte]): bool {.inline.} =
  ## True when the 48-byte big-endian value is >= the base field modulus p,
  ## i.e. not a canonical field element (EIP-2537 requires coordinates < p).
  ## Lexicographic big-endian compare that exits at the first differing byte;
  ## the inputs are public, so the data-dependent early-out is fine.
  for i in 0 ..< 48:
    if data[i] != FieldModulusBE[i]:
      return data[i] > FieldModulusBE[i]
  true  # value == p -> not < p -> reject

func fromBytes*(ret: var BLS_SCALAR, raw: openArray[byte]): bool =
  const L = 32
  if raw.len < L:
    return false
  # Reduced mod the curve order so that blst_p1_mult can take its GLV path.
  # The result only reports whether the scalar is non-zero, which is valid
  # input, so it is discarded.
  discard blst_scalar_from_be_bytes(toCV(ret), raw.toOpenArray(0, L-1))
  true

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

func fromAffine*(a: var BLS_G1, b: BLS_G1P) {.inline.} =
  blst_p1_from_affine(toCV(a), toCC(b))

func fromAffine*(a: var BLS_G2, b: BLS_G2P) {.inline.} =
  blst_p2_from_affine(toCV(a), toCC(b))

const
  MSMScalarBits = 256

func scratchLen(numBytes: uint): int {.inline.} =
  (numBytes.int + sizeof(limb_t) - 1) div sizeof(limb_t)

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

func isZero(a: BLS_FP): bool {.inline.} =
  (a.l[0] or a.l[1] or a.l[2] or a.l[3] or a.l[4] or a.l[5]) == 0

func isZero(a: BLS_FP2): bool {.inline.} =
  a.fp[0].isZero and a.fp[1].isZero

# Variable-time affine+affine -> Jacobian point addition (Cohen et al. 1998).
# Both operands are affine (Z=1), so the generic case costs only 4M+2S versus
# 8M+5S for blst's mixed `blst_pX_add_or_double_affine` (which still handles a
# projective first operand). This is NOT constant-time — it is only valid for
# public inputs such as the G1ADD/G2ADD precompile operands, which the EIP does
# not subgroup-check. Doubling, P == -Q, and points at infinity are branched
# out explicitly, matching the blst reference behaviour those cases produce.
func sumAffines*(r: var BLS_G1, p, q: BLS_G1P) =
  if p.isInf:
    r.fromAffine(q); return
  if q.isInf:
    r.fromAffine(p); return

  template sub(rr, a, b: untyped) = blst_fp_sub(toCV(rr), toCC(a), toCC(b))
  template mul(rr, a, b: untyped) = blst_fp_mul(toCV(rr), toCC(a), toCC(b))
  template sqr(rr, a: untyped)    = blst_fp_sqr(toCV(rr), toCC(a))

  var h, rn, hh, hhh, v, t {.noinit.}: BLS_FP
  sub(h,  q.x, p.x)          # H = Qx - Px
  sub(rn, q.y, p.y)          # R = Qy - Py
  if h.isZero:
    if rn.isZero:            # P == Q -> doubling
      r.fromAffine(p)
      blst_p1_double(toCV(r), toCC(r))
    else:                    # P == -Q -> point at infinity
      zeroMem(addr r, sizeof(r))
    return

  sqr(hh, h)                 # HH  = H^2
  mul(v, p.x, hh)            # V   = Px*HH
  mul(hhh, h, hh)            # HHH = H^3
  sqr(t, rn)                 # t   = R^2
  sub(t, t, v)
  sub(t, t, v)               # t   = R^2 - 2V
  sub(r.x, t, hhh)           # X3  = R^2 - 2V - HHH
  sub(t, v, r.x)             # t   = V - X3
  mul(t, t, rn)              # t   = R*(V - X3)
  mul(v, hhh, p.y)           # v   = Py*HHH
  sub(r.y, t, v)             # Y3  = R*(V - X3) - Py*HHH
  r.z = h                    # Z3  = H (Z1 = Z2 = 1)

func sumAffines*(r: var BLS_G2, p, q: BLS_G2P) =
  if p.isInf:
    r.fromAffine(q); return
  if q.isInf:
    r.fromAffine(p); return

  template sub(rr, a, b: untyped) = blst_fp2_sub(toCV(rr), toCC(a), toCC(b))
  template mul(rr, a, b: untyped) = blst_fp2_mul(toCV(rr), toCC(a), toCC(b))
  template sqr(rr, a: untyped)    = blst_fp2_sqr(toCV(rr), toCC(a))

  var h, rn, hh, hhh, v, t {.noinit.}: BLS_FP2
  sub(h,  q.x, p.x)          # H = Qx - Px
  sub(rn, q.y, p.y)          # R = Qy - Py
  if h.isZero:
    if rn.isZero:            # P == Q -> doubling
      r.fromAffine(p)
      blst_p2_double(toCV(r), toCC(r))
    else:                    # P == -Q -> point at infinity
      zeroMem(addr r, sizeof(r))
    return

  sqr(hh, h)                 # HH  = H^2
  mul(v, p.x, hh)            # V   = Px*HH
  mul(hhh, h, hh)            # HHH = H^3
  sqr(t, rn)                 # t   = R^2
  sub(t, t, v)
  sub(t, t, v)               # t   = R^2 - 2V
  sub(r.x, t, hhh)           # X3  = R^2 - 2V - HHH
  sub(t, v, r.x)             # t   = V - X3
  mul(t, t, rn)              # t   = R*(V - X3)
  mul(v, hhh, p.y)           # v   = Py*HHH
  sub(r.y, t, v)             # Y3  = R*(V - X3) - Py*HHH
  r.z = h                    # Z3  = H (Z1 = Z2 = 1)

func millerLoop*(P: BLS_G1P, Q: BLS_G2P): BLS_ACC {.inline.} =
  blst_miller_loop(toCV(result), toCC(Q), toCC(P))

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

  # The top 16 bytes of the 64-byte field encoding must be zero. Check them as
  # two word-sized loads rather than a byte loop (endianness is irrelevant for a
  # zero test).
  var hi0, hi1: uint64
  copyMem(addr hi0, unsafeAddr input[0], sizeof(hi0))
  copyMem(addr hi1, unsafeAddr input[8], sizeof(hi1))
  if (hi0 or hi1) != 0:
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
