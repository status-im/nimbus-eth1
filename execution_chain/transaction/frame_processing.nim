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
  ../core/eip8141,
  ./call_types

proc beginFrameProcessing*(params: CallParams): Result[void, string] =
  let
    sigHash = computeSigHash(params.tx[])
    vmState = params.vmState
    tx = params.tx

  vmState.frameCtx.resolvedSigners.setLen(tx.signatures.len)
  for i, sig in tx.signatures:
    let address = ? validateSignature(sig, tx.sender, sigHash)
    vmState.frameCtx.resolvedSigners[i] = address

  vmState.frameCtx.payer = Opt.none(Address)
  vmState.frameCtx.isSome = true
  vmState.frameCtx.senderApproved = false

func executeDefaultVerifyCode(vmState: BaseVmState, frame: TransactionFrame, resolvedTarget: Address): bool =
  let
    allowedScope = frame.flags and APPROVE_SCOPE_MASK
    tx = vmState.txCtx.tx
    
  # The frame is not allowed to approve anything.
  if allowedScope == 0:
    return false

  let signatureIndex = if (APPROVE_EXECUTION and allowedScope) != 0: 0 else: 1

  # There is no signature entry at the authorizing index.
  if tx.signatures.len <= signatureIndex:
    return false
    
  let 
    signature = tx.signatures[signatureIndex]

  # Only a protocol-validated secp256k1 signature authorizes.
  if signature.scheme != SCHEME_SECP256K1:
    return false
    
  # The signature must cover the canonical signature hash.
  if signature.msg.len != 0:
    return false
    
  # The signature must come from the frame's resolved target.
  if vmState.frameCtx.resolvedSigners[signatureIndex] != resolvedTarget:
    return false

  if not attempt_approval(tx_env, allowedScope):
    return false

  return FrameStatus.SUCCESS
    
#proc setupComputation(params: CallParams, keepStack: bool, vmState: BaseVMState, msg: Message): Computation =
#  # Delay loading code until interpreter_dispatch.prepareDispatch
#  if params.isCreate:
#    msg.contractAddress = generateContractAddress(vmState, params.sender)
#  newComputation(vmState, keepStack, msg)

#proc setupEVM(params: CallParams, keepStack: bool): Computation =
#  let
#    vmState = params.vmState
#    fork = vmState.hardFork
#  vmState.txCtx = TxContext(
#    origin     : params.sender,
#    gasPrice   : params.gasPrice,
#    blobBaseFee: getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
#    tx         : params.tx,
#  )
#
#  # reset global gasRefunded counter each time
#  # EVM called for a new transaction
#  vmState.gasRefunded = 0
#
#  let
#    tx = params.tx
#    destination = tx[].destination
#    msg = Message(
#      kind:              if params.isCreate: CallKind.Create
#                         else: CallKind.Call,
#      gas:               executionGas,
#      stateGasReservoir: stateGasReservoir,
#      contractAddress:   destination,
#      codeAddress:       destination,
#      delegateTo:        destination,
#      sender:            params.sender,
#      value:             tx.value,
#    )
#    computation = setupComputation(params, keepStack, vmState, msg)
#
#  if computation.isSuccess:
#    computation.addRefund(executionRefund)
#    vmState.captureStart(computation, params.sender, destination,
#                         params.isCreate, tx.payload,
#                         tx.gasLimit, tx.value)
#  computation
