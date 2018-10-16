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
  debug "ECRecover precompile", derivedKey = pubKey.toCanonicalAddress()

proc sha256*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.rawOutput = @(nimcrypto.sha_256.digest(computation.msg.data).data)
  debug "SHA256 precompile", output = computation.rawOutput.toHex

proc ripemd160*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.rawOutput.setLen(32)
  computation.rawOutput[12..31] = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  debug "RIPEMD160 precompile", output = computation.rawOutput.toHex

proc identity*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasIdentity + wordCount * GasIdentityWord

  computation.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  computation.rawOutput = computation.msg.data
  debug "Identity precompile", output = computation.rawOutput.toHex

proc modExp*(computation: var BaseComputation) =
  ## Modular exponentiation precompiled contract
  # Parsing the data
  template rawMsg: untyped {.dirty.} =
    computation.msg.data
  let
    base_len = rawMsg.rangeToPaddedUint256(0, 31).truncate(int)
    exp_len = rawMsg.rangeToPaddedUint256(32, 63).truncate(int)
    mod_len = rawMsg.rangeToPaddedUint256(64, 95).truncate(int)

    start_exp = 96 + base_len
    start_mod = start_exp + exp_len

    base = rawMsg.rangeToPaddedUint256(96, start_exp - 1)
    exp = rawMsg.rangeToPaddedUint256(start_exp, start_mod - 1)
    modulo = rawMsg.rangeToPaddedUint256(start_mod, start_mod + mod_len - 1)

  block: # Gas cost
    func gasModExp_f(x: Natural): int =
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
        else: log2(exp)
      else:
        let extra = rawMsg.rangeToPaddedUint256(96 + base_len, 127 + base_len)
        if not extra.isZero:
          8 * (exp_len - 32) + extra.log2
        else:
          8 * (exp_len - 32)

    let gasFee = block:
      (
        max(mod_len, base_len).gasModExp_f *
          max(adj_exp_len, 1)
      ) div GasQuadDivisor

  block: # Processing
    # Start with EVM special cases

    # Force static evaluation
    func zero256(): static array[32, byte] = discard
    func one256(): static array[32, byte] =
      when cpuEndian == bigEndian:
        result[^1] = 1
      else:
        result[0] = 1

    if modulo <= 1:
      # If m == 0: EVM returns 0.
      # If m == 1: we can shortcut that to 0 as well
      computation.rawOutput = @(zero256())
    elif exp.isZero():
      # If 0^0: EVM returns 1
      # For all x != 0, x^0 == 1 as well
      computation.rawOutput = @(one256())
    else:
      computation.rawOutput = @(powmod(base, exp, modulo).toByteArrayBE)

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
  const
    bRange = when system.cpuEndian == bigEndian: 0..18 else: 1..19
    bOffset = when system.cpuEndian == bigEndian: 19 else: 0

  for i in bRange:
    if computation.msg.codeAddress[i] != 0: return

  let lb = computation.msg.codeAddress[bOffset]

  if lb in PrecompileAddresses.low.byte .. PrecompileAddresses.high.byte:
    result = true
    let precompile = PrecompileAddresses(lb)
    debug "Call precompile ", precompile = precompile, codeAddr = computation.msg.codeAddress
    case precompile
    of paEcRecover: ecRecover(computation)
    of paSha256: sha256(computation)
    of paRipeMd160: ripeMd160(computation)
    of paIdentity: identity(computation)
    of paModExp: modExp(computation)
    of paEcAdd: bn256ecAdd(computation)
    of paEcMul: bn256ecMul(computation)
    of paPairing: bn256ecPairing(computation)
    else:
      raise newException(ValidationError, "Unknown precompile address " & $lb)
