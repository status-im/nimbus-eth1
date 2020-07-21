# Nimbus
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

proc hostReleaseResultImpl(res: var nimbus_result) {.cdecl, gcsafe.} =
  dealloc(res.output_data)

proc hostGetTxContextImpl(ctx: Computation): nimbus_tx_context {.cdecl.} =
  let vmstate = ctx.vmState
  result.tx_gas_price = toEvmc(vmstate.txGasPrice.u256)
  result.tx_origin = vmstate.txOrigin
  result.block_coinbase = vmstate.coinbase
  result.block_number = vmstate.blockNumber.truncate(int64)
  result.block_timestamp = vmstate.timestamp.toUnix()
  result.block_gas_limit = int64(vmstate.blockHeader.gasLimit)
  result.block_difficulty = toEvmc(vmstate.difficulty)
  result.chain_id = toEvmc(vmstate.chaindb.config.chainId.u256)

proc hostGetBlockHashImpl(ctx: Computation, number: int64): Hash256 {.cdecl.} =
  ctx.vmState.getAncestorHash(number.u256)

proc hostAccountExistsImpl(ctx: Computation, address: EthAddress): bool {.cdecl.} =
  let db = ctx.vmState.readOnlyStateDB
  if ctx.fork >= FkSpurious:
    not db.isDeadAccount(address)
  else:
    db.accountExists(address)

proc hostGetStorageImpl(ctx: Computation, address: EthAddress, key: var evmc_bytes32): evmc_bytes32 {.cdecl.} =
  ctx.vmState.accountDB.getStorage(address, Uint256.fromEvmc(key)).toEvmc()

proc sstoreNetGasMetering(ctx: Computation): bool {.inline.} =
  ctx.fork in {FkConstantinople, FkIstanbul}

proc hostSetStorageImpl(ctx: Computation, address: EthAddress,
                        key, value: var evmc_bytes32): evmc_storage_status {.cdecl.} =
  let
    slot = Uint256.fromEvmc(key)
    newValue = Uint256.fromEvmc(value)
    statedb = ctx.vmState.readOnlyStateDb
    currValue = statedb.getStorage(address, slot)

  assert address == ctx.msg.contractAddress

  var
    status = EVMC_STORAGE_MODIFIED
    gasRefund = 0.GasInt
    origValue = 0.u256

  if newValue == currValue:
    status = EVMC_STORAGE_UNCHANGED
  else:
    origValue = statedb.getCommittedStorage(address, slot)
    if origValue == currValue or not ctx.sstoreNetGasMetering():
      if currValue == 0:
        status = EVMC_STORAGE_ADDED
      elif newValue == 0:
        status = EVMC_STORAGE_DELETED
    else:
      status = EVMC_STORAGE_MODIFIED_AGAIN
    ctx.vmState.mutateStateDB:
      db.setStorage(address, slot, newValue)

  let gasParam = GasParams(kind: Op.Sstore,
      s_status: status,
      s_currentValue: currValue,
      s_originalValue: origValue
    )
  gasRefund = ctx.gasCosts[Sstore].c_handler(newValue, gasParam)[1]

  if gasRefund != 0:
    ctx.gasMeter.refundGas(gasRefund)

  result = status

proc hostGetBalanceImpl(ctx: Computation, address: EthAddress): evmc_bytes32 {.cdecl.} =
  ctx.vmState.readOnlyStateDB.getBalance(address).toEvmc()

proc hostGetCodeSizeImpl(ctx: Computation, address: EthAddress): uint {.cdecl.} =
  ctx.vmState.readOnlyStateDB.getCode(address).len.uint

proc hostGetCodeHashImpl(ctx: Computation, address: EthAddress): Hash256 {.cdecl.} =
  let db = ctx.vmstate.readOnlyStateDB
  if not db.accountExists(address):
    return
  if db.isEmptyAccount(address):
    return
  db.getCodeHash(address)

proc hostCopyCodeImpl(ctx: Computation, address: EthAddress,
                      codeOffset: int, bufferData: ptr byte,
                      bufferSize: int): int {.cdecl.} =

  var code = ctx.vmState.readOnlyStateDB.getCode(address)

  # Handle "big offset" edge case.
  if codeOffset > code.len:
    return 0

  let maxToCopy = code.len - codeOffset
  let numToCopy = min(maxToCopy, bufferSize)
  if numToCopy > 0:
    copyMem(bufferData, code[codeOffset].addr, numToCopy)
  result = numToCopy

proc hostSelfdestructImpl(ctx: Computation, address, beneficiary: EthAddress) {.cdecl.} =
  assert address == ctx.msg.contractAddress
  ctx.execSelfDestruct(beneficiary)

proc hostEmitLogImpl(ctx: Computation, address: EthAddress,
                     data: ptr byte, dataSize: int,
                     topics: UncheckedArray[evmc_bytes32], topicsCount: int) {.cdecl.} =
  var log: Log
  if topicsCount > 0:
    log.topics = newSeq[Topic](topicsCount)
    for i in 0 ..< topicsCount:
      log.topics[i] = topics[i].bytes

  log.data = @(makeOpenArray(data, dataSize))
  log.address = address
  ctx.addLogEntry(log)

template createImpl(c: Computation, m: nimbus_message, res: nimbus_result) =
  # TODO: use evmc_message to evoid copy
  let childMsg = Message(
    kind: CallKind(m.kind),
    depth: m.depth,
    gas: m.gas,
    sender: m.sender,
    value: Uint256.fromEvmc(m.value),
    data: @(makeOpenArray(m.inputData, m.inputSize.int))
    )

  let child = newComputation(c.vmState, childMsg, Uint256.fromEvmc(m.create2_salt))
  child.execCreate()

  if not child.shouldBurnGas:
    res.gas_left = child.gasMeter.gasRemaining

  if child.isSuccess:
    c.merge(child)
    res.status_code = EVMC_SUCCESS
    res.create_address = child.msg.contractAddress
  else:
    res.status_code = if child.shouldBurnGas: EVMC_FAILURE else: EVMC_REVERT
    if child.output.len > 0:
      # TODO: can we move the ownership of seq to raw pointer?
      res.output_size = child.output.len.uint
      res.output_data = cast[ptr byte](alloc(child.output.len))
      copyMem(res.output_data, child.output[0].addr, child.output.len)
      res.release = hostReleaseResultImpl

template callImpl(c: Computation, m: nimbus_message, res: nimbus_result) =
  let childMsg = Message(
    kind: CallKind(m.kind),
    depth: m.depth,
    gas: m.gas,
    sender: m.sender,
    codeAddress: m.destination,
    contractAddress: if m.kind == EVMC_CALL: m.destination else: c.msg.contractAddress,
    value: Uint256.fromEvmc(m.value),
    data: @(makeOpenArray(m.inputData, m.inputSize.int)),
    flags: MsgFlags(m.flags)
    )

  let child = newComputation(c.vmState, childMsg)
  child.execCall()

  if not child.shouldBurnGas:
    res.gas_left = child.gasMeter.gasRemaining

  if child.isSuccess:
    c.merge(child)
    res.status_code = EVMC_SUCCESS
  else:
    res.status_code = if child.shouldBurnGas: EVMC_FAILURE else: EVMC_REVERT

  if child.output.len > 0:
    # TODO: can we move the ownership of seq to raw pointer?
    res.output_size = child.output.len.uint
    res.output_data = cast[ptr byte](alloc(child.output.len))
    copyMem(res.output_data, child.output[0].addr, child.output.len)
    res.release = hostReleaseResultImpl

proc hostCallImpl(ctx: Computation, msg: var nimbus_message): nimbus_result {.cdecl.} =
  if msg.kind == EVMC_CREATE or msg.kind == EVMC_CREATE2:
    createImpl(ctx, msg, result)
  else:
    callImpl(ctx, msg, result)

proc initHostInterface(): evmc_host_interface =
  result.account_exists = cast[evmc_account_exists_fn](hostAccountExistsImpl)
  result.get_storage = cast[evmc_get_storage_fn](hostGetStorageImpl)
  result.set_storage = cast[evmc_set_storage_fn](hostSetStorageImpl)
  result.get_balance = cast[evmc_get_balance_fn](hostGetBalanceImpl)
  result.get_code_size = cast[evmc_get_code_size_fn](hostGetCodeSizeImpl)
  result.get_code_hash = cast[evmc_get_code_hash_fn](hostGetCodeHashImpl)
  result.copy_code = cast[evmc_copy_code_fn](hostCopyCodeImpl)
  result.selfdestruct = cast[evmc_selfdestruct_fn](hostSelfdestructImpl)
  result.call = cast[evmc_call_fn](hostCallImpl)
  result.get_tx_context = cast[evmc_get_tx_context_fn](hostGetTxContextImpl)
  result.get_block_hash = cast[evmc_get_block_hash_fn](hostGetBlockHashImpl)
  result.emit_log = cast[evmc_emit_log_fn](hostEmitLogImpl)

proc vmSetOptionImpl(vm: ptr evmc_vm, name, value: cstring): evmc_set_option_result {.cdecl.} =
  return EVMC_SET_OPTION_INVALID_NAME

proc vmExecuteImpl(vm: ptr evmc_vm, host: ptr evmc_host_interface,
                   ctx: Computation, rev: evmc_revision,
                   msg: evmc_message, code: ptr byte, code_size: uint): evmc_result {.cdecl.} =
  discard

proc vmGetCapabilitiesImpl(vm: ptr evmc_vm): evmc_capabilities {.cdecl.} =
  result.incl(EVMC_CAPABILITY_EVM1)

proc vmDestroyImpl(vm: ptr evmc_vm) {.cdecl.} =
  dealloc(vm)

const
  EVMC_HOST_NAME = "nimbus_vm"
  EVMC_VM_VERSION = "0.0.1"

proc init(vm: var evmc_vm) =
  vm.abi_version = EVMC_ABI_VERSION
  vm.name = EVMC_HOST_NAME
  vm.version = EVMC_VM_VERSION
  vm.destroy = vmDestroyImpl
  vm.execute = cast[evmc_execute_fn](vmExecuteImpl)
  vm.get_capabilities = vmGetCapabilitiesImpl
  vm.set_option = vmSetOptionImpl

let gHost = initHostInterface()
proc nim_host_get_interface(): ptr nimbus_host_interface {.exportc, cdecl.} =
  result = cast[ptr nimbus_host_interface](gHost.unsafeAddr)

proc nim_host_create_context(vmstate: BaseVmState, msg: ptr evmc_message): Computation {.exportc, cdecl.} =
  #result = HostContext(
  #  vmState: vmstate,
  #  gasPrice: GasInt(gasPrice),
  #  origin: fromEvmc(origin)
  #)
  GC_ref(result)

proc nim_host_destroy_context(ctx: Computation) {.exportc, cdecl.} =
  GC_unref(ctx)

proc nim_create_nimbus_vm(): ptr evmc_vm {.exportc, cdecl.} =
  result = create(evmc_vm)
  init(result[])
