import
  ../vm_types, interpreter/[gas_meter, gas_costs],
  ../errors, stint, eth_keys, eth_common, chronicles, tables, macros,
  message

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
  debug "ECRecover derived key ", key = pubKey.toCanonicalAddress()

proc execPrecompiles*(computation: var BaseComputation): bool {.inline.} =
  # TODO: Assumes endian
  for i in 0..18:
    if computation.msg.codeAddress[i] != 0: return
  let lb = computation.msg.codeAddress[19]
  if lb < 9:
    result = true
    let precompile = PrecompileAddresses(lb)
    debug "Call precompile ", precompile = precompile, codeAddr = computation.msg.codeAddress
    case precompile
    of paEcRecover: ecRecover(computation)
    else:
      raise newException(ValidationError, "Unknown precompile address " & $lb)
