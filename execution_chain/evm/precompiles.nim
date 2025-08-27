# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
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
  constantine/ethereum_evm_precompiles,
  "."/[types, blake2b_f, blscurve],
  ./interpreter/[gas_meter, gas_costs, utils/utils_numeric],
  eth/common/keys,
  chronicles,
  nimcrypto/[ripemd, sha2, utils],
  bncurve/[fields, groups],
  stew/[assign2, endians2, byteutils],
  libp2p/crypto/ecnist,
  ../common/evmforks,
  ../core/eip4844,
  ./modexp,
  ./evm_errors,
  ./computation,
  ./secp256r1verify,
  eth/common/[base, addresses]

type
  Precompiles* = enum
    # Frontier to Spurious Dragron
    paEcRecover
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
    # Cancun
    paPointEvaluation
    # Prague (EIP-2537)
    paBlsG1Add
    paBlsG1MultiExp
    paBlsG2Add
    paBlsG2MultiExp
    paBlsPairing
    paBlsMapG1
    paBlsMapG2
    # Osaka
    paP256Verify

  SigRes = object
    msgHash: array[32, byte]
    sig: Signature

const
  # Frontier to Spurious Dragron
  paEcRecoverAddress       = address"0x0000000000000000000000000000000000000001"
  paSha256Address          = address"0x0000000000000000000000000000000000000002"
  paRipeMd160Address       = address"0x0000000000000000000000000000000000000003"
  paIdentityAddress        = address"0x0000000000000000000000000000000000000004"

  # Byzantium and Constantinople
  paModExpAddress          = address"0x0000000000000000000000000000000000000005"
  paEcAddAddress           = address"0x0000000000000000000000000000000000000006"
  paEcMulAddress           = address"0x0000000000000000000000000000000000000007"
  paPairingAddress         = address"0x0000000000000000000000000000000000000008"

  # Istanbul
  paBlake2bfAddress        = address"0x0000000000000000000000000000000000000009"

  # Cancun
  paPointEvaluationAddress = address"0x000000000000000000000000000000000000000a"

  # Prague (EIP-2537)
  paBlsG1AddAddress        = address"0x000000000000000000000000000000000000000b"
  paBlsG1MultiExpAddress   = address"0x000000000000000000000000000000000000000c"
  paBlsG2AddAddress        = address"0x000000000000000000000000000000000000000d"
  paBlsG2MultiExpAddress   = address"0x000000000000000000000000000000000000000e"
  paBlsPairingAddress      = address"0x000000000000000000000000000000000000000f"
  paBlsMapG1Address        = address"0x0000000000000000000000000000000000000010"
  paBlsMapG2Address        = address"0x0000000000000000000000000000000000000011"

  # Osaka
  paP256VerifyAddress      = address"0x0000000000000000000000000000000000000100"

  precompileAddrs*: array[Precompiles, Address] = [
    paEcRecoverAddress,        # paEcRecover
    paSha256Address,           # paSha256
    paRipeMd160Address,        # paRipeMd160
    paIdentityAddress,         # paIdentity
    paModExpAddress,           # paModExp
    paEcAddAddress,            # paEcAdd
    paEcMulAddress,            # paEcMul
    paPairingAddress,          # paPairing
    paBlake2bfAddress,         # paBlake2bf
    paPointEvaluationAddress,  # paPointEvaluation
    paBlsG1AddAddress,         # paBlsG1Add
    paBlsG1MultiExpAddress,    # paBlsG1MultiExp
    paBlsG2AddAddress,         # paBlsG2Add
    paBlsG2MultiExpAddress,    # paBlsG2MultiExp
    paBlsPairingAddress,       # paBlsPairing
    paBlsMapG1Address,         # paBlsMapG1
    paBlsMapG2Address,         # paBlsMapG2
    paP256VerifyAddress        # paP256Verify
  ]

  precompileNames*: array[Precompiles, string] = [
    "ECREC",
    "SHA256",
    "RIPEMD160",
    "ID",
    "MODEXP",
    "BN254_ADD",
    "BN254_MUL",
    "BN254_PAIRING",
    "BLAKE2F",
    "KZG_POINT_EVALUATION",
    "BLS12_G1ADD",
    "BLS12_G1MSM",
    "BLS12_G2ADD",
    "BLS12_G2MSM",
    "BLS12_PAIRING_CHECK",
    "BLS12_MAP_FP_TO_G1",
    "BLS12_MAP_FP2_TO_G2",
    "P256_VERIFY"
  ]


# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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
    assign(bytes.toOpenArray(0, (maxPos-64)), data.toOpenArray(64, maxPos))

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
  let res =c.output.eth_evm_ripemd160(c.msg.data)

  if res != cttEVM_Success:
    return err(prcErr(PrcInvalidParam))
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

  func mulComplexityEIP7883(maxLen: UInt256): UInt256 =
    result = 16.u256
    if maxLen > 32.u256:
      result = maxLen + 7
      result = result div 8
      result = result * result
      result = result * 2

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
      let expMul = if fork >= FkOsaka: 16.u256
                   else: 8.u256
      if not first32.isZero:
        expMul * (expLen - 32.u256) + first32.log2.u256
      else:
        expMul * (expLen - 32.u256)

  template gasCalc(comp, divisor: untyped): untyped =
    (
      max(modLen, baseLen).comp *
      max(adjExpLen, 1.u256)
    ) div divisor

  template gasCalc7883(comp): untyped =
    # multiplication_complexity * iteration_count
    max(modLen, baseLen).comp * max(adjExpLen, 1.u256)

  # EIP2565: modExp gas cost
  let gasFee = if fork >= FkOsaka: gasCalc7883(mulComplexityEIP7883)
               elif fork >= FkBerlin: gasCalc(mulComplexityEIP2565, GasQuadDivisorEIP2565)
               else: gasCalc(mulComplexity, GasQuadDivisor)

  if gasFee > high(GasInt).u256:
    return err(gasErr(OutOfGas))

  let minPrice = if fork >= FkOsaka: 500.GasInt
                 else: 200.GasInt

  var res = gasFee.truncate(GasInt)
  # EIP2565: modExp gas cost
  if fork >= FkBerlin and res < minPrice:
    res = minPrice
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

  if fork >= FkOsaka:
    # EIP-7823
    if baseLen > 1024 or expLen > 1024 or modLen > 1024:
      return err(prcErr(PrcInvalidParam))

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

  var output: array[64, byte]
  let res = output.eth_evm_bn254_g1add(c.msg.data)

  if res != cttEVM_Success:
    return err(prcErr(PrcInvalidParam))

  c.output.setLen(64)
  assign(c.output, output)

  ok()

func bn256ecMul(c: Computation, fork: EVMFork = FkByzantium): EvmResultVoid =
  let gasFee = if fork < FkIstanbul: GasECMul else: GasECMulIstanbul
  ? c.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")

  var output: array[64, byte]
  let res = output.eth_evm_bn254_g1mul(c.msg.data)

  if res != cttEVM_Success:
    return err(prcErr(PrcInvalidParam))

  c.output.setLen(64)
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

  if msglen == 0:
    # we can discard here because we supply buffer of proper size
    c.output.setLen(32)
    discard BNU256.one().toBytesBE(c.output)
  else:
    # Calculate number of pairing pairs
    let count = msglen div 192
    # Pairing accumulator
    var acc = FQ12.one()

    for i in 0..<count:
      let s = i * 192
      # Loading AffinePoint[G1], bytes from [0..63]
      let p1 = ?G1.getPoint(c.msg.data.toOpenArray(s, s + 63))
      # Loading AffinePoint[G2], bytes from [64..191]
      let p2 = ?G2.getPoint(c.msg.data.toOpenArray(s + 64, s + 191))
      # Accumulate pairing result
      acc = acc * pairing(p1, p2)

    c.output.setLen(32)
    if acc == FQ12.one():
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytesBE(c.output)

  ok()

func blake2bf(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  if len(input) == blake2FInputLength:
    let gasFee = GasInt(beLoad32(input, 0))
    ? c.gasMeter.consumeGas(gasFee, reason="blake2bf Precompile")

  c.output.setLen(64)
  if not blake2b_F(input, c.output):
    # unlike other precompiles, blake2b upon
    # error should return zero length output
    c.output.setLen(0)
    return err(prcErr(PrcInvalidParam))
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

  c.output.setLen(128)
  if not encodePoint(a, c.output):
    return err(prcErr(PrcInvalidPoint))
  ok()

const
  MSMG1DiscountTable = [
    1000.GasInt, 949, 848, 797, 764, 750, 738, 728, 719, 712, 705,
    698, 692, 687, 682, 677, 673, 669, 665, 661, 658, 654, 651,
    648, 645, 642, 640, 637, 635, 632, 630, 627, 625, 623, 621,
    619, 617, 615, 613, 611, 609, 608, 606, 604, 603, 601, 599,
    598, 596, 595, 593, 592, 591, 589, 588, 586, 585, 584, 582,
    581, 580, 579, 577, 576, 575, 574, 573, 572, 570, 569, 568,
    567, 566, 565, 564, 563, 562, 561, 560, 559, 558, 557, 556,
    555, 554, 553, 552, 551, 550, 549, 548, 547, 547, 546, 545,
    544, 543, 542, 541, 540, 540, 539, 538, 537, 536, 536, 535,
    534, 533, 532, 532, 531, 530, 529, 528, 528, 527, 526, 525,
    525, 524, 523, 522, 522, 521, 520, 520, 519]

  MSMG1MaxDiscount = 519.GasInt

  MSMG2DiscountTable = [
    1000.GasInt, 1000, 923, 884, 855, 832, 812, 796, 782, 770, 759,
    749, 740, 732, 724, 717, 711, 704, 699, 693, 688, 683, 679,
    674, 670, 666, 663, 659, 655, 652, 649, 646, 643, 640, 637,
    634, 632, 629, 627, 624, 622, 620, 618, 615, 613, 611, 609,
    607, 606, 604, 602, 600, 598, 597, 595, 593, 592, 590, 589,
    587, 586, 584, 583, 582, 580, 579, 578, 576, 575, 574, 573,
    571, 570, 569, 568, 567, 566, 565, 563, 562, 561, 560, 559,
    558, 557, 556, 555, 554, 553, 552, 552, 551, 550, 549, 548,
    547, 546, 545, 545, 544, 543, 542, 541, 541, 540, 539, 538,
    537, 537, 536, 535, 535, 534, 533, 532, 532, 531, 530, 530,
    529, 528, 528, 527, 526, 526, 525, 524, 524]

  MSMG2MaxDiscount = 524.GasInt

func calcBlsMultiExpGas(K: int, gasCost: GasInt,
                        discountTable: openArray[GasInt],
                        maxDiscount: GasInt): GasInt =
  # Calculate G1 point, scalar value pair length
  if K == 0:
    # Return 0 gas for small input length
    return 0.GasInt

  # Lookup discount value for G1 point, scalar value pair length
  let dLen = discountTable.len
  let discount = if K < dLen: discountTable[K-1]
                 else: maxDiscount

  # Calculate gas and return the result
  (K.GasInt * gasCost * discount) div 1000

func blsG1MultiExp(c: Computation): EvmResultVoid =
  template input: untyped =
    c.msg.data

  const L = 160
  if (input.len == 0) or ((input.len mod L) != 0):
    return err(prcErr(PrcInvalidParam))

  let
    K = input.len div L
    gas = calcBlsMultiExpGas(K, Bls12381G1MulGas, MSMG1DiscountTable, MSMG1MaxDiscount)

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

    if not p.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+128, off+159)):
      return err(prcErr(PrcInvalidParam))

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output.setLen(128)
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

  c.output.setLen(256)
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
    gas = calcBlsMultiExpGas(K, Bls12381G2MulGas, MSMG2DiscountTable, MSMG2MaxDiscount)

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

    if not p.subgroupCheck:
      return err(prcErr(PrcInvalidPoint))

    # Decode scalar value
    if not s.fromBytes(input.toOpenArray(off+256, off+287)):
      return err(prcErr(PrcInvalidParam))

    p.mul(s)
    if i == 0:
      acc = p
    else:
      acc.add(p)

  c.output.setLen(256)
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

  c.output.setLen(32)
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

  c.output.setLen(128)
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

  c.output.setLen(256)
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

proc p256verify(c: Computation): EvmResultVoid =

  template failed() =
    c.output.setLen(0)
    return ok()

  ? c.gasMeter.consumeGas(GasP256VerifyGas, reason="P256VERIFY Precompile")

  if c.msg.data.len != 160:
    failed()

  var inputPubKey: array[65, byte]

  # Validations
  if isInfinityByte(c.msg.data.toOpenArray(96, 159)):
    failed()

  # Check scalar and field bounds (r, s ∈ (0, n), qx, qy ∈ [0, p))
  var sig: EcSignature
  if not sig.initRaw(c.msg.data.toOpenArray(32, 95)):
    failed()

  var pubkey: EcPublicKey
  inputPubKey[0] = 4.byte
  assign(inputPubKey.toOpenArray(1, 64), c.msg.data.toOpenArray(96, 159))

  if not pubkey.initRaw(inputPubKey):
    failed()

  let isValid = sig.verifyRaw(c.msg.data.toOpenArray(0, 31), pubkey)

  if isValid:
    c.output.setLen(32)
    c.output[^1] = 1.byte  # return 0x...01
  else:
    c.output.setLen(0)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func getMaxPrecompile*(fork: EVMFork): Precompiles =
  if fork < FkByzantium: paIdentity
  elif fork < FkIstanbul: paPairing
  elif fork < FkCancun: paBlake2bf
  elif fork < FkPrague: paPointEvaluation
  elif fork < FkOsaka: paBlsMapG2
  else: Precompiles.high

iterator activePrecompiles*(fork: EVMFork): Address =
  let maxPrecompile = getMaxPrecompile(fork)
  for c in Precompiles.low..maxPrecompile:
    yield precompileAddrs[c]

func activePrecompilesList*(fork: EVMFork): seq[Address] =
  for address in activePrecompiles(fork):
    result.add address

proc getPrecompile*(fork: EVMFork, codeAddress: Address): Opt[Precompiles] =
  let maxPrecompile = getMaxPrecompile(fork)
  for c in Precompiles.low..maxPrecompile:
    if precompileAddrs[c] == codeAddress:
      return Opt.some(c)

  Opt.none(Precompiles)

proc execPrecompile*(c: Computation, precompile: Precompiles) =
  let fork = c.fork
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
    of paBlsG1MultiExp: blsG1MultiExp(c)
    of paBlsG2Add: blsG2Add(c)
    of paBlsG2MultiExp: blsG2MultiExp(c)
    of paBlsPairing: blsPairing(c)
    of paBlsMapG1: blsMapG1(c)
    of paBlsMapG2: blsMapG2(c)
    of paP256Verify: p256verify(c)

  if res.isErr:
    if res.error.code == EvmErrorCode.OutOfGas:
      c.setError(StatusCode.OutOfGas, $res.error.code, true)
    else:
      if fork >= FkByzantium and precompile > paIdentity:
        c.setError(StatusCode.PrecompileFailure, $res.error.code, true)
      else:
        # swallow any other precompiles errors
        debug "execPrecompiles validation error", errCode = $res.error.code
