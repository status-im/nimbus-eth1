import
  ../vm_types, interpreter/[gas_meter, gas_costs, utils/utils_numeric, vm_forks],
  ../errors, stint, eth/[keys, common], chronicles, tables, macros,
  math, nimcrypto, bncurve/[fields, groups], blake2b_f, ./blscurve

type
  PrecompileAddresses* = enum
    # Frontier to Spurious Dragron
    paEcRecover = 1
    paSha256
    paRipeMd160
    paIdentity
    # Byzantium and Constantinople
    paModExp
    paEcAdd
    paEcMul
    paPairing
    # Istanbul
    paBlake2bf
    # Berlin
    paBlsG1Add
    paBlsG1Mul
    paBlsG1MultiExp
    paBlsG2Add
    paBlsG2Mul
    paBlsG2MultiExp
    paBlsPairing
    paBlsMapG1
    paBlsMapG2

proc getSignature(computation: Computation): (array[32, byte], Signature) =
  # input is Hash, V, R, S
  template data: untyped = computation.msg.data
  var bytes: array[65, byte] # will hold R[32], S[32], V[1], in that order
  let maxPos = min(data.high, 127)

  # if we don't have at minimum 64 bytes, there can be no valid V
  if maxPos >= 63:
    let v = data[63]
    # check if V[32] is 27 or 28
    if not (v.int in 27..28):
      raise newException(ValidationError, "Invalid V in getSignature")
    for x in 32..<63:
      if data[x] != 0:
        raise newException(ValidationError, "Invalid V in getSignature")

    bytes[64] = v - 27

    # if there is more data for R and S, copy it. Else, defaulted zeroes are
    # used for R and S
    if maxPos >= 64:
      # Copy message data to buffer
      bytes[0..(maxPos-64)] = data[64..maxPos]

    let sig = Signature.fromRaw(bytes)
    if sig.isErr:
      raise newException(ValidationError, "Could not recover signature computation")
    result[1] = sig[]

    # extract message hash, only need to copy when there is a valid signature
    result[0][0..31] = data[0..31]
  else:
    raise newException(ValidationError, "Invalid V in getSignature")

proc simpleDecode*(dst: var FQ2, src: openarray[byte]): bool {.noinit.} =
  # bypassing FQ2.fromBytes
  # because we want to check `value > modulus`
  result = false
  if dst.c1.fromBytes(src.toOpenArray(0, 31)) and
     dst.c0.fromBytes(src.toOpenArray(32, 63)):
    result = true

template simpleDecode*(dst: var FQ, src: openarray[byte]): bool =
  fromBytes(dst, src)

proc getPoint[T: G1|G2](t: typedesc[T], data: openarray[byte]): Point[T] =
  when T is G1:
    const nextOffset = 32
    var px, py: FQ
  else:
    const nextOffset = 64
    var px, py: FQ2
  if not px.simpleDecode(data.toOpenArray(0, nextOffset - 1)):
    raise newException(ValidationError, "Could not get point value")
  if not py.simpleDecode(data.toOpenArray(nextOffset, nextOffset * 2 - 1)):
    raise newException(ValidationError, "Could not get point value")

  if px.isZero() and py.isZero():
    result = T.zero()
  else:
    var ap: AffinePoint[T]
    if not ap.init(px, py):
      raise newException(ValidationError, "Point is not on curve")
    result = ap.toJacobian()

proc getFR(data: openarray[byte]): FR =
  if not result.fromBytes2(data):
    raise newException(ValidationError, "Could not get FR value")

proc ecRecover*(computation: Computation) =
  computation.gasMeter.consumeGas(
    GasECRecover,
    reason="ECRecover Precompile")

  var
    (msgHash, sig) = computation.getSignature()

  var pubkey = recover(sig, SkMessage(msgHash))
  if pubkey.isErr:
    raise newException(ValidationError, "Could not derive public key from computation")

  computation.output.setLen(32)
  computation.output[12..31] = pubkey[].toCanonicalAddress()
  trace "ECRecover precompile", derivedKey = pubkey[].toCanonicalAddress()

proc sha256*(computation: Computation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.output = @(nimcrypto.sha_256.digest(computation.msg.data).data)
  trace "SHA256 precompile", output = computation.output.toHex

proc ripemd160*(computation: Computation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.output.setLen(32)
  computation.output[12..31] = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  trace "RIPEMD160 precompile", output = computation.output.toHex

proc identity*(computation: Computation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasIdentity + wordCount * GasIdentityWord

  computation.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  computation.output = computation.msg.data
  trace "Identity precompile", output = computation.output.toHex

proc modExpInternal(computation: Computation, baseLen, expLen, modLen: int, T: type StUint) =
  template data: untyped {.dirty.} =
    computation.msg.data

  let
    base = data.rangeToPadded[:T](96, 95 + baseLen, baseLen)
    exp = data.rangeToPadded[:T](96 + baseLen, 95 + baseLen + expLen, expLen)
    modulo = data.rangeToPadded[:T](96 + baseLen + expLen, 95 + baseLen + expLen + modLen, modLen)

  # TODO: specs mentions that we should return in "M" format
  #       i.e. if Base and exp are uint512 and Modulo an uint256
  #       we should return a 256-bit big-endian byte array

  # Force static evaluation
  func zero(): array[T.bits div 8, byte] {.compileTime.} = discard
  func one(): array[T.bits div 8, byte] {.compileTime.} =
    when cpuEndian == bigEndian:
      result[0] = 1
    else:
      result[^1] = 1

  # Start with EVM special cases
  let output = if modulo <= 1:
                  # If m == 0: EVM returns 0.
                  # If m == 1: we can shortcut that to 0 as well
                  zero()
              elif exp.isZero():
                  # If 0^0: EVM returns 1
                  # For all x != 0, x^0 == 1 as well
                  one()
              else:
                  powmod(base, exp, modulo).toByteArrayBE

  # maximum output len is the same as modLen
  # if it less than modLen, it will be zero padded at left
  if output.len >= modLen:
    computation.output = @(output[^modLen..^1])
  else:
    computation.output = newSeq[byte](modLen)
    computation.output[^output.len..^1] = output[0..^1]

proc modExpFee(c: Computation, baseLen, expLen, modLen: Uint256, fork: Fork): GasInt =
  template data: untyped {.dirty.} =
    c.msg.data

  func mulComplexity(x: Uint256): Uint256 =
    ## Estimates the difficulty of Karatsuba multiplication
    if x <= 64.u256: x * x
    elif x <= 1024.u256: x * x div 4.u256 + 96.u256 * x - 3072.u256
    else: x * x div 16.u256 + 480.u256 * x - 199680.u256

  func mulComplexityEIP2565(x: Uint256): Uint256 =
    # gas = ceil(x div 8) ^ 2
    result = x + 7
    result = result div 8
    result = result * result

  let adjExpLen = block:
    let
      baseL = baseLen.safeInt
      expL = expLen.safeInt
      first32 = if baseL.uint64 + expL.uint64 < high(int32).uint64 and baseL < data.len:
                  data.rangeToPadded2[:Uint256](96 + baseL, 95 + baseL + expL, min(expL, 32))
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

  let gasFee = if fork >= FkBerlin: gasCalc(mulComplexityEIP2565, GasQuadDivisorEIP2565)
               else: gasCalc(mulComplexity, GasQuadDivisor)

  if gasFee > high(GasInt).u256:
    raise newException(OutOfGas, "modExp gas overflow")

  result = gasFee.truncate(GasInt)
  if fork >= FkBerlin and result < 200.GasInt:
    result = 200.GasInt

proc modExp*(c: Computation, fork: Fork = FkByzantium) =
  ## Modular exponentiation precompiled contract
  ## Yellow Paper Appendix E
  ## EIP-198 - https://github.com/ethereum/EIPs/blob/master/EIPS/eip-198.md
  # Parsing the data
  template data: untyped {.dirty.} =
    c.msg.data

  let # lengths Base, Exponent, Modulus
    baseL = data.rangeToPadded[:Uint256](0, 31)
    expL  = data.rangeToPadded[:Uint256](32, 63)
    modL  = data.rangeToPadded[:Uint256](64, 95)
    baseLen = baseL.safeInt
    expLen  = expL.safeInt
    modLen  = modL.safeInt

  let gasFee = modExpFee(c, baseL, expL, modL, fork)
  c.gasMeter.consumeGas(gasFee, reason="ModExp Precompile")

  if baseLen == 0 and modLen == 0:
    # This is a special case where expLength can be very big.
    c.output = @[]
    return

  let maxBytes = max(baseLen, max(expLen, modLen))
  if maxBytes <= 32:
    c.modExpInternal(baseLen, expLen, modLen, UInt256)
  elif maxBytes <= 64:
    c.modExpInternal(baseLen, expLen, modLen, StUint[512])
  elif maxBytes <= 128:
    c.modExpInternal(baseLen, expLen, modLen, StUint[1024])
  elif maxBytes <= 256:
    c.modExpInternal(baseLen, expLen, modLen, StUint[2048])
  elif maxBytes <= 512:
    c.modExpInternal(baseLen, expLen, modLen, StUint[4096])
  elif maxBytes <= 1024:
    c.modExpInternal(baseLen, expLen, modLen, StUint[8192])
  else:
    raise newException(EVMError, "The Nimbus VM doesn't support modular exponentiation with numbers larger than uint8192")

proc bn256ecAdd*(computation: Computation, fork: Fork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECAdd else: GasECAddIstanbul
  computation.gasMeter.consumeGas(gasFee, reason = "ecAdd Precompile")

  var
    input: array[128, byte]
    output: array[64, byte]
  # Padding data
  let len = min(computation.msg.data.len, 128) - 1
  input[0..len] = computation.msg.data[0..len]
  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var p2 = G1.getPoint(input.toOpenArray(64, 127))
  var apo = (p1 + p2).toAffine()
  if isSome(apo):
    # we can discard here because we supply proper buffer
    discard apo.get().toBytes(output)

  computation.output = @output

proc bn256ecMul*(computation: Computation, fork: Fork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECMul else: GasECMulIstanbul
  computation.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")

  var
    input: array[96, byte]
    output: array[64, byte]

  # Padding data
  let len = min(computation.msg.data.len, 96) - 1
  input[0..len] = computation.msg.data[0..len]
  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var fr = getFR(input.toOpenArray(64, 95))
  var apo = (p1 * fr).toAffine()
  if isSome(apo):
    # we can discard here because we supply buffer of proper size
    discard apo.get().toBytes(output)

  computation.output = @output

proc bn256ecPairing*(computation: Computation, fork: Fork = FkByzantium) =
  let msglen = len(computation.msg.data)
  if msglen mod 192 != 0:
    raise newException(ValidationError, "Invalid input length")

  let numPoints = msglen div 192
  let gasFee = if fork < FkIstanbul:
                 GasECPairingBase + numPoints * GasECPairingPerPoint
               else:
                 GasECPairingBaseIstanbul + numPoints * GasECPairingPerPointIstanbul
  computation.gasMeter.consumeGas(gasFee, reason="ecPairing Precompile")

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
      var p1 = G1.getPoint(computation.msg.data.toOpenArray(s, s + 63))
      # Loading AffinePoint[G2], bytes from [64..191]
      var p2 = G2.getPoint(computation.msg.data.toOpenArray(s + 64, s + 191))
      # Accumulate pairing result
      acc = acc * pairing(p1, p2)

    if acc == FQ12.one():
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytes(output)

  computation.output = @output

proc blake2bf*(c: Computation) =
  template input: untyped =
    c.msg.data

  if len(input) == blake2FInputLength:
    let gasFee = GasInt(beLoad32(input, 0))
    c.gasMeter.consumeGas(gasFee, reason="blake2bf Precompile")

  var output: array[64, byte]
  if not blake2b_F(input, output):
    raise newException(ValidationError, "Blake2b F function invalid input")
  else:
    c.output = @output

proc blsG1Add*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 256:
    raise newException(ValidationError, "blsG1Add invalid input len")

  c.gasMeter.consumeGas(Bls12381G1AddGas, reason="blsG1Add Precompile")

  var a, b: BLS_G1
  if not a.decodePoint(input.toOpenArray(0, 127)):
    raise newException(ValidationError, "blsG1Add invalid input A")

  if not b.decodePoint(input.toOpenArray(128, 255)):
    raise newException(ValidationError, "blsG1Add invalid input B")

  a.add b

  c.output = newSeq[byte](128)
  if not encodePoint(a, c.output):
    raise newException(ValidationError, "blsG1Add encodePoint error")

proc blsG1Mul*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 160:
    raise newException(ValidationError, "blsG1Mul invalid input len")

  c.gasMeter.consumeGas(Bls12381G1MulGas, reason="blsG1Mul Precompile")

  var a: BLS_G1
  if not a.decodePoint(input.toOpenArray(0, 127)):
    raise newException(ValidationError, "blsG1Mul invalid input A")

  var scalar: BLS_SCALAR
  if not scalar.fromBytes(input.toOpenArray(128, 159)):
    raise newException(ValidationError, "blsG1Mul invalid scalar")

  a.mul(scalar)

  c.output = newSeq[byte](128)
  if not encodePoint(a, c.output):
    raise newException(ValidationError, "blsG1Mul encodePoint error")

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

func calcBlsMultiExpGas(K: int, gasCost: GasInt): GasInt =
  # Calculate G1 point, scalar value pair length
  if K == 0:
    # Return 0 gas for small input length
    return 0.GasInt

  const dLen = Bls12381MultiExpDiscountTable.len
  # Lookup discount value for G1 point, scalar value pair length
  let discount = if K < dLen: Bls12381MultiExpDiscountTable[K-1]
                 else: Bls12381MultiExpDiscountTable[dLen-1]

  # Calculate gas and return the result
  result = (K * gasCost * discount) div 1000

proc blsG1MultiExp*(c: Computation) =
  template input: untyped =
    c.msg.data

  const L = 160
  if (input.len == 0) or ((input.len mod L) != 0):
    raise newException(ValidationError, "blsG1MultiExp invalid input len")

  let
    K = input.len div L
    gas = K.calcBlsMultiExpGas(Bls12381G1MulGas)

  c.gasMeter.consumeGas(gas, reason="blsG1MultiExp Precompile")

  var
    p: BLS_G1
    s: BLS_SCALAR
    acc: BLS_G1

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not p.decodePoint(input.toOpenArray(off, off+127)):
      raise newException(ValidationError, "blsG1MultiExp invalid input P")

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+128, off+159)):
      raise newException(ValidationError, "blsG1MultiExp invalid scalar")

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output = newSeq[byte](128)
  if not encodePoint(acc, c.output):
    raise newException(ValidationError, "blsG1MuliExp encodePoint error")

proc blsG2Add*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 512:
    raise newException(ValidationError, "blsG2Add invalid input len")

  c.gasMeter.consumeGas(Bls12381G2AddGas, reason="blsG2Add Precompile")

  var a, b: BLS_G2
  if not a.decodePoint(input.toOpenArray(0, 255)):
    raise newException(ValidationError, "blsG2Add invalid input A")

  if not b.decodePoint(input.toOpenArray(256, 511)):
    raise newException(ValidationError, "blsG2Add invalid input B")

  a.add b

  c.output = newSeq[byte](256)
  if not encodePoint(a, c.output):
    raise newException(ValidationError, "blsG2Add encodePoint error")

proc blsG2Mul*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 288:
    raise newException(ValidationError, "blsG2Mul invalid input len")

  c.gasMeter.consumeGas(Bls12381G2MulGas, reason="blsG2Mul Precompile")

  var a: BLS_G2
  if not a.decodePoint(input.toOpenArray(0, 255)):
    raise newException(ValidationError, "blsG2Mul invalid input A")

  var scalar: BLS_SCALAR
  if not scalar.fromBytes(input.toOpenArray(256, 287)):
    raise newException(ValidationError, "blsG2Mul invalid scalar")

  a.mul(scalar)

  c.output = newSeq[byte](256)
  if not encodePoint(a, c.output):
    raise newException(ValidationError, "blsG2Mul encodePoint error")

proc blsG2MultiExp*(c: Computation) =
  template input: untyped =
    c.msg.data

  const L = 288
  if (input.len == 0) or ((input.len mod L) != 0):
    raise newException(ValidationError, "blsG2MultiExp invalid input len")

  let
    K = input.len div L
    gas = K.calcBlsMultiExpGas(Bls12381G2MulGas)

  c.gasMeter.consumeGas(gas, reason="blsG2MultiExp Precompile")

  var
    p: BLS_G2
    s: BLS_SCALAR
    acc: BLS_G2

  # Decode point scalar pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not p.decodePoint(input.toOpenArray(off, off+255)):
      raise newException(ValidationError, "blsG2MultiExp invalid input P")

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+256, off+287)):
      raise newException(ValidationError, "blsG2MultiExp invalid scalar")

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output = newSeq[byte](256)
  if not encodePoint(acc, c.output):
    raise newException(ValidationError, "blsG2MuliExp encodePoint error")

proc blsPairing*(c: Computation) =
  template input: untyped =
    c.msg.data

  const L = 384
  if (input.len == 0) or ((input.len mod L) != 0):
    raise newException(ValidationError, "blsG2Pairing invalid input len")

  let
    K = input.len div L
    gas = Bls12381PairingBaseGas + K.GasInt * Bls12381PairingPerPairGas

  c.gasMeter.consumeGas(gas, reason="blsG2Pairing Precompile")

  var
    g1: BLS_G1P
    g2: BLS_G2P
    acc: BLS_ACC

  # Decode pairs
  for i in 0..<K:
    let off = L * i

    # Decode G1 point
    if not g1.decodePoint(input.toOpenArray(off, off+127)):
      raise newException(ValidationError, "blsG2Pairing invalid G1")

    # Decode G2 point
    if not g2.decodePoint(input.toOpenArray(off+128, off+383)):
      raise newException(ValidationError, "blsG2Pairing invalid G2")

    # 'point is on curve' check already done,
    # Here we need to apply subgroup checks.
    if not g1.subgroupCheck:
      raise newException(ValidationError, "blsG2Pairing invalid G1 subgroup")

    if not g2.subgroupCheck:
      raise newException(ValidationError, "blsG2Pairing invalid G2 subgroup")

    # Update pairing engine with G1 and G2 points
    if i == 0:
      acc = millerLoop(g1, g2)
    else:
      acc.mul(millerLoop(g1, g2))

  c.output = newSeq[byte](32)
  if acc.check():
    c.output[^1] = 1.byte

proc blsMapG1*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 64:
    raise newException(ValidationError, "blsMapG1 invalid input len")

  c.gasMeter.consumeGas(Bls12381MapG1Gas, reason="blsMapG1 Precompile")

  var fe: BLS_FE
  if not fe.decodeFE(input):
    raise newException(ValidationError, "blsMapG1 invalid field element")

  let p = fe.mapFPToG1()

  c.output = newSeq[byte](128)
  if not encodePoint(p, c.output):
    raise newException(ValidationError, "blsMapG1 encodePoint error")

proc blsMapG2*(c: Computation) =
  template input: untyped =
    c.msg.data

  if input.len != 128:
    raise newException(ValidationError, "blsMapG2 invalid input len")

  c.gasMeter.consumeGas(Bls12381MapG2Gas, reason="blsMapG2 Precompile")

  var fe: BLS_FE2
  if not fe.decodeFE(input):
    raise newException(ValidationError, "blsMapG2 invalid field element")

  let p = fe.mapFPToG2()

  c.output = newSeq[byte](256)
  if not encodePoint(p, c.output):
    raise newException(ValidationError, "blsMapG2 encodePoint error")

proc getMaxPrecompileAddr(fork: Fork): PrecompileAddresses =
  if fork < FkByzantium: paIdentity
  elif fork < FkIstanbul: paPairing
  elif fork < FkBerlin: paBlake2bf
  else: PrecompileAddresses.high

proc execPrecompiles*(computation: Computation, fork: Fork): bool {.inline.} =
  for i in 0..18:
    if computation.msg.codeAddress[i] != 0: return

  let lb = computation.msg.codeAddress[19]
  let maxPrecompileAddr = getMaxPrecompileAddr(fork)
  if lb in PrecompileAddresses.low.byte .. maxPrecompileAddr.byte:
    result = true
    let precompile = PrecompileAddresses(lb)
    trace "Call precompile", precompile = precompile, codeAddr = computation.msg.codeAddress
    try:
      case precompile
      of paEcRecover: ecRecover(computation)
      of paSha256: sha256(computation)
      of paRipeMd160: ripeMd160(computation)
      of paIdentity: identity(computation)
      of paModExp: modExp(computation, fork)
      of paEcAdd: bn256ecAdd(computation, fork)
      of paEcMul: bn256ecMul(computation, fork)
      of paPairing: bn256ecPairing(computation, fork)
      of paBlake2bf: blake2bf(computation)
      of paBlsG1Add: blsG1Add(computation)
      of paBlsG1Mul: blsG1Mul(computation)
      of paBlsG1MultiExp: blsG1MultiExp(computation)
      of paBlsG2Add: blsG2Add(computation)
      of paBlsG2Mul: blsG2Mul(computation)
      of paBlsG2MultiExp: blsG2MultiExp(computation)
      of paBlsPairing: blsPairing(computation)
      of paBlsMapG1: blsMapG1(computation)
      of paBlsMapG2: blsMapG2(computation)
    except OutOfGas as e:
      # cannot use setError here, cyclic dependency
      computation.error = Error(info: e.msg, burnsGas: true)
    except CatchableError as e:
      if fork >= FKByzantium and precompile > paIdentity:
        computation.error = Error(info: e.msg, burnsGas: true)
      else:
        # swallow any other precompiles errors
        debug "execPrecompiles validation error", msg=e.msg
