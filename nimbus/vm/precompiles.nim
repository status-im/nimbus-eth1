import
  ../vm_types, interpreter/[gas_meter, gas_costs, utils/utils_numeric],
  ../errors, stint, eth_keys, eth_common, chronicles, tables, macros,
  message, math, nimcrypto, bncurve/[fields, groups]

type
  PrecompileAddresses* = enum
    paEcRecover = 1,
    paSha256,
    paRipeMd160,
    paIdentity,
    #
    paModExp,
    paEcAdd,
    paEcMul,
    paPairing = 8

proc getSignature*(computation: BaseComputation): (array[32, byte], Signature) =
  # input is Hash, V, R, S
  template data: untyped = computation.msg.data
  var bytes: array[65, byte]
  let maxPos = min(data.high, 127)
  if maxPos >= 32:
    # extract message hash
    result[0][0..31] = data[0..31]
    if maxPos >= 127:
      # Copy message data to buffer
      # Note that we need to rearrange to R, S, V
      bytes[0..63] = data[64..127]
      let v = data[63]  # TODO: Endian
      assert v.int in 27..28
      bytes[64] = v - 27

  if recoverSignature(bytes, result[1]) != EthKeysStatus.Success:
    raise newException(ValidationError, "Could not recover signature computation")

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

proc ecRecover*(computation: var BaseComputation) =
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

proc sha256*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.rawOutput = @(nimcrypto.sha_256.digest(computation.msg.data).data)
  trace "SHA256 precompile", output = computation.rawOutput.toHex

proc ripemd160*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.rawOutput.setLen(32)
  computation.rawOutput[12..31] = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  trace "RIPEMD160 precompile", output = computation.rawOutput.toHex

proc identity*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasIdentity + wordCount * GasIdentityWord

  computation.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  computation.rawOutput = computation.msg.data
  trace "Identity precompile", output = computation.rawOutput.toHex

proc modExpInternal(computation: var BaseComputation, base_len, exp_len, mod_len: int, T: type StUint) =
  template rawMsg: untyped {.dirty.} =
    computation.msg.data

  let
    base = rawMsg.rangeToPadded[:T](96, 95 + base_len)
    exp = rawMsg.rangeToPadded[:T](96 + base_len, 95 + base_len + exp_len)
    modulo = rawMsg.rangeToPadded[:T](96 + base_len + exp_len, 95 + base_len + exp_len + mod_len)

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
      if exp_len <= 32:
        if exp.isZero(): 0
        else: log2(exp)    # highest-bit in exponent
      else:
        let first32 = rawMsg.rangeToPadded[:Uint256](96 + base_len, 95 + base_len + exp_len)
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
    # TODO: specs mentions that we should return in "M" format
    #       i.e. if Base and exp are uint512 and Modulo an uint256
    #       we should return a 256-bit big-endian byte array

    # Force static evaluation
    func zero(): static array[T.bits div 8, byte] = discard
    func one(): static array[T.bits div 8, byte] =
      when cpuEndian == bigEndian:
        result[^1] = 1
      else:
        result[0] = 1

    # Start with EVM special cases
    if modulo <= 1:
      # If m == 0: EVM returns 0.
      # If m == 1: we can shortcut that to 0 as well
      computation.rawOutput = @(zero())
    elif exp.isZero():
      # If 0^0: EVM returns 1
      # For all x != 0, x^0 == 1 as well
      computation.rawOutput = @(one())
    else:
      computation.rawOutput = @(powmod(base, exp, modulo).toByteArrayBE)

proc modExp*(computation: var BaseComputation) =
  ## Modular exponentiation precompiled contract
  ## Yellow Paper Appendix E
  ## EIP-198 - https://github.com/ethereum/EIPs/blob/master/EIPS/eip-198.md
  # Parsing the data
  template rawMsg: untyped {.dirty.} =
    computation.msg.data
  let # lengths Base, Exponent, Modulus
    base_len = rawMsg.rangeToPadded[:Uint256](0, 31).truncate(int)
    exp_len = rawMsg.rangeToPadded[:Uint256](32, 63).truncate(int)
    mod_len = rawMsg.rangeToPadded[:Uint256](64, 95).truncate(int)

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
    raise newException(ValueError, "The Nimbus VM doesn't support modular exponentiation with numbers larger than uint8192")

proc bn256ecAdd*(computation: var BaseComputation) =
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

  # TODO: gas computation
  # computation.gasMeter.consumeGas(gasFee, reason = "ecAdd Precompile")
  computation.rawOutput = @output

proc bn256ecMul*(computation: var BaseComputation) =
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

  # TODO: gas computation
  # computation.gasMeter.consumeGas(gasFee, reason="ecMul Precompile")
  computation.rawOutput = @output

proc bn256ecPairing*(computation: var BaseComputation) =
  var output: array[32, byte]

  let msglen = len(computation.msg.data)
  if msglen mod 192 != 0:
    raise newException(ValidationError, "Invalid input length")

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

  # TODO: gas computation
  # computation.gasMeter.consumeGas(gasFee, reason="ecPairing Precompile")
  computation.rawOutput = @output

proc execPrecompiles*(computation: var BaseComputation): bool {.inline.} =
  for i in 0..18:
    if computation.msg.codeAddress[i] != 0: return

  let lb = computation.msg.codeAddress[19]
  if lb in PrecompileAddresses.low.byte .. PrecompileAddresses.high.byte:
    result = true
    let precompile = PrecompileAddresses(lb)
    trace "Call precompile", precompile = precompile, codeAddr = computation.msg.codeAddress
    case precompile
    of paEcRecover: ecRecover(computation)
    of paSha256: sha256(computation)
    of paRipeMd160: ripeMd160(computation)
    of paIdentity: identity(computation)
    of paModExp: modExp(computation)
    of paEcAdd: bn256ecAdd(computation)
    of paEcMul: bn256ecMul(computation)
    of paPairing: bn256ecPairing(computation)
