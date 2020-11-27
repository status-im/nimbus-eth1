import blscurve/bls_backend

when BLS_BACKEND == Miracl:
  import blscurve/miracl/[common, milagro]
  export common

  type
    BLS_G1* = ECP_BLS12381
    BLS_G2* = ECP2_BLS12381
    BLS_FP* = BIG_384
    BLS_FP2* = FP2_BLS12381
    BLS_SCALAR* = BIG_384
    BLS_FE* = FP_BLS12381
    BLS_FE2* = FP2_BLS12381

  proc ECP_BLS12381_map2point(P: var ECP_BLS12381, h: FP_BLS12381) {.importc, cdecl.}
  proc ECP2_BLS12381_map2point(P: var ECP2_BLS12381, h: FP2_BLS12381) {.importc, cdecl.}
  proc ECP_BLS12381_set(p: ptr ECP_BLS12381, x, y: BIG_384): cint {.importc, cdecl.}
  proc FP_BLS12381_sqr(w: ptr FP_BLS12381, x: ptr FP_BLS12381) {.importc, cdecl.}

  proc sqr*(x: FP_BLS12381): FP_BLS12381 {.inline.} =
    ## Retruns ``x ^ 2``.
    FP_BLS12381_sqr(addr result, unsafeAddr x)

  proc rhs*(x: FP_BLS12381): FP_BLS12381 {.inline.} =
    ## Returns ``x ^ 3 + b``.
    ECP_BLS12381_rhs(addr result, unsafeAddr x)

  proc isOnCurv*(x, y: FP_BLS12381 or FP2_BLS12381): bool =
    ## Returns ``true`` if point is on curve or points to infinite.
    if x.iszilch() and y.iszilch():
      result = true
    else:
      result = (sqr(y) == rhs(x))

  func pack(g: var BLS_G1, x, y: BLS_FP): bool {.inline.} =
    discard ECP_BLS12381_set(g.addr, x, y)
    let xx = x.nres
    let yy = y.nres
    isOnCurv(xx, yy)

  func unpack(g: BLS_G1, x, y: var BLS_FP): bool {.inline.} =
    discard g.get(x, y)
    true

  func pack(g: var BLS_G2, x0, x1, y0, y1: BLS_FP): bool =
    var x, y: BLS_FP2
    x.fromBigs(x0, x1)
    y.fromBigs(y0, y1)
    discard ECP2_BLS12381_set(g.addr, x.addr, y.addr)
    isOnCurv(x, y)

  func unpack(g: BLS_G2, x0, x1, y0, y1: var BLS_FP): bool =
    var x, y: BLS_FP2
    result = g.get(x, y) <= 0.cint
    FP_BLS12381_redc(x0, addr x.a)
    FP_BLS12381_redc(x1, addr x.b)
    FP_BLS12381_redc(y0, addr y.a)
    FP_BLS12381_redc(y1, addr y.b)

else:
  import blscurve/blst/[blst_lowlevel]

  type
    BLS_G1* = blst_p1
    BLS_G2* = blst_p2
    BLS_FP* = blst_fp
    BLS_FP2* = blst_fp2
    BLS_SCALAR* = blst_scalar
    BLS_FE* = blst_fp
    BLS_FE2* = blst_fp2

  func fromBytes*(ret: var BLS_SCALAR, raw: openArray[byte]): bool =
    const L = 32
    if raw.len < L:
      return false
    let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
    blst_scalar_from_bendian(ret, pa[])
    true

  func fromBytes(ret: var BLS_FP, raw: openArray[byte]): bool =
    const L = 48
    if raw.len < L:
      return false
    let pa = cast[ptr array[L, byte]](raw[0].unsafeAddr)
    blst_fp_from_bendian(ret, pa[])
    true

  func toBytes(fp: BLS_FP, output: var openArray[byte]): bool =
    const L = 48
    if output.len < L:
      return false
    let pa = cast[ptr array[L, byte]](output[0].unsafeAddr)
    blst_bendian_from_fp(pa[], fp)
    true

  func pack(g: var BLS_G1, x, y: BLS_FP): bool =
    let src = blst_p1_affine(x: x, y: y)
    blst_p1_from_affine(g, src)
    blst_p1_on_curve(g).int == 1

  func unpack(g: BLS_G1, x, y: var BLS_FP): bool =
    var dst: blst_p1_affine
    blst_p1_to_affine(dst, g)
    x = dst.x
    y = dst.y
    true

  func pack(g: var BLS_G2, x0, x1, y0, y1: BLS_FP): bool =
    let src = blst_p2_affine(x: blst_fp2(fp: [x0, x1]), y: blst_fp2(fp: [y0, y1]))
    blst_p2_from_affine(g, src)
    blst_p2_on_curve(g)

  func unpack(g: BLS_G2, x0, x1, y0, y1: var BLS_FP): bool =
    var dst: blst_p2_affine
    blst_p2_to_affine(dst, g)
    x0 = dst.x.fp[0]
    x1 = dst.x.fp[1]
    y0 = dst.y.fp[0]
    y1 = dst.y.fp[1]
    true

  func nbits(s: BLS_SCALAR): uint =
    var k = sizeof(s.l) - 1
    while k >= 0 and s.l[k] == 0: dec k
    if k < 0: return 0
    var
      bts = k shl 3
      c = s.l[k]

    while c != 0:
      c = c shr 1
      inc bts

    result = bts.uint

  func add*(a: var BLS_G1, b: BLS_G1) {.inline.} =
    # ?? add_or_double ??
    blst_p1_add_or_double(a, a, b)

  func mul*(a: var BLS_G1, b: BLS_SCALAR) {.inline.} =
    blst_p1_mult(a, a, b, b.nbits)

  func add*(a: var BLS_G2, b: BLS_G2) {.inline.} =
    # ?? add_or_double ??
    blst_p2_add_or_double(a, a, b)

  func mul*(a: var BLS_G2, b: BLS_SCALAR) {.inline.} =
    blst_p2_mult(a, a, b, b.nbits)

# decodeFieldElement expects 64 byte input with zero top 16 bytes,
# returns lower 48 bytes.
func decodeFieldElement*(res: var BLS_FP, input: openArray[byte]): bool =
  if input.len != 64:
    debugEcho "DEF A ERR"
    return false

  # check top bytes
  for i in 0..<16:
    if input[i] != 0.byte:
      debugEcho "DEF B ERR"
      return false

  if not res.fromBytes input.toOpenArray(16, 63):
    debugEcho "DEF C ERR"
    return false

  true

when BLS_BACKEND == Miracl:
  func decodeFieldElement*(res: var BLS_FE, input: openArray[byte]): bool =
    var big: BLS_FP
    if not big.decodeFieldElement(input):
      return false
    res = big.nres()
    true

# DecodePoint given encoded (x, y) coordinates in 128 bytes returns a valid G1 Point.
func decodePoint*(g: var BLS_G1, data: openArray[byte]): bool =
  if data.len != 128:
    debugEcho "G1 init A ERR"
    return false

  var x, y: BLS_FP
  if not x.decodeFieldElement data.toOpenArray(0, 63):
    return false

  if not y.decodeFieldElement data.toOpenArray(64, 127):
    return false

  if not g.pack(x, y):
    debugEcho "ECP set err"
    return false

  true

# EncodePoint encodes a point into 128 bytes.
func encodePoint*(g: BLS_G1, output: var openArray[byte]): bool =
  if output.len != 128:
    debugEcho "encodePoint ERR"
    return false

  var x, y: BLS_FP
  if not g.unpack(x, y):
    debugEcho "encodePoint get"
    return false

  if not x.toBytes output.toOpenArray(16, 63):
    debugEcho "encodePoint ERR X"
    return false

  if not y.toBytes output.toOpenArray(64+16, 127):
    debugEcho "encodePoint ERR Y"
    return false

  true

func decodePoint*(g: var BLS_G2, data: openArray[byte]): bool =
  if data.len != 256:
    debugEcho "G2 init ERR"
    return false

  var x0, x1, y0, y1: BLS_FP
  if not x0.decodeFieldElement data.toOpenArray(0, 63):
    return false

  if not x1.decodeFieldElement data.toOpenArray(64, 127):
    return false

  if not y0.decodeFieldElement data.toOpenArray(128, 191):
    return false

  if not y1.decodeFieldElement data.toOpenArray(192, 255):
    return false

  if not g.pack(x0, x1, y0, y1):
    debugEcho "G2 pack err"
    return false

  true

func encodePoint*(g: BLS_G2, output: var openArray[byte]): bool =
  if output.len != 256:
    debugEcho "encodePoint G2 ERR"
    return false

  var x0, x1, y0, y1: BLS_FP
  if not g.unpack(x0, x1, y0, y1):
    debugEcho "encodePoint G2 get"
    return false

  if not x0.toBytes output.toOpenArray(16, 63):
    debugEcho "encodePoint G2 ERR X0"
    return false

  if not x1.toBytes output.toOpenArray(80, 127):
    debugEcho "encodePoint G2 ERR X1"
    return false

  if not y0.toBytes output.toOpenArray(144, 192):
    debugEcho "encodePoint G2 ERR Y0"
    return false

  if not y1.toBytes output.toOpenArray(208, 255):
    debugEcho "encodePoint G2 ERR Y1"
    return false

  true
