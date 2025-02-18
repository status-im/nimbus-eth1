# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  stew/ptrops,
  chronicles,
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses, transactions],
  ../../execution_chain/common/chain_config,
  ../../execution_chain/transaction,
  ../../execution_chain/evm/evmc_helpers,
  ./[evm_loader, portal_evm_state]

export portal_evm_state, results

{.push raises: [].}

logScope:
  topics = "portal_evm"

type
  # TODO: maybe don't need these extra types
  PortalEvmMessageKind = enum
    CALL = 0
    DELEGATECALL = 1
    CALLCODE = 2
    CREATE = 3
    CREATE2 = 4
    EOFCREATE = 5

  PortalEvmMessage = object
    kind*: PortalEvmMessageKind
    staticCall*: bool
    depth*: int32
    gas*: int64
    recipient*: Address
    sender*: Address
    inputData*: Opt[seq[byte]]
    value*: UInt256
    create2Salt*: base.Bytes32
    codeAddress*: Opt[Address]
    code*: Opt[seq[byte]]

  PortalEvm* = ref object
    vmPtr: ptr evmc_vm
    revision: evmc_revision
    config: ChainConfig
    state: PortalEvmState
    header: Header
    transaction: Transaction
    sender: Address

  PortalEvmHost = object
    evm: PortalEvm
    hostInterface: evmc_host_interface

func hostInterface(): evmc_host_interface

func init(T: type PortalEvmHost, evm: PortalEvm): T =
  PortalEvmHost(evm: evm, hostInterface: hostInterface())

template toEvmc(host: PortalEvmHost): evmc_host_context =
  evmc_host_context(host.addr)

template fromEvmc(host: evmc_host_context): PortalEvmHost =
  cast[ptr PortalEvmHost](host)[]

template addrIfPresent(value: Opt[seq[byte]]): auto =
  if value.isSome():
    value.get()[0].addr
  else:
    nil

template lenIfPresent(value: Opt[seq[byte]]): auto =
  if value.isSome():
    csize_t(value.get().len())
  else:
    0

func toEvmc(msgKind: PortalEvmMessageKind): evmc_call_kind =
  evmc_call_kind(msgKind.int)

func toEvmc(msg: PortalEvmMessage): evmc_message =
  evmc_message(
    kind: msg.kind.toEvmc(),
    flags:
      if msg.staticCall:
        {EVMC_STATIC}
      else:
        {},
    depth: msg.depth,
    gas: msg.gas,
    recipient: msg.recipient.toEvmc(),
    sender: msg.sender.toEvmc(),
    input_data: msg.inputData.addrIfPresent(),
    input_size: msg.inputData.lenIfPresent(),
    value: msg.value.toEvmc(),
    create2_salt: msg.create2Salt.toEvmc(),
    code_address:
      if msg.codeAddress.isSome():
        msg.codeAddress.get().toEvmc()
      else:
        default(evmc_address),
    code: msg.code.addrIfPresent(),
    code_size: msg.code.lenIfPresent(),
  )

proc init*(T: type PortalEvm, evmPath: string): T =
  PortalEvm(
    vmPtr: loadEvmcVM(evmPath),
    revision: EVMC_LATEST_STABLE_REVISION,
    config: chainConfigForNetwork(MainNet),
  )

func getRevision(evm: PortalEvm): evmc_revision =
  let
    forkTable = evm.config.toForkTransitionTable()
    fork = forkTable.toHardFork(forkDeterminationInfo(evm.header))
  ToEVMFork[fork]

proc setExecutionContext*(evm: PortalEvm, state: PortalEvmState, header: Header) =
  evm.state = state
  evm.header = header
  evm.revision = evm.getRevision()

func abiVersion*(evm: PortalEvm): int =
  evm.vmPtr.abi_version.int

func name*(evm: PortalEvm): string =
  $evm.vmPtr.name

func version*(evm: PortalEvm): string =
  $evm.vmPtr.version

proc execute(
    evm: PortalEvm, message: PortalEvmMessage, code: Opt[seq[byte]]
): Result[seq[byte], string] =
  let host = PortalEvmHost.init(evm)

  var
    msg = message.toEvmc()
    evmc_result = evm.vmPtr.execute(
      evm.vmPtr,
      host.hostInterface.addr,
      host.toEvmc(),
      evm.revision,
      msg,
      code.addrIfPresent(),
      code.lenIfPresent(),
    )

  let
    output = @(makeOpenArray(evmc_result.output_data, evmc_result.output_size.int))
    res =
      if evmc_result.status_code == EVMC_SUCCESS:
        ok(output)
      else:
        err($evmc_result.status_code)

  # Release the evmc_result
  if not evmc_result.release.isNil():
    evmc_result.release(evmc_result)

  return res

proc call*(
    evm: PortalEvm,
    fromAddr = Opt.none(Address),
    toAddr: Address,
    gas = Opt.none(uint64),
    gasPrice = Opt.none(uint64),
    value = Opt.none(UInt256),
    input = Opt.none(seq[byte]),
): Result[seq[byte], string] =
  try:
    let
      code = evm.state.getCode(toAddr)
      message = PortalEvmMessage(
        kind: PortalEvmMessageKind.CALL,
        # staticCall: true,
        # depth: 0,
        sender:
          if fromAddr.isSome():
            fromAddr.get()
          else:
            default(Address),
        recipient: toAddr,
        gas:
          if gas.isSome():
            gas.get().int64
          else:
            550_000_000,
        inputData: input,
        value:
          if value.isSome():
            value.get()
          else:
            0.u256(),
          #create2Salt: Bytes32
          #codeAddress: toAddr.toEvmc(),
          #code: Opt[seq[byte]]
      )

    evm.execute(message, Opt.some(code))
  except PortalEvmStateException as e:
    err(e.msg)

template isClosed*(evm: PortalEvm): bool =
  evm.vmPtr.isNil()

proc close*(evm: PortalEvm) =
  if not evm.isClosed():
    evm.vmPtr.destroy(evm.vmPtr)
    evm.vmPtr = nil

###############################################################################
# EVMC host interface
###############################################################################

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

proc accountExists(
    host: evmc_host_context, address: var evmc_address
): c99bool {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.account_exists called", address = adr.to0xHex()

  state.accountExists(adr).c99bool

proc getStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.get_storage called", address = adr.to0xHex(), key = k

  state.getCurrentStorage(adr, k).toEvmc()

proc setStorage(
    host: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
): evmc_storage_status {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
    v = UInt256.fromEvmc(value)
  trace "evmc_host_interface.set_storage called",
    address = adr.to0xHex(), key = k, value = v

  # Logic copied from Erigon Silkworm EVM.
  # See here: https://github.com/erigontech/silkworm/blob/7ea57b6fc2f4a990363ace3aa91941878da60631/silkworm/core/execution/evm.cpp#L350

  let currentValue = state.getCurrentStorage(adr, k)

  if currentValue == v:
    return EVMC_STORAGE_ASSIGNED

  state.setStorage(adr, k, v)

  let originalValue = state.getOriginalStorage(adr, k)

  if originalValue == currentValue:
    if originalValue.isZero():
      return EVMC_STORAGE_ADDED
    if v.isZero():
      return EVMC_STORAGE_DELETED
    return EVMC_STORAGE_MODIFIED

  if not originalValue.isZero():
    if currentValue.isZero():
      if originalValue == v:
        return EVMC_STORAGE_DELETED_RESTORED
      return EVMC_STORAGE_DELETED_ADDED
    if v.isZero():
      return EVMC_STORAGE_MODIFIED_DELETED
    if originalValue == v:
      return EVMC_STORAGE_MODIFIED_RESTORED
    return EVMC_STORAGE_ASSIGNED

  if originalValue == v:
    return EVMC_STORAGE_ADDED_DELETED

  return EVMC_STORAGE_ASSIGNED

proc getBalance(
    host: evmc_host_context, address: var evmc_address
): evmc_uint256be {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.get_balance called", address = adr.to0xHex()

  state.getBalance(adr).toEvmc()

proc getCodeSize(
    host: evmc_host_context, address: var evmc_address
): csize_t {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.get_code_size called", address = adr.to0xHex()

  state.getCodeSize(adr).csize_t

proc getCodeHash(
    host: evmc_host_context, address: var evmc_address
): evmc_bytes32 {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.get_code_hash called", address = adr.to0xHex()

  state.getCodeHash(adr).toEvmc()

proc copyCode(
    host: evmc_host_context,
    address: var evmc_address,
    code_offset: csize_t,
    buffer_data: ptr byte,
    buffer_size: csize_t,
): csize_t {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.copy_code called",
    address = adr.to0xHex(), code_offset, buffer_size

  state.copyCode(adr, code_offset.int, makeOpenArray(buffer_data, buffer_size.int)).csize_t

proc selfDestruct(
    host: evmc_host_context, address, beneficiary: var evmc_address
): c99bool {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    benef = beneficiary.fromEvmc()
  trace "evmc_host_interface.copy_code called",
    address = adr.to0xHex(), beneficiary = benef.to0xHex()

  let balance = state.getBalance(adr)
  state.setBalance(benef, state.getBalance(benef) + balance)

  var recorded = false
  if h.evm.revision >= EVMC_CANCUN and not state.isCreated(adr):
    state.setBalance(adr, state.getBalance(adr) - balance)
  else:
    state.setBalance(adr, 0.u256)
    state.selfDestruct(adr)
    recorded = true

  recorded

proc call(host: evmc_host_context, msg: var evmc_message): evmc_result {.evmc_abi.} =
  trace "evmc_host_interface.call called"

  let h = host.fromEvmc()
  h.evm.vmPtr.execute(
    h.evm.vmPtr, h.hostInterface.addr, h.evm.state.toEvmc(), h.evm.revision, msg, nil, 0
  )

proc getTxContext(host: evmc_host_context): evmc_tx_context {.evmc_abi.} =
  trace "evmc_host_interface.get_tx_context called"

  let
    h = host.fromEvmc()
    header = h.evm.header
    txn = h.evm.transaction
    sender = h.evm.sender
    baseFeePerGas = header.baseFeePerGas.valueOr:
      0.u256()
    effectiveGasPrice = txn.effectiveGasPrice(baseFeePerGas.truncate(GasInt))

  var context = evmc_tx_context()
  context.tx_gas_price = u256(effectiveGasPrice).toEvmc()
  context.tx_origin = sender.toEvmc()
  context.block_number = header.number.int64
  context.block_timestamp = header.timestamp.int64
  context.block_gas_limit = header.gasLimit.int64
  if header.difficulty.isZero():
    context.block_prev_randao = header.prevRandao().toEvmc()
  else:
    context.block_prev_randao = header.difficulty.toEvmc()
  context.chain_id = u256(h.evm.config.chainId.uint64).toEvmc()
  context.block_base_fee = baseFeePerGas.toEvmc()

proc getBlockHash(host: evmc_host_context, number: int64): evmc_bytes32 {.evmc_abi.} =
  trace "evmc_host_interface.get_block_hash called", number
  doAssert(number >= 0)

  let
    h = host.fromEvmc()
    state = h.evm.state
    blockHash = state.getBlockHash(number.uint64).valueOr:
      return default(evmc_bytes32)

  blockHash.toEvmc()

proc emitLog(
    host: evmc_host_context,
    address: var evmc_address,
    data: ptr byte,
    data_size: csize_t,
    topics: ptr evmc_bytes32,
    topics_count: csize_t,
) {.evmc_abi.} =
  trace "evmc_host_interface.emit_log called", address = address.fromEvmc()
  discard # Implementation not required for Fluffy

proc accessAccount(
    host: evmc_host_context, address: var evmc_address
): evmc_access_status {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
  trace "evmc_host_interface.access_account called", address = adr

  let warm = state.accessAccount(adr)
  if warm: EVMC_ACCESS_WARM else: EVMC_ACCESS_COLD

proc accessStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_access_status {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.access_account called", address = adr, key = k

  let warm = state.accessStorage(adr, k)
  if warm: EVMC_ACCESS_WARM else: EVMC_ACCESS_COLD

proc getTransientStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.get_transient_storage called", address = adr, key = k

  state.getTransientStorage(adr, k).toEvmc()

proc setTransientStorage(
    host: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
) {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.evm.state
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
    v = UInt256.fromEvmc(value)
  trace "evmc_host_interface.get_transient_storage called",
    address = adr, key = k, value = v

  state.setTransientStorage(adr, k, v)

func hostInterface(): evmc_host_interface =
  evmc_host_interface(
    account_exists: accountExists,
    get_storage: getStorage,
    set_storage: setStorage,
    get_balance: getBalance,
    get_code_size: getCodeSize,
    get_code_hash: getCodeHash,
    copy_code: copyCode,
    selfdestruct: selfDestruct,
    call: call,
    get_tx_context: getTxContext,
    get_block_hash: getBlockHash,
    emit_log: emitLog,
    access_account: accessAccount,
    access_storage: accessStorage,
    get_transient_storage: getTransientStorage,
    set_transient_storage: setTransientStorage,
  )
