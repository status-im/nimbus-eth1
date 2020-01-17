# Nimbus
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

proc hostReleaseResultImpl(result: var evmc_result) {.cdecl.} =
  discard

proc hostGetTxContextImpl(ctx: Computation): evmc_tx_context {.cdecl.} =
  let vmstate = ctx.vmState
  result.tx_gas_price = toEvmc(vmstate.txGasPrice.u256)
  result.tx_origin = toEvmc(vmstate.txOrigin)
  result.block_coinbase = toEvmc(vmstate.coinbase)
  result.block_number = vmstate.blockNumber.truncate(int64)
  result.block_timestamp = vmstate.timestamp.toUnix()
  result.block_gas_limit = int64(vmstate.blockHeader.gasLimit)
  result.block_difficulty = toEvmc(vmstate.difficulty)
  result.chain_id = toEvmc(vmstate.chaindb.config.chainId.u256)

proc hostGetBlockHashImpl(ctx: Computation, number: int64): evmc_bytes32 {.cdecl.} =
  ctx.vmState.getAncestorHash(number.u256).toEvmc()

proc hostAccountExistsImpl(ctx: Computation, address: var evmc_address): c99bool {.cdecl.} =
  let db = ctx.vmState.readOnlyStateDB
  if ctx.fork >= FkSpurious:
    not db.isDeadAccount(fromEvmc(address))
  else:
    db.accountExists(fromEvmc(address))

proc hostGetStorageImpl(ctx: Computation, address: var evmc_address, key: var evmc_bytes32): evmc_bytes32 {.cdecl.} =
  let storageAddr = fromEvmc(address)
  assert storageAddr == ctx.msg.contractAddress
  let (storage, _) = ctx.vmState.accountDB.getStorage(storageAddr, Uint256.fromEvmc(key))
  storage.toEvmc()

proc hostSetStorageImpl(ctx: Computation, address: var evmc_address,
                        key, value: var evmc_bytes32): evmc_storage_status {.cdecl.} =
  let
    storageAddr = fromEvmc(address)
    slot = Uint256.fromEvmc(key)
    newValue = Uint256.fromEvmc(value)
    statedb = ctx.vmState.readOnlyStateDb
    (currValue, _) = statedb.getStorage(storageAddr, slot)

  assert storageAddr == ctx.msg.contractAddress

  if newValue == currValue:
    return EVMC_STORAGE_UNCHANGED

  let
    origValue = statedb.getCommittedStorage(storageAddr, slot)
    InitRefundEIP2200  = gasFees[ctx.fork][GasSset] - gasFees[ctx.fork][GasSload]
    CleanRefundEIP2200 = gasFees[ctx.fork][GasSreset] - gasFees[ctx.fork][GasSload]
    ClearRefundEIP2200 = gasFees[ctx.fork][RefundsClear]

  var
    gasRefund = 0.GasInt
    status = EVMC_STORAGE_MODIFIED

  if origValue == currValue or ctx.fork < FkIstanbul:
    if currValue == 0:
      status = EVMC_STORAGE_ADDED
    elif newValue == 0:
      status = EVMC_STORAGE_DELETED
      gasRefund += ClearRefundEIP2200
  else:
    status = EVMC_STORAGE_MODIFIED_AGAIN
    if origValue != 0:
      if currValue == 0:
        gasRefund -= ClearRefundEIP2200  # Can go negative
      if newValue == 0:
        gasRefund += ClearRefundEIP2200
    if origValue == newValue:
      if origValue == 0:
        gasRefund += InitRefundEIP2200
      else:
        gasRefund += CleanRefundEIP2200

  if gasRefund > 0:
    ctx.gasMeter.refundGas(gasRefund)

  ctx.vmState.mutateStateDB:
    db.setStorage(storageAddr, slot, newValue)

  result = status

proc hostGetBalanceImpl(ctx: Computation, address: var evmc_address): evmc_uint256be {.cdecl.} =
  ctx.vmState.readOnlyStateDB.getBalance(fromEvmc(address)).toEvmc()

proc hostGetCodeSizeImpl(ctx: Computation, address: var evmc_address): uint {.cdecl.} =
  ctx.vmState.readOnlyStateDB.getCode(fromEvmc(address)).len.uint

proc hostGetCodeHashImpl(ctx: Computation, address: var evmc_address): evmc_bytes32 {.cdecl.} =
  let
    db = ctx.vmstate.readOnlyStateDB
    address = fromEvmc(address)

  if not db.accountExists(address):
    return

  if db.isEmptyAccount(address):
    return

  db.getCodeHash(address).toEvmc()

proc hostCopyCodeImpl(ctx: Computation, address: var evmc_address,
                      codeOffset: uint, bufferData: ptr byte,
                      bufferSize: uint): uint {.cdecl.} =

  var code = ctx.vmState.readOnlyStateDB.getCode(fromEvmc(address))

  # Handle "big offset" edge case.
  if codeOffset > code.len.uint:
    return 0

  let maxToCopy = code.len - codeOffset.int
  let numToCopy = min(maxToCopy, bufferSize.int)
  if numToCopy > 0:
    copyMem(bufferData, code.slice(codeOffset.int).baseAddr, numToCopy)
  result = numToCopy.uint

proc hostSelfdestructImpl(ctx: Computation, address, beneficiary: var evmc_address) {.cdecl.} =
  assert fromEvmc(address) == ctx.msg.contractAddress
  ctx.registerAccountForDeletion(fromEvmc(beneficiary))

proc hostEmitLogImpl(ctx: Computation, address: var evmc_address,
                     data: ptr byte, dataSize: int,
                     topics: UncheckedArray[evmc_bytes32], topicsCount: int) {.cdecl.} =
  var log: Log
  if topicsCount > 0:
    log.topics = newSeq[Topic](topicsCount)
    for i in 0 ..< topicsCount:
      log.topics[i] = topics[i].bytes

  if dataSize > 0:
    log.data = newSeq[byte](dataSize)
    copyMem(log.data[0].addr, data, dataSize)

  log.address = fromEvmc(address)
  ctx.addLogEntry(log)

proc hostCallImpl(ctx: Computation, msg: var evmc_message): evmc_result {.cdecl.} =
  discard

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
proc nim_host_get_interface(): ptr evmc_host_interface {.exportc, cdecl.} =
  result = gHost.unsafeAddr

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
