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
  "."/[types, blake2b_f],
  ./interpreter/[gas_meter, gas_costs, utils/utils_numeric],
  ../errors, eth/[common, keys], chronicles,
  nimcrypto/[ripemd, sha2, utils], bncurve/[fields, groups],
  ../common/evmforks,
  ../core/eip4844,
  ./modexp,
  ./computation


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
    paPointEvaluation = 0x0A

proc getMaxPrecompileAddr(fork: EVMFork): PrecompileAddresses =
  if fork < FkByzantium: paIdentity
  elif fork < FkIstanbul: paPairing
  elif fork < FkCancun: paBlake2bf
  else: PrecompileAddresses.high

proc validPrecompileAddr(addrByte, maxPrecompileAddr: byte): bool =
  (addrByte in PrecompileAddresses.low.byte .. maxPrecompileAddr)

proc validPrecompileAddr(addrByte: byte, fork: EVMFork): bool =
  let maxPrecompileAddr = getMaxPrecompileAddr(fork)
  validPrecompileAddr(addrByte, maxPrecompileAddr.byte)

iterator activePrecompiles*(fork: EVMFork): EthAddress =
  var res: EthAddress
  let maxPrecompileAddr = getMaxPrecompileAddr(fork)
  for c in PrecompileAddresses.low..maxPrecompileAddr:
    if validPrecompileAddr(c.byte, maxPrecompileAddr.byte):
      res[^1] = c.byte
      yield res

func activePrecompilesList*(fork: EVMFork): seq[EthAddress] =
  for address in activePrecompiles(fork):
    result.add address

proc getSignature(c: Computation): (array[32, byte], Signature) =
  # input is Hash, V, R, S
  template data: untyped = c.msg.data
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
      raise newException(ValidationError, "Could not recover signature c")
    result[1] = sig[]

    # extract message hash, only need to copy when there is a valid signature
    result[0][0..31] = data[0..31]
  else:
    raise newException(ValidationError, "Invalid V in getSignature")

proc simpleDecode*(dst: var FQ2, src: openArray[byte]): bool {.noinit.} =
  # bypassing FQ2.fromBytes
  # because we want to check `value > modulus`
  result = false
  if dst.c1.fromBytes(src.toOpenArray(0, 31)) and
     dst.c0.fromBytes(src.toOpenArray(32, 63)):
    result = true

template simpleDecode*(dst: var FQ, src: openArray[byte]): bool =
  fromBytes(dst, src)

proc getPoint[T: G1|G2](t: typedesc[T], data: openArray[byte]): Point[T] =
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

proc getFR(data: openArray[byte]): FR =
  if not result.fromBytes2(data):
    raise newException(ValidationError, "Could not get FR value")

proc ecRecover*(c: Computation) =
  c.gasMeter.consumeGas(
    GasECRecover,
    reason="ECRecover Precompile")

  var
    (msgHash, sig) = c.getSignature()

  var pubkey = recover(sig, SkMessage(msgHash))
  if pubkey.isErr:
    raise newException(ValidationError, "Could not derive public key from c")

  c.output.setLen(32)
  c.output[12..31] = pubkey[].toCanonicalAddress()
  #trace "ECRecover precompile", derivedKey = pubkey[].toCanonicalAddress()

proc sha256*(c: Computation) =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  c.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  c.output = @(sha2.sha256.digest(c.msg.data).data)
  #trace "SHA256 precompile", output = c.output.toHex

proc ripemd160*(c: Computation) =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  c.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  c.output.setLen(32)
  c.output[12..31] = @(ripemd.ripemd160.digest(c.msg.data).data)
  #trace "RIPEMD160 precompile", output = c.output.toHex

proc identity*(c: Computation) =
  let
    wordCount = wordCount(c.msg.data.len)
    gasFee = GasIdentity + wordCount * GasIdentityWord

  c.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  c.output = c.msg.data
  #trace "Identity precompile", output = c.output.toHex

proc modExpFee(c: Computation, baseLen, expLen, modLen: UInt256, fork: EVMFork): GasInt =
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
    raise newException(OutOfGas, "modExp gas overflow")

  result = gasFee.truncate(GasInt)

  # EIP2565: modExp gas cost
  if fork >= FkBerlin and result < 200.GasInt:
    result = 200.GasInt

proc modExp*(c: Computation, fork: EVMFork = FkByzantium) =
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

  let gasFee = modExpFee(c, baseL, expL, modL, fork)
  c.gasMeter.consumeGas(gasFee, reason="ModExp Precompile")

  if baseLen == 0 and modLen == 0:
    # This is a special case where expLength can be very big.
    c.output = @[]
    return

  const maxSize = int32.high.u256
  if baseL > maxSize or expL > maxSize or modL > maxSize:
    raise newException(EVMError, "The Nimbus VM doesn't support oversized modExp operand")

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
    c.output = @(output[^modLen..^1])
  else:
    c.output = newSeq[byte](modLen)
    c.output[^output.len..^1] = output[0..^1]

proc bn256ecAdd*(c: Computation, fork: EVMFork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECAdd else: GasECAddIstanbul
  c.gasMeter.consumeGas(gasFee, reason = "ecAdd Precompile")

  var
    input: array[128, byte]
    output: array[64, byte]
  # Padding data
  let len = min(c.msg.data.len, 128) - 1
  input[0..len] = c.msg.data[0..len]
  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var p2 = G1.getPoint(input.toOpenArray(64, 127))
  var apo = (p1 + p2).toAffine()
  if isSome(apo):
    # we can discard here because we supply proper buffer
    discard apo.get().toBytes(output)

  c.output = @output

proc bn256ecMul*(c: Computation, fork: EVMFork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECMul else: GasECMulIstanbul
  c.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")

  var
    input: array[96, byte]
    output: array[64, byte]

  # Padding data
  let len = min(c.msg.data.len, 96) - 1
  input[0..len] = c.msg.data[0..len]
  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var fr = getFR(input.toOpenArray(64, 95))
  var apo = (p1 * fr).toAffine()
  if isSome(apo):
    # we can discard here because we supply buffer of proper size
    discard apo.get().toBytes(output)

  c.output = @output

proc bn256ecPairing*(c: Computation, fork: EVMFork = FkByzantium) =
  let msglen = len(c.msg.data)
  if msglen mod 192 != 0:
    raise newException(ValidationError, "Invalid input length")

  let numPoints = msglen div 192
  let gasFee = if fork < FkIstanbul:
                 GasECPairingBase + numPoints * GasECPairingPerPoint
               else:
                 GasECPairingBaseIstanbul + numPoints * GasECPairingPerPointIstanbul
  c.gasMeter.consumeGas(gasFee, reason="ecPairing Precompile")

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
      var p1 = G1.getPoint(c.msg.data.toOpenArray(s, s + 63))
      # Loading AffinePoint[G2], bytes from [64..191]
      var p2 = G2.getPoint(c.msg.data.toOpenArray(s + 64, s + 191))
      # Accumulate pairing result
      acc = acc * pairing(p1, p2)

    if acc == FQ12.one():
      # we can discard here because we supply buffer of proper size
      discard BNU256.one().toBytes(output)

  c.output = @output

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

proc pointEvaluation*(c: Computation) =
  # Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
  # Also verify that the provided commitment matches the provided versioned_hash.
  # The data is encoded as follows: versioned_hash | z | y | commitment | proof |

  template input: untyped =
    c.msg.data

  c.gasMeter.consumeGas(POINT_EVALUATION_PRECOMPILE_GAS,
    reason = "EIP-4844 Point Evaluation Precompile")

  let res = pointEvaluation(input)
  if res.isErr:
    raise newException(ValidationError, res.error)

  # return a constant
  c.output = @PointEvaluationResult

proc execPrecompiles*(c: Computation, fork: EVMFork): bool {.inline.} =
  for i in 0..18:
    if c.msg.codeAddress[i] != 0: return

  let lb = c.msg.codeAddress[19]
  if not validPrecompileAddr(lb, fork):
    return

  let precompile = PrecompileAddresses(lb)
  try:
    case precompile
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
  except OutOfGas as e:
    c.setError(EVMC_OUT_OF_GAS, e.msg, true)
  except CatchableError as e:
    if fork >= FkByzantium and precompile > paIdentity:
      c.setError(EVMC_PRECOMPILE_FAILURE, e.msg, true)
    else:
      # swallow any other precompiles errors
      debug "execPrecompiles validation error", msg=e.msg
  true
