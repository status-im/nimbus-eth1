import
  ../vm_types, interpreter/[gas_meter, gas_costs, utils/utils_numeric, vm_forks],
  ../errors, stint, eth/[keys, common], chronicles, tables, macros,
  message, math, nimcrypto, bncurve/[fields, groups], blake2b_f

type
  PrecompileAddresses* = enum
    # Frontier to Spurious Dragron
    paEcRecover = 1,
    paSha256,
    paRipeMd160,
    paIdentity,
    # Byzantium and Constantinople
    paModExp,
    paEcAdd,
    paEcMul,
    paPairing,
    # Istanbul
    paBlake2bf = 9

proc getSignature(computation: BaseComputation): (array[32, byte], Signature) =
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

    if recoverSignature(bytes, result[1]) != EthKeysStatus.Success:
      raise newException(ValidationError, "Could not recover signature computation")

    # extract message hash, only need to copy when there is a valid signature
    result[0][0..31] = data[0..31]
  else:
    raise newException(ValidationError, "Invalid V in getSignature")

proc getPoint[T: G1|G2](t: typedesc[T], data: openarray[byte]): Point[T] =
  when T is G1:
    const nextOffset = 32
    var px, py: FQ
  else:
    const nextOffset = 64
    var px, py: FQ2
  if not px.fromBytes2(data.toOpenArray(0, nextOffset - 1)):
    raise newException(ValidationError, "Could not get point value")
  if not py.fromBytes2(data.toOpenArray(nextOffset, nextOffset * 2 - 1)):
    raise newException(ValidationError, "Could not get point value")

  # "ecpairing_perturb_g2_by_field_modulus_again.json",
  # "ecpairing_perturb_zeropoint_by_field_modulus.json",
  # "ecpairing_perturb_g2_by_field_modulus.json",
  # modulus comparion in FQ2.fromBytes produce different result
  const
    modulus = Uint256.fromHex("30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47")
  let a = Uint256.fromBytesBE(data.toOpenArray(0, 31), false)
  let b = Uint256.fromBytesBE(data.toOpenArray(32, 63), false)
  when T is G2:
    let c = Uint256.fromBytesBE(data.toOpenArray(64, 95), false)
    let d = Uint256.fromBytesBE(data.toOpenArray(96, 127), false)
    if a >= modulus or b >= modulus or c >= modulus or d >= modulus:
      raise newException(ValidationError, "value greater than field modulus")
  else:
    if a >= modulus or b >= modulus:
      raise newException(ValidationError, "value greater than field modulus")

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

proc ecRecover*(computation: BaseComputation) =
  computation.gasMeter.consumeGas(
    GasECRecover,
    reason="ECRecover Precompile")

  var
    (msgHash, sig) = computation.getSignature()
    pubKey: PublicKey

  if sig.recoverSignatureKey(msgHash, pubKey) != EthKeysStatus.Success:
    raise newException(ValidationError, "Could not derive public key from computation")

  computation.rawOutput.setLen(32)
  computation.rawOutput[12..31] = pubKey.toCanonicalAddress()
  trace "ECRecover precompile", derivedKey = pubKey.toCanonicalAddress()

proc sha256*(computation: BaseComputation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.rawOutput = @(nimcrypto.sha_256.digest(computation.msg.data).data)
  trace "SHA256 precompile", output = computation.rawOutput.toHex

proc ripemd160*(computation: BaseComputation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.rawOutput.setLen(32)
  computation.rawOutput[12..31] = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  trace "RIPEMD160 precompile", output = computation.rawOutput.toHex

proc identity*(computation: BaseComputation) =
  let
    wordCount = wordCount(computation.msg.data.len)
    gasFee = GasIdentity + wordCount * GasIdentityWord

  computation.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  computation.rawOutput = computation.msg.data
  trace "Identity precompile", output = computation.rawOutput.toHex

proc modExpInternal(computation: BaseComputation, base_len, exp_len, mod_len: int, T: type StUint) =
  template rawMsg: untyped {.dirty.} =
    computation.msg.data

  block: # Gas cost
    func gasModExp_f(x: Natural): int =
      ## Estimates the difficulty of Karatsuba multiplication
      # x: maximum length in bytes between modulo and base
      # TODO: Deal with negative max_len
      result = case x
        of 0 .. 64: x * x
        of 65 .. 1024: x * x div 4 + 96 * x - 3072
        else: x * x div 16 + 480 * x - 199680

    let adj_exp_len = block:
      # TODO deal with negative length
      let first32 = rawMsg.rangeToPadded2[:Uint256](96 + base_len, 95 + base_len + exp_len, min(exp_len, 32))
      if exp_len <= 32:
        if first32.isZero(): 0
        else: log2(first32)    # highest-bit in exponent
      else:
        # TODO: `modexpRandomInput.json` require Uint256 arithmetic for this code below
        if not first32.isZero:
          8 * (exp_len - 32) + first32.log2
        else:
          8 * (exp_len - 32)

    let gasFee = block:
      (
        max(mod_len, base_len).gasModExp_f *
          max(adj_exp_len, 1)
      ) div GasQuadDivisor

    computation.gasMeter.consumeGas(gasFee, reason="ModExp Precompile")

  block: # Processing
    let
      base = rawMsg.rangeToPadded[:T](96, 95 + base_len, base_len)
      exp = rawMsg.rangeToPadded[:T](96 + base_len, 95 + base_len + exp_len, exp_len)
      modulo = rawMsg.rangeToPadded[:T](96 + base_len + exp_len, 95 + base_len + exp_len + mod_len, mod_len)

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

    # maximum output len is the same as mod_len
    # if it less than mod_len, it will be zero padded at left
    if output.len >= mod_len:
      computation.rawOutput = @(output[^mod_len..^1])
    else:
      computation.rawOutput = newSeq[byte](mod_len)
      computation.rawOutput[^output.len..^1] = output[0..^1]

proc modExp*(computation: BaseComputation) =
  ## Modular exponentiation precompiled contract
  ## Yellow Paper Appendix E
  ## EIP-198 - https://github.com/ethereum/EIPs/blob/master/EIPS/eip-198.md
  # Parsing the data
  template rawMsg: untyped {.dirty.} =
    computation.msg.data

  let # lengths Base, Exponent, Modulus
    base_len = rawMsg.rangeToPadded[:Uint256](0, 31).safeInt
    exp_len = rawMsg.rangeToPadded[:Uint256](32, 63).safeInt
    mod_len = rawMsg.rangeToPadded[:Uint256](64, 95).safeInt

  let maxBytes = max(base_len, max(exp_len, mod_len))
  if maxBytes <= 32:
    computation.modExpInternal(base_len, exp_len, mod_len, UInt256)
  elif maxBytes <= 64:
    computation.modExpInternal(base_len, exp_len, mod_len, StUint[512])
  elif maxBytes <= 128:
    computation.modExpInternal(base_len, exp_len, mod_len, StUint[1024])
  elif maxBytes <= 256:
    computation.modExpInternal(base_len, exp_len, mod_len, StUint[2048])
  elif maxBytes <= 512:
    computation.modExpInternal(base_len, exp_len, mod_len, StUint[4096])
  elif maxBytes <= 1024:
    computation.modExpInternal(base_len, exp_len, mod_len, StUint[8192])
  else:
    raise newException(EVMError, "The Nimbus VM doesn't support modular exponentiation with numbers larger than uint8192")

proc bn256ecAdd*(computation: BaseComputation, fork: Fork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECAdd else: GasECAddIstanbul
  computation.gasMeter.consumeGas(gasFee, reason = "ecAdd Precompile")

  var
    input: array[128, byte]
    output: array[64, byte]
  # Padding data
  let msglen = len(computation.msg.data)
  let tocopy = if msglen < 128: msglen else: 128
  if tocopy > 0:
    copyMem(addr input[0], addr computation.msg.data[0], tocopy)
  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var p2 = G1.getPoint(input.toOpenArray(64, 127))
  var apo = (p1 + p2).toAffine()
  if isSome(apo):
    # we can discard here because we supply proper buffer
    discard apo.get().toBytes(output)

  computation.rawOutput = @output

proc bn256ecMul*(computation: BaseComputation, fork: Fork = FkByzantium) =
  let gasFee = if fork < FkIstanbul: GasECMul else: GasECMulIstanbul
  computation.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")

  var
    input: array[96, byte]
    output: array[64, byte]

  # Padding data
  let msglen = len(computation.msg.data)
  let tocopy = if msglen < 96: msglen else: 96
  if tocopy > 0:
    copyMem(addr input[0], addr computation.msg.data[0], tocopy)

  var p1 = G1.getPoint(input.toOpenArray(0, 63))
  var fr = getFR(input.toOpenArray(64, 95))
  var apo = (p1 * fr).toAffine()
  if isSome(apo):
    # we can discard here because we supply buffer of proper size
    discard apo.get().toBytes(output)

  computation.rawOutput = @output

proc bn256ecPairing*(computation: BaseComputation, fork: Fork = FkByzantium) =
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

  computation.rawOutput = @output

proc blake2bf*(computation: BaseComputation) =
  template input(): untyped =
    computation.msg.data

  if len(input) == blake2FInputLength:
    let gasFee = GasInt(beLoad32(input, 0))
    computation.gasMeter.consumeGas(gasFee, reason="ecPairing Precompile")

  var output: array[64, byte]
  if not blake2b_F(input, output):
    raise newException(ValidationError, "Blake2b F function invalid input")
  else:
    computation.rawOutput = @output

proc getMaxPrecompileAddr(fork: Fork): PrecompileAddresses =
  if fork < FkByzantium: paIdentity
  elif fork < FkIstanbul: paPairing
  else: PrecompileAddresses.high

proc execPrecompiles*(computation: BaseComputation, fork: Fork): bool {.inline.} =
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
      of paModExp: modExp(computation)
      of paEcAdd: bn256ecAdd(computation, fork)
      of paEcMul: bn256ecMul(computation, fork)
      of paPairing: bn256ecPairing(computation, fork)
      of paBlake2bf: blake2bf(computation)
    except OutOfGas as e:
      # cannot use setError here, cyclic dependency
      computation.error = Error(info: e.msg, burnsGas: true)
    except CatchableError as e:
      if fork >= FKByzantium and precompile > paIdentity:
        computation.error = Error(info: e.msg, burnsGas: true)
      else:
        # swallow any other precompiles errors
        debug "execPrecompiles validation error", msg=e.msg
