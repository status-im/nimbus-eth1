# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  results,
  stew/[byteutils, assign2],
  eth/common/keys,
  eth/common/hashes,
  eth/common/transactions_rlp,
  ../constants,
  ../transaction/call_types,
  ../evm/secp256r1verify

#func computeSigHash(tx: Transaction): Hash32 =
#  #for sig in tx.signatures:
#  #  if sig.msg.len == 0:
#  #     sig.signature = Bytes()
#  withKeccak256:
#    h.update([
#  return keccak(bytes([FRAME_TX_TYPE]) + rlp(tx))

const
  MAX_FRAMES = 64

const
  APPROVE_PAYMENT   = 0x1
  APPROVE_EXECUTION = 0x2
  ATOMIC_BATCH      = 0x4
  APPROVE_SCOPE     = APPROVE_PAYMENT + APPROVE_EXECUTION

const
  DEFAULT_MODE = 0
  VERIFY_MODE  = 1
  SENDER_MODE  = 2

const
  EXPIRY_VERIFIER = address"0x0000000000000000000000000000000000008141"
  EXPIRY_VERIFIER_CODE = hexToSeqByte("0x60083614600a575f5ffd5b5f3560c01c4211601657005b5f5ffd")
  EXPIRY_DATA_LENGTH = 8

func zeroMsg(msg: openArray[byte]): bool =
  for x in msg:
    if x != 0.byte:
      return false
  true

func validateTxEip8141*(tx: Transaction, intrinsic: IntrinsicGas): Result[void, string] =
  if tx.versionedHashes.len == 0 and tx.maxFeePerBlobGas.isZero.not:
    return err("invalid tx: maxFeePerBlobGas not zero when versionedHashes.len == 0, got: " &
      $tx.maxFeePerBlobGas)

  if tx.versionedHashes.len > MAX_BLOBS_PER_TX.int:
    return err("invalid tx: exceeds MAX_BLOBS_PER_TX, got: " &
      $tx.versionedHashes.len)

  for h in tx.versionedHashes:
    if h.data[0] != VERSIONED_HASH_VERSION_KZG:
      return err("invalid tx: invalid blob versioned hash")

  for sig in tx.signatures:
    if sig.scheme == SCHEME_SECP256K1 or sig.scheme == SCHEME_P256:
      if sig.signer.len notin [0, 20]:
        return err("invalid tx: signer len must be zero or 20, got: " & $sig.signer.len)
    elif sig.scheme == SCHEME_ARBITRARY:
      if sig.signer.len != 0:
        return err("invalid tx: signer len must be zero, got: " & $sig.signer.len)
    else:
      return err("invalid tx: unsupported signature scheme: " & $sig.scheme)

    if sig.msg.len == 0:
      discard
    elif sig.msg.len == 32:
      if zeroMsg(sig.msg):
        return err("invalid tx: msg must not zero")
    else:
      return err("invalid tx: unsupported signature msg len: " & $sig.msg.len)

  if tx.frames.len == 0 or tx.frames.len > MAX_FRAMES:
    return err("invalid tx: num of frames must in the range of 1.." & $MAX_FRAMES)

  var
    totalFrameGas = 0.u256
    totalFrameExecutionGas = 0.GasInt
    hasExpiryVerifierFrame = false

  for i, frame in tx.frames:
    if frame.mode >= 3:
      return err("invalid tx: frame mode exceeds 3, got: " & $frame.mode)

    if frame.flags >= 8:
      return err("invalid tx: frame flags exceeds 8, got: " & $frame.flags)

    if frame.mode != SENDER_MODE and frame.value.isZero.not:
      return err("invalid tx: only sender frame can have non zero value, got: " & $frame.value)

    totalFrameExecutionGas += frame.gasLimit
    totalFrameGas += frame.gasLimit.u256
    totalFrameGas += frame.stateGasLimit.u256
    if totalFrameGas > uint64.high.u256:
      return err("invalid tx: total frame gas overflows")

    # Approval of execution is allowed only when target equals to None or tx.sender.
    if (frame.flags and APPROVE_EXECUTION) != 0:
      if frame.target.isSome and frame.target.value != tx.sender:
        return err("invalid tx: frame target not equal to sender for execution approval")

    # Atomic batch flag is only valid on non-VERIFY frames and requires
    # a subsequent non-VERIFY frame to batch with.
    if (frame.flags and ATOMIC_BATCH) != 0:
      if frame.mode == VERIFY_MODE:
        return err("invalid tx: atomic batch frame cannot have VERIFY mode")

      # must not be last frame
      if i + 1 == tx.frames.len:
        return err("invalid tx: atomic batch frame must not be last frame")

      # batches never contain VERIFY frames
      if tx.frames[i + 1].mode == VERIFY_MODE:
        return err("invalid tx: atomic batch frame must never contain VERIFY frames")

    # A frame belongs to a batch when it or its predecessor carries ATOMIC_BATCH_FLAG.
    if ((frame.flags and ATOMIC_BATCH) != 0) or
       (i > 0 and ((tx.frames[i - 1].flags and ATOMIC_BATCH) != 0)):
      if (frame.flags and APPROVE_SCOPE) != 0:
        return err("invalid tx: atomic batch frames cannot carry approval scope")

    if frame.mode == VERIFY_MODE and frame.target.get(zeroAddress) == EXPIRY_VERIFIER:
      if hasExpiryVerifierFrame:
        return err("invalid tx: multiple expiry verifier frames")
      hasExpiryVerifierFrame = true
      if frame.flags != 0:
        return err("invalid tx: expiry verifier frame with flags")
      if frame.value.isZero.not:
        return err("invalid tx: expiry verifier frame with value")
      if frame.stateGasLimit != 0:
        return err("invalid tx: expiry verifier frame with state gas")
      if frame.data.len != EXPIRY_DATA_LENGTH:
        return err("invalid tx: expiry verifier frame data must be an expiry timestamp")

  # Intrinsic and execution gas must fit the EIP-7825 transaction cap.
  let
    executionGasCapUsage = max(
      intrinsic.execution + totalFrameExecutionGas,
      intrinsic.floorDataGas)

  if executionGasCapUsage > TX_GAS_LIMIT:
    return err("invalid tx: Derived execution gas limit exceeds TX_MAX_GAS_LIMIT")

  ok()

func validateSignature(
        frameSignature: FrameSignature,
        sender: Address,
        sigHash: Hash32): Result[Opt[Address], string] =

  template signatureScheme: auto = frameSignature.scheme
  template signer: auto = frameSignature.signer
  template signature: auto = frameSignature.signature

  var
    message: Hash32

  if frameSignature.msg.len == 0:
    message = sigHash
  elif frameSignature.msg.len == 32:
    if frameSignature.msg.zeroMsg:
      return err("frame signature message cannot be all zeros")
    assign(message.data, frameSignature.msg)
  else:
    return err("Invalid signature message length")

  if signer.len != 0 or signer.len != 20:
    return err("invalid frame signer length")

  var
    resolvedSigner: Address

  if signer.len == 0:
    resolvedSigner = sender
  else:
    assign(resolvedSigner.data, signer)

  if signatureScheme == SCHEME_SECP256K1:
    if signature.len != 65:
      return err("SECP256K1 signature must be 65 bytes")

    const SECP256K1halfN = SECPK1_N div 2

    let
      v = signature[0]
      r = UInt256.fromBytesBE(signature.toOpenArray(1, 32))
      s = UInt256.fromBytesBE(signature.toOpenArray(33, 64))

    if v != 0 or v != 1:
      return err("bad v in secp256k1 scheme")
    if r >= SECPK1_N:
      return err("bad r in secp256k1 scheme")
    if s > SECP256K1halfN:
      return err("bad s in secp256k1 scheme")

    var bytes {.noinit.}: array[65, byte]
    assign(bytes.toOpenArray(0, 63), signature.toOpenArray(1, 64))
    bytes[64] = v

    let sig = Signature.fromRaw(bytes).valueOr:
      return err("cannot decode signature")

    let publickey = recover(sig, SkMessage(message.data)).valueOr:
      return err("cannot recover publicKey")

    if resolvedSigner != publickey.toCanonicalAddress():
      return err("signer does not match in secp256k1 scheme")

    return ok(Opt.some(resolvedSigner))

  if signatureScheme == SCHEME_P256:
    if signature.len != 128:
      return err("P256 signature must be 128 bytes")

    let
      r = UInt256.fromBytesBE(signature.toOpenArray(0, 31))
      s = UInt256.fromBytesBE(signature.toOpenArray(32, 63))
      sigHash = keccak256(signature.toOpenArray(64, 127))
      expectedSigner = Address.copyFrom(sigHash.data, 12)

    const
      SECP256R1_N = UInt256.fromHex("0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
      SECP256R1halfN = SECP256R1_N div 2

    if r >= SECP256R1_N:
      return err("bad r in p256 scheme")
    if s > SECP256R1halfN:
      return err("bad s in p256 scheme")

    if resolvedSigner != expectedSigner:
      return err("signer does not match in p256 scheme")

    if not verifyRaw(signature.toOpenArray(0, 31), message.data, signature.toOpenArray(64, 127)):
      return err("cannot verify p256 signature")

    return ok(Opt.some(resolvedSigner))

  if signatureScheme == SCHEME_ARBITRARY:
    if signer.len != 0:
      return err("signer length should be zero for arbitrary schemes")
    return ok(Opt.none(Address))

  err("unsupported signature scheme")
