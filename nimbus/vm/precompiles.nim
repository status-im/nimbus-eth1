import
  ../vm_types, interpreter/[gas_meter, gas_costs],
  ../errors, stint, eth_keys, eth_common, chronicles, tables, macros,
  message, math, nimcrypto, bncurve/[fields, groups]

type
  PrecompileAddresses = enum
    paEcRecover = 1,
    paSha256,
    paRipeMd160,
    paIdentity,
    #
    paModExp,
    paEcAdd,
    paEcMul,
    paPairing = 8

proc getSignature*(computation: BaseComputation): Signature =
  var bytes: array[128, byte]
  bytes[0..31] = computation.msg.data[32..63]   # V
  bytes[32..63] = computation.msg.data[64..95]  # R
  bytes[64..63] = computation.msg.data[96..128] # S
  result = initSignature(bytes)                 # Can raise

proc getPoint[T: G1|G2](t: typedesc[T], data: openarray[byte]): Point[T] =
  when T is G1:
    const nextOffset = 32
    var px, py: FQ
  else:
    const nextOffset = 64
    var px, py: FQ2
  if not px.fromBytes(data.toOpenArray(0, nextOffset - 1)):
    raise newException(ValidationError, "Could not get point value")
  if not py.fromBytes(data.toOpenArray(nextOffset, nextOffset * 2 - 1)):
    raise newException(ValidationError, "Could not get point value")
  if px.isZero() and py.isZero():
    result = T.zero()
  else:
    var ap: AffinePoint[T]
    if not ap.init(px, py):
      raise newException(ValidationError, "Point is not on curve")
    result = ap.toJacobian()

proc getFR(data: openarray[byte]): FR =
  if not result.fromBytes(data):
    raise newException(ValidationError, "Could not get FR value")

proc ecRecover*(computation: var BaseComputation) =
  computation.gasMeter.consumeGas(
    GasECRecover,
    reason="ECRecover Precompile")

  # TODO: Check endian
  # Assumes V is 27 or 28
  var
    sig = computation.getSignature()
    pubKey: PublicKey
  let msgHash = computation.msg.data[0..31]

  if sig.recoverSignatureKey(msgHash, pubKey) != EthKeysStatus.Success:
    raise newException(ValidationError, "Could not derive public key from computation")

  computation.rawOutput = @(pubKey.toCanonicalAddress())
  debug "ECRecover precompile", derivedKey = pubKey.toCanonicalAddress()

proc sha256*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasSHA256 + wordCount * GasSHA256Word

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.rawOutput = @(keccak_256.digest(computation.msg.data).data)
  debug "SHA256 precompile", output = computation.rawOutput

proc ripemd160(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasRIPEMD160 + wordCount * GasRIPEMD160Word

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.rawOutput = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  debug "RIPEMD160 precompile", output = computation.rawOutput

proc identity*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GasIdentity + wordCount * GasIdentityWord

  computation.gasMeter.consumeGas(gasFee, reason="Identity Precompile")
  computation.rawOutput = computation.msg.data
  debug "Identity precompile", output = computation.rawOutput

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
    let p = apo.get()
    # we can discard here because we supply proper buffer
    discard p.toBytes(output)

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
    let p = apo.get()
    # we can discard here because we supply buffer of proper size
    discard p.toBytes(output)

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
    of paEcAdd: bn256ecAdd(computation)
    of paEcMul: bn256ecMul(computation)
    of paPairing: bn256ecPairing(computation)
    else:
      raise newException(ValidationError, "Unknown precompile address " & $lb)
