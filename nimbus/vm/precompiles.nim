import
  ../vm_types, interpreter/[gas_meter, gas_costs],
  ../errors, stint, eth_keys, eth_common, chronicles, tables, macros,
  message, math, nimcrypto

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

proc ecRecover*(computation: var BaseComputation) =
  computation.gasMeter.consumeGas(
    GAS_ECRECOVER,
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
    gasFee = GAS_SHA256 + wordCount * GAS_SHA256WORD

  computation.gasMeter.consumeGas(gasFee, reason="SHA256 Precompile")
  computation.rawOutput = @(keccak_256.digest(computation.msg.data).data)
  debug "SHA256 precompile", output = computation.rawOutput

proc ripemd160(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GAS_RIPEMD160 + wordCount * GAS_RIPEMD160WORD

  computation.gasMeter.consumeGas(gasFee, reason="RIPEMD160 Precompile")
  computation.rawOutput = @(nimcrypto.ripemd160.digest(computation.msg.data).data)
  debug "RIPEMD160 precompile", output = computation.rawOutput

proc identity*(computation: var BaseComputation) =
  let
    wordCount = computation.msg.data.len div 32
    gasFee = GAS_IDENTITY + wordCount * GAS_IDENTITYWORD

  computation.gasMeter.consumeGas(gas_fee, reason="Identity Precompile")
  computation.rawOutput = computation.msg.data
  debug "Identity precompile", output = computation.rawOutput

proc execPrecompiles*(computation: var BaseComputation): bool {.inline.} =
  const
    bRange = when system.cpuEndian == bigEndian: 0..18 else: 1..19
    bOffset = when system.cpuEndian == bigEndian: 19 else: 0

  for i in bRange:
    if computation.msg.codeAddress[i] != 0: return
  
  let lb = computation.msg.codeAddress[bOffset]

  if lb < 9:
    result = true
    let precompile = PrecompileAddresses(lb)
    debug "Call precompile ", precompile = precompile, codeAddr = computation.msg.codeAddress
    case precompile
    of paEcRecover: ecRecover(computation)
    of paSha256: sha256(computation)
    of paRipeMd160: ripeMd160(computation)
    of paIdentity: identity(computation)
    else:
      raise newException(ValidationError, "Unknown precompile address " & $lb)
