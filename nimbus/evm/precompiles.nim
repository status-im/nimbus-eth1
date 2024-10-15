# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[macros],
  results,
  "."/[types, blake2b_f, blscurve],
  ./interpreter/[gas_meter, gas_costs, utils/utils_numeric],
  eth/common/keys,
  chronicles,
  nimcrypto/[ripemd, sha2, utils],
  bncurve/[fields, groups],
  stew/assign2,
  ../common/evmforks,
  ../core/eip4844,
  ./modexp,
  ./evm_errors,
  ./computation,
  eth/common/[base, addresses]

type
  PrecompileAddresses* = enum
    # Frontier to Spurious Dragron
    paEcRecover  = 0x01,
    paSha256     = 0x02,
    paRipeMd160  = 0x03,
    paIdentity   = 0x04,
    # Byzantium and Constantinople
    paModExp     = 0x05,
    paEcAdd      = 0x06,
    paEcMul      = 0x07,
    paPairing    = 0x08,
    # Istanbul
    paBlake2bf   = 0x09,
    # Cancun
    paPointEvaluation = 0x0A,
    # Prague (EIP-2537)
    paBlsG1Add   = 0x0b,
    paBlsG1Mul   = 0x0c,
    paBlsG1MultiExp = 0x0d,
    paBlsG2Add   = 0x0e,
    paBlsG2Mul   = 0x0f,
    paBlsG2MultiExp = 0x10,
    paBlsPairing = 0x11,
    paBlsMapG1 = 0x12,
    paBlsMapG2 = 0x13

  SigRes = object
    msgHash: array[32, byte]
    sig: Signature

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func getMaxPrecompileAddr(fork: EVMFork): PrecompileAddresses =
  if fork < FkByzantium: paIdentity
  elif fork < FkIstanbul: paPairing
  elif fork < FkCancun: paBlake2bf
  elif fork < FkPrague: paPointEvaluation
  else: PrecompileAddresses.high

func validPrecompileAddr(addrByte, maxPrecompileAddr: byte): bool =
  (addrByte in PrecompileAddresses.low.byte .. maxPrecompileAddr)

func validPrecompileAddr(addrByte: byte, fork: EVMFork): bool =
  let maxPrecompileAddr = getMaxPrecompileAddr(fork)
  validPrecompileAddr(addrByte, maxPrecompileAddr.byte)

func getSignature(c: Computation): EvmResult[SigRes]  =
  # input is Hash, V, R, S
  template data: untyped = c.msg.data
  var bytes: array[65, byte] # will hold R[32], S[32], V[1], in that order
  let maxPos = min(data.high, 127)

  # if we don't have at minimum 64 bytes, there can be no valid V
  if maxPos < 63:
    return err(prcErr(PrcInvalidSig))

  let v = data[63]
  # check if V[32] is 27 or 28
  if not (v.int in 27..28):
    return err(prcErr(PrcInvalidSig))
  for x in 32..<63:
    if data[x] != 0:
      return err(prcErr(PrcInvalidSig))

  bytes[64] = v - 27

  # if there is more data for R and S, copy it. Else, defaulted zeroes are
  # used for R and S
  if maxPos >= 64:
    # Copy message data to buffer
    bytes[0..(maxPos-64)] = data[64..maxPos]

  let sig = Signature.fromRaw(bytes).valueOr:
    return err(prcErr(PrcInvalidSig))
  var res = SigRes(sig: sig)

  # extract message hash, only need to copy when there is a valid signature
  assign(res.msgHash, data.toOpenArray(0, 31))
  ok(res)

func simpleDecode(dst: var FQ2, src: openArray[byte]): bool {.noinit.} =
  # bypassing FQ2.fromBytes
  # because we want to check `value > modulus`
  result = false
  if dst.c1.fromBytes(src.toOpenArray(0, 31)) and
     dst.c0.fromBytes(src.toOpenArray(32, 63)):
    result = true

template simpleDecode(dst: var FQ, src: openArray[byte]): bool =
  fromBytes(dst, src)

func getPoint[T: G1|G2](_: typedesc[T], data: openArray[byte]): EvmResult[Point[T]] =
  when T is G1:
    const nextOffset = 32
    var px, py: FQ
  else:
    const nextOffset = 64
    var px, py: FQ2

  if not px.simpleDecode(data.toOpenArray(0, nextOffset - 1)):
    return err(prcErr(PrcInvalidPoint))
  if not py.simpleDecode(data.toOpenArray(nextOffset, nextOffset * 2 - 1)):
    return err(prcErr(PrcInvalidPoint))

  if px.isZero() and py.isZero():
    ok(T.zero())
  else:
    var ap: AffinePoint[T]
    if not ap.init(px, py):
      return err(prcErr(PrcInvalidPoint))
    ok(ap.toJacobian())

func getFR(data: openArray[byte]): EvmResult[FR] =
  var res: FR
  if not res.fromBytes2(data):
    return err(prcErr(PrcInvalidPoint))
  ok(res)

# ------------------------------------------------------------------------------
# Precompiles functions
# ------------------------------------------------------------------------------

func ecRecover(c: Computation): EvmResultVoid =
  ? c.gasMeter.consumeGas(
    GasECRecover,
    reason="ECRecover Precompile")

  let
    sig = ? c.getSignature()
    pubkey = recover(sig.sig, SkMessage(sig.msgHash)).valueOr:
      return err(prcErr(PrcInvalidSig))

  c.output.setLen(32)
  assign(c.output.toOpenArray(12, 31), pubkey.toCanonicalAddress().data)
  ok()

func sha256(c: Computation): EvmResultVoid =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasSHA256 + wordCount.GasInt * GasSHA256Word

  ? c.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  assign(c.output, sha2.sha256.digest(c.msg.data).data)
  ok()

func ripemd160(c: Computation): EvmResultVoid =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasRIPEMD160 + wordCount.GasInt * GasRIPEMD160Word

  ? c.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  c.output.setLen(32)
  assign(c.output.toOpenArray(12, 31), ripemd.ripemd160.digest(c.msg.data).data)
  ok()

func identity(c: Computation): EvmResultVoid =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasIdentity + wordCount.GasInt * GasIdentityWord

  ? c.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  assign(c.output, c.msg.data)
  ok()

func modExpFee(c: Computation,
               baseLen, expLen, modLen: UInt256,
               fork: EVMFork): EvmResult[GasInt] =
  template data: untyped {.dirty.} =
    c.msg.data

  func mulComplexity(x: UInt256): UInt256 =
    ## Estimates the difficulty of Karatsuba multiplication
    if x <= 64.u256: x * x
    elif x <= 1024.u256: x * x div 4.u256 + 96.u256 * x - 3072.u256
    else: x * x div 16.u256 + 480.u256 * x - 199680.u256

  func mulComplexityEIP2565(x: UInt256): UInt256 =
    # gas = ceil(x div 8) ^ 2
    result = x + 7
    result = result div 8
    result = result * result

  let adjExpLen = block:
    let
      baseL = baseLen.safeInt
      expL = expLen.safeInt
      first32 = if baseL.uint64 + expL.uint64 < high(int32).uint64 and baseL < data.len:
                  data.rangeToPadded[:UInt256](96 + baseL, 95 + baseL + expL, min(expL, 32))
                else:
                  0.u256

    if expLen <= 32:
      if first32.isZero(): 0.u256
      else: first32.log2.u256    # highest-bit in exponent
    else:
      if not first32.isZero:
        8.u256 * (expLen - 32.u256) + first32.log2.u256
      else:
        8.u256 * (expLen - 32.u256)

  template gasCalc(comp, divisor: untyped): untyped =
    (
      max(modLen, baseLen).comp *
      max(adjExpLen, 1.u256)
    ) div divisor

  # EIP2565: modExp gas cost
  let gasFee = if fork >= FkBerlin: gasCalc(mulComplexityEIP2565, GasQuadDivisorEIP2565)
               else: gasCalc(mulComplexity, GasQuadDivisor)

  if gasFee > high(GasInt).u256:
    return err(gasErr(OutOfGas))

  var res = gasFee.truncate(GasInt)
  # EIP2565: modExp gas cost
  if fork >= FkBerlin and res < 200.GasInt:
    res = 200.GasInt
  ok(res)

func modExp(c: Computation, fork: EVMFork = FkByzantium): EvmResultVoid =
  ## Modular exponentiation precompiled contract
  ## Yellow Paper Appendix E
  ## EIP-198 - https://github.com/ethereum/EIPs/blob/master/EIPS/eip-198.md
  # Parsing the data
  template data: untyped {.dirty.} =
    c.msg.data

  let # lengths Base, Exponent, Modulus
    baseL = data.rangeToPadded[:UInt256](0, 31, 32)
    expL  = data.rangeToPadded[:UInt256](32, 63, 32)
    modL  = data.rangeToPadded[:UInt256](64, 95, 32)
    baseLen = baseL.safeInt
    expLen  = expL.safeInt
    modLen  = modL.safeInt

  let gasFee = ? modExpFee(c, baseL, expL, modL, fork)
  ? c.gasMeter.consumeGas(gasFee, reason="ModExp Precompile")

  if baseLen == 0 and modLen == 0:
    # This is a special case where expLength can be very big.
    c.output = @[]
    return ok()

  const maxSize = int32.high.u256
  if baseL > maxSize or expL > maxSize or modL > maxSize:
    return err(prcErr(PrcInvalidParam))

  # TODO:
  # add EVM special case:
  # - modulo <= 1: return zero
  # - exp == zero: return one

  let output = modExp(
    data.rangeToPadded(96, baseLen),
    data.rangeToPadded(96 + baseLen, expLen),
    data.rangeToPadded(96 + baseLen + expLen, modLen)
  )

  # maximum output len is the same as modLen
  # if it less than modLen, it will be zero padded at left
  if output.len >= modLen:
    assign(c.output, output.toOpenArray(output.len-modLen, output.len-1))
  else:
    c.output = newSeq[byte](modLen)
    assign(c.output.toOpenArray(c.output.len-output.len, c.output.len-1), output)
  ok()

func bn256ecAdd(c: Computation, fork: EVMFork = FkByzantium): EvmResultVoid =
  let gasFee = if fork < FkIstanbul: GasECAdd else: GasECAddIstanbul
  ? c.gasMeter.consumeGas(gasFee, reason = "ecAdd Precompile")

  var
    input: array[128, byte]
    output: array[64, byte]
  # Padding data
  let len = min(c.msg.data.len, 128) - 1
  input[0..len] = c.msg.data[0..len]
  var p1 = ? G1.getPoint(input.toOpenArray(0, 63))
  var p2 = ? G1.getPoint(input.toOpenArray(64, 127))
  var apo = (p1 + p2).toAffine()
  if isSome(apo):
    # we can discard here because we supply proper buffer
    discard apo.get().toBytes(output)

  assign(c.output, output)
  ok()

func bn256ecMul(c: Computation, fork: EVMFork = FkByzantium): EvmResultVoid =
  let gasFee = if fork < FkIstanbul: GasECMul else: GasECMulIstanbul
  ? c.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")

  var
    input: array[96, byte]
    output: array[64, byte]

  # Padding data
  let len = min(c.msg.data.len, 96) - 1
  input[0..len] = c.msg.data[0..len]
  var p1 = ? G1.getPoint(input.toOpenArray(0, 63))
  var fr = ? getFR(input.toOpenArray(64, 95))
  var apo = (p1 * fr).toAffine()
  if isSome(apo):
    # we can discard here because we supply buffer of proper size
    discard apo.get().toBytes(output)

  assign(c.output, output)
  ok()

func bn256ecPairing(c: Computation, fork: EVMFork = FkByzantium): EvmResultVoid =
  let msglen = c.msg.data.len
  if msglen mod 192 != 0:
    return err(prcErr(PrcInvalidParam))

  let numPoints = GasInt msglen div 192
  let gasFee = if fork < FkIstanbul:
                 GasECPairingBase + numPoints * GasECPairingPerPoint
               else:
                 GasECPairingBaseIstanbul + numPoints * GasECPairingPerPointIstanbul
  ? c.gasMeter.consumeGas(gasFee, reason="ecPairing Precompile")

  var output: array[32, byte]
  if msglen == 0:
    # we can discard here because we supply buffer of proper size
    discard BNU256.one().toBytes(output)
  else:
    # Calculate number of pairing pairs
    let count = msglen div 192
    # Pairing accumulator
    var acc = FQ12.one()

    for i in 0..<count:
      let s = i * 192
      # Loading AffinePoint[G1], bytes from [0..63]
      var p1 = ? G1.getPoint(c.msg.data.toOpenArray(s, s + 63))
      # Loading AffinePoint[G2], bytes from [64..191]
      var p2 = ? G2.getPoint(c.msg.data.toOpenArray(s + 64, s + 191))
      # Accumulate pairing result
      acc = acc * pairing(p1, p2)

    if acc == FQ12.one():
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytes(output)

  assign(c.output, output)
  ok()

func blake2bf(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if len(input) == blake2FInputLength:
    let gasFee = GasInt(beLoad32(input, 0))
    ? c.gasMeter.consumeGas(gasFee, reason="blake2bf Precompile")

  var output: array[64, byte]
  if not blake2b_F(input, output):
    return err(prcErr(PrcInvalidParam))
  else:
    assign(c.output, output)
  ok()

func blsG1Add(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 256:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381G1AddGas, reason="blsG1Add Precompile")

  var a, b: BLS_G1
  if not a.decodePoint(input.toOpenArray(0, 127)):
    return err(prcErr(PrcInvalidPoint))

  if not b.decodePoint(input.toOpenArray(128, 255)):
    return err(prcErr(PrcInvalidPoint))

  a.add b

  c.output = newSeq[byte](128)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG1Mul(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 160:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381G1MulGas, reason="blsG1Mul Precompile")

  var a: BLS_G1
  if not a.decodePoint(input.toOpenArray(0, 127)):
    return err(prcErr(PrcInvalidPoint))

  var scalar: BLS_SCALAR
  if not scalar.fromBytes(input.toOpenArray(128, 159)):
    return err(prcErr(PrcInvalidParam))

  a.mul(scalar)

  c.output = newSeq[byte](128)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

const
  Bls12381MultiExpDiscountTable = [
    1200, 888, 764, 641, 594, 547, 500, 453, 438, 423,
    408, 394, 379, 364, 349, 334, 330, 326, 322, 318,
    314, 310, 306, 302, 298, 294, 289, 285, 281, 277,
    273, 269, 268, 266, 265, 263, 262, 260, 259, 257,
    256, 254, 253, 251, 250, 248, 247, 245, 244, 242,
    241, 239, 238, 236, 235, 233, 232, 231, 229, 228,
    226, 225, 223, 222, 221, 220, 219, 219, 218, 217,
    216, 216, 215, 214, 213, 213, 212, 211, 211, 210,
    209, 208, 208, 207, 206, 205, 205, 204, 203, 202,
    202, 201, 200, 199, 199, 198, 197, 196, 196, 195,
    194, 193, 193, 192, 191, 191, 190, 189, 188, 188,
    187, 186, 185, 185, 184, 183, 182, 182, 181, 180,
    179, 179, 178, 177, 176, 176, 175, 174
  ]

func calcBlsMultiExpGas(K: GasInt, gasCost: GasInt): GasInt =
  # Calculate G1 point, scalar value pair length
  if K == 0:
    # Return 0 gas for small input length
    return 0.GasInt

  const dLen = Bls12381MultiExpDiscountTable.len
  # Lookup discount value for G1 point, scalar value pair length
  let discount = if K < dLen: GasInt Bls12381MultiExpDiscountTable[K-1]
                 else: GasInt Bls12381MultiExpDiscountTable[dLen-1]

  # Calculate gas and return the result
  result = (K * gasCost * discount) div 1000

func blsG1MultiExp(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 160
  if (input.len == 0) or ((input.len mod L) != 0):
    return err(prcErr(PrcInvalidParam))

  let
    K = input.len div L
    gas = calcBlsMultiExpGas(GasInt K, Bls12381G1MulGas)

  ? c.gasMeter.consumeGas(gas, reason="blsG1MultiExp Precompile")

  var
    p: BLS_G1
    s: BLS_SCALAR
    acc: BLS_G1

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not p.decodePoint(input.toOpenArray(off, off+127)):
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+128, off+159)):
      return err(prcErr(PrcInvalidParam))

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output = newSeq[byte](128)
  if not encodePoint(acc, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG2Add(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 512:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381G2AddGas, reason="blsG2Add Precompile")

  var a, b: BLS_G2
  if not a.decodePoint(input.toOpenArray(0, 255)):
    return err(prcErr(PrcInvalidPoint))

  if not b.decodePoint(input.toOpenArray(256, 511)):
    return err(prcErr(PrcInvalidPoint))

  a.add b

  c.output = newSeq[byte](256)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG2Mul(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 288:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381G2MulGas, reason="blsG2Mul Precompile")

  var a: BLS_G2
  if not a.decodePoint(input.toOpenArray(0, 255)):
    return err(prcErr(PrcInvalidPoint))

  var scalar: BLS_SCALAR
  if not scalar.fromBytes(input.toOpenArray(256, 287)):
    return err(prcErr(PrcInvalidParam))

  a.mul(scalar)

  c.output = newSeq[byte](256)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsG2MultiExp(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 288
  if (input.len == 0) or ((input.len mod L) != 0):
    return err(prcErr(PrcInvalidParam))

  let
    K = input.len div L
    gas = calcBlsMultiExpGas(GasInt K, Bls12381G2MulGas)

  ? c.gasMeter.consumeGas(gas, reason="blsG2MultiExp Precompile")

  var
    p: BLS_G2
    s: BLS_SCALAR
    acc: BLS_G2

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not p.decodePoint(input.toOpenArray(off, off+255)):
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+256, off+287)):
      return err(prcErr(PrcInvalidParam))

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output = newSeq[byte](256)
  if not encodePoint(acc, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsPairing(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 384
  if (input.len == 0) or ((input.len mod L) != 0):
    return err(prcErr(PrcInvalidParam))

  let
    K = input.len div L
    gas = Bls12381PairingBaseGas + K.GasInt * Bls12381PairingPerPairGas

  ? c.gasMeter.consumeGas(gas, reason="blsG2Pairing Precompile")

  var
    g1: BLS_G1P
    g2: BLS_G2P
    acc: BLS_ACC

  # Decode pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not g1.decodePoint(input.toOpenArray(off, off+127)):
      return err(prcErr(PrcInvalidPoint))

    # Decode G2 point
    if not g2.decodePoint(input.toOpenArray(off+128, off+383)):
      return err(prcErr(PrcInvalidPoint))

    # 'point is on curve' check already done,
    # Here we need to apply subgroup checks.
    if not g1.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    if not g2.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # Update pairing engine with G1 and G2 points
    if i == 0:
      acc = millerLoop(g1, g2)
    else:
      acc.mul(millerLoop(g1, g2))

  c.output = newSeq[byte](32)
  if acc.check():
    c.output[^1] = 1.byte
  ok()

func blsMapG1(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 64:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381MapG1Gas, reason="blsMapG1 Precompile")

  var fe: BLS_FE
  if not fe.decodeFE(input):
    return err(prcErr(PrcInvalidPoint))

  let p = fe.mapFPToG1()

  c.output = newSeq[byte](128)
  if not encodePoint(p, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

func blsMapG2(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if input.len != 128:
    return err(prcErr(PrcInvalidParam))

  ? c.gasMeter.consumeGas(Bls12381MapG2Gas, reason="blsMapG2 Precompile")

  var fe: BLS_FE2
  if not fe.decodeFE(input):
    return err(prcErr(PrcInvalidPoint))

  let p = fe.mapFPToG2()

  c.output = newSeq[byte](256)
  if not encodePoint(p, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

proc pointEvaluation(c: Computation): EvmResultVoid =
  # Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
  # Also verify that the provided commitment matches the provided versioned_hash.
  # The data is encoded as follows: versioned_hash | z | y | commitment | proof |

  template input: untyped =
    c.msg.data

  ? c.gasMeter.consumeGas(POINT_EVALUATION_PRECOMPILE_GAS,
      reason = "EIP-4844 Point Evaluation Precompile")

  pointEvaluation(input).isOkOr:
    return err(prcErr(PrcValidationError))

  # return a constant
  c.output = @PointEvaluationResult
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

iterator activePrecompiles*(fork: EVMFork): Address =
  var res: Address
  let maxPrecompileAddr = getMaxPrecompileAddr(fork)
  for c in PrecompileAddresses.low..maxPrecompileAddr:
    if validPrecompileAddr(c.byte, maxPrecompileAddr.byte):
      res.data[^1] = c.byte
      yield res

func activePrecompilesList*(fork: EVMFork): seq[Address] =
  for address in activePrecompiles(fork):
    result.add address

proc execPrecompiles*(c: Computation, fork: EVMFork): bool =
  for i in 0..18:
    if c.msg.codeAddress.data[i] != 0:
      return false

  let lb = c.msg.codeAddress.data[19]
  if not validPrecompileAddr(lb, fork):
    return false

  let precompile = PrecompileAddresses(lb)
  let res = case precompile
    of paEcRecover: ecRecover(c)
    of paSha256: sha256(c)
    of paRipeMd160: ripemd160(c)
    of paIdentity: identity(c)
    of paModExp: modExp(c, fork)
    of paEcAdd: bn256ecAdd(c, fork)
    of paEcMul: bn256ecMul(c, fork)
    of paPairing: bn256ecPairing(c, fork)
    of paBlake2bf: blake2bf(c)
    of paPointEvaluation: pointEvaluation(c)
    of paBlsG1Add: blsG1Add(c)
    of paBlsG1Mul: blsG1Mul(c)
    of paBlsG1MultiExp: blsG1MultiExp(c)
    of paBlsG2Add: blsG2Add(c)
    of paBlsG2Mul: blsG2Mul(c)
    of paBlsG2MultiExp: blsG2MultiExp(c)
    of paBlsPairing: blsPairing(c)
    of paBlsMapG1: blsMapG1(c)
    of paBlsMapG2: blsMapG2(c)

  if res.isErr:
    if res.error.code == EvmErrorCode.OutOfGas:
      c.setError(EVMC_OUT_OF_GAS, $res.error.code, true)
    else:
      if fork >= FkByzantium and precompile > paIdentity:
        c.setError(EVMC_PRECOMPILE_FAILURE, $res.error.code, true)
      else:
        # swallow any other precompiles errors
        debug "execPrecompiles validation error", errCode = $res.error.code

  true
