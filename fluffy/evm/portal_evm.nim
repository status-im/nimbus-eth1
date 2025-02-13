# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  stew/byteutils,
  stew/ptrops,
  chronicles,
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses],
  ../../execution_chain/evm/evmc_helpers,
  ./[evm_loader, portal_evm_state]

export portal_evm_state, results

{.push raises: [].}

logScope:
  topics = "portal_evm"

type
  PortalEvmMessageKind* = enum
    CALL = 0
    DELEGATECALL = 1
    CALLCODE = 2
    CREATE = 3
    CREATE2 = 4
    EOFCREATE = 5

  PortalEvmMessage* = object
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

  PortalEvmRef* = ref object
    vmPtr: ptr evmc_vm
    state: PortalEvmStateRef

  PortalEvmHost = object
    evm: PortalEvmRef
    hostInterface: evmc_host_interface

func hostInterface(): evmc_host_interface

func init*(T: type PortalEvmHost, evm: PortalEvmRef): T =
  PortalEvmHost(evm: evm, hostInterface: hostInterface())

template toEvmc(host: PortalEvmHost): evmc_host_context =
  evmc_host_context(host.addr)

template fromEvmc(host: evmc_host_context): PortalEvmHost =
  cast[ptr PortalEvmHost](host)[]

template state(host: PortalEvmHost): PortalEvmStateRef =
  host.evm.state

template revision(host: PortalEvmHost): evmc_revision =
  host.evm.revision

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

func init*(T: type PortalEvmRef): T =
  PortalEvmRef(vmPtr: loadEvmcVM())

proc `state=`*(evm: PortalEvmRef, state: PortalEvmStateRef) =
  evm.state = state

func state*(evm: PortalEvmRef): PortalEvmStateRef =
  evm.state

func revision(evm: PortalEvmRef): evmc_revision =
  EVMC_LATEST_STABLE_REVISION

func abiVersion*(evm: PortalEvmRef): int =
  evm.vmPtr.abi_version.int

func name*(evm: PortalEvmRef): string =
  $evm.vmPtr.name

func version*(evm: PortalEvmRef): string =
  $evm.vmPtr.version

proc execute*(
    evm: PortalEvmRef, message: PortalEvmMessage, code: Opt[seq[byte]]
): Result[seq[byte], string] =
  let host = PortalEvmHost.init(evm)

  var
    msg = message.toEvmc()
    evmc_result = evm.vmPtr.execute(
      evm.vmPtr,
      host.hostInterface.addr,
      host.toEvmc(),
      evm.revision(),
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

# Eth_Call parameters:
# from: DATA, 20 Bytes - (optional) The address the transaction is sent from.
# to: DATA, 20 Bytes - The address the transaction is directed to.
# gas: QUANTITY - (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
# gasPrice: QUANTITY - (optional) Integer of the gasPrice used for each paid gas
# value: QUANTITY - (optional) Integer of the value sent with this transaction
# input: DATA - (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI in the Solidity documentation(opens in a new tab).

func isClosed*(evm: PortalEvmRef): bool =
  evm.vmPtr.isNil()

proc close(evm: PortalEvmRef) =
  if not evm.vmPtr.isNil():
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
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
  trace "evmc_host_interface.account_exists called", address = adr.to0xHex()

  state.accountExists(adr).c99bool

proc getStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.get_storage called", address = adr.to0xHex(), key = k

  state.getCurrentStorage(adr, k).toEvmc()

proc setStorage(
    host: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
): evmc_storage_status {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
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
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
  trace "evmc_host_interface.get_balance called", address = adr.to0xHex()

  state.getBalance(adr).toEvmc()

proc getCodeSize(
    host: evmc_host_context, address: var evmc_address
): csize_t {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
  trace "evmc_host_interface.get_code_size called", address = adr.to0xHex()

  state.getCodeSize(adr).csize_t

proc getCodeHash(
    host: evmc_host_context, address: var evmc_address
): evmc_bytes32 {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
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
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
  trace "evmc_host_interface.copy_code called",
    address = adr.to0xHex(), code_offset, buffer_size

  state.copyCode(adr, code_offset.int, makeOpenArray(buffer_data, buffer_size.int)).csize_t

proc selfDestruct(
    host: evmc_host_context, address, beneficiary: var evmc_address
) {.evmc_abi.} =
  let
    h = host.fromEvmc()
    state = h.state()
    adr = address.fromEvmc()
    benef = beneficiary.fromEvmc()
  trace "evmc_host_interface.copy_code called",
    address = adr.to0xHex(), beneficiary = benef.to0xHex()

  let balance = state.getBalance(adr)
  state.setBalance(benef, state.getBalance(benef) + balance)

  var recorded = false
  if h.revision() >= EVMC_CANCUN and not state.isCreated(adr):
    state.setBalance(adr, state.getBalance(adr) - balance)
  else:
    state.setBalance(adr, 0.u256)
    state.selfDestruct(adr)
    recorded = true

  discard recorded # TODO: return this once the nim-evmc api is updated


proc call(host: evmc_host_context, msg: var evmc_message): evmc_result {.evmc_abi.} =
  trace "evmc_host_interface.call called", evmc_message # can this be printed?

  let h = host.fromEvmc()
  h.evm.vmPtr.execute(
    h.evm.vmPtr,
    h.hostInterface.addr,
    h.state().toEvmc(),
    EVMC_LATEST_STABLE_REVISION,
      # TODO this should be set based on the current block number
    msg,
    nil,
    0,
  )

proc getTxContext(host: evmc_host_context): evmc_tx_context {.evmc_abi.} =
  trace "evmc_host_interface.get_tx_context called"
  evmc_tx_context()
    # const BlockHeader& header{evm_.block_.header};
    # evmc_tx_context context{};
    # const intx::uint256 base_fee_per_gas{header.base_fee_per_gas.value_or(0)};
    # const intx::uint256 effective_gas_price{evm_.txn_->effective_gas_price(base_fee_per_gas)};
    # intx::be::store(context.tx_gas_price.bytes, effective_gas_price);
    # context.tx_origin = *evm_.txn_->sender();
    # context.block_coinbase = evm_.beneficiary;
    # SILKWORM_ASSERT(header.number <= INT64_MAX);  // EIP-1985
    # context.block_number = static_cast<int64_t>(header.number);
    # context.block_timestamp = static_cast<int64_t>(header.timestamp);
    # SILKWORM_ASSERT(header.gas_limit <= INT64_MAX);  // EIP-1985
    # context.block_gas_limit = static_cast<int64_t>(header.gas_limit);
    # if (header.difficulty == 0) {
    #     // EIP-4399: Supplant DIFFICULTY opcode with RANDOM
    #     // We use 0 header difficulty as the telltale of PoS blocks
    #     std::memcpy(context.block_prev_randao.bytes, header.prev_randao.bytes, kHashLength);
    # } else {
    #     intx::be::store(context.block_prev_randao.bytes, header.difficulty);
    # }
    # intx::be::store(context.chain_id.bytes, intx::uint256{evm_.config().chain_id});
    # intx::be::store(context.block_base_fee.bytes, base_fee_per_gas);
    # const intx::uint256 blob_gas_price{header.blob_gas_price().value_or(0)};
    # intx::be::store(context.blob_base_fee.bytes, blob_gas_price);
    # context.blob_hashes = evm_.txn_->blob_versioned_hashes.data();
    # context.blob_hashes_count = evm_.txn_->blob_versioned_hashes.size();
    # return context;

proc getBlockHash(host: evmc_host_context, number: int64): evmc_bytes32 {.evmc_abi.} =
  doAssert(number >= 0)

  let state = host.fromEvmc().state()
  trace "evmc_host_interface.get_block_hash called", number

  let blockHash = state.getBlockHash(number.uint64).valueOr:
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
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
  trace "evmc_host_interface.access_account called", address = adr

  let warm = state.accessAccount(adr)
  if warm: EVMC_ACCESS_WARM else: EVMC_ACCESS_COLD

proc accessStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_access_status {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.access_account called", address = adr, key = k

  let warm = state.accessStorage(adr, k)
  if warm: EVMC_ACCESS_WARM else: EVMC_ACCESS_COLD

proc getTransientStorage(
    host: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
    adr = address.fromEvmc()
    k = UInt256.fromEvmc(key)
  trace "evmc_host_interface.get_transient_storage called", address = adr, key = k

  state.getTransientStorage(adr, k).toEvmc()

proc setTransientStorage(
    host: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
) {.evmc_abi.} =
  let
    state = host.fromEvmc().state()
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

when isMainModule:
  # Create new instance of the evm
  let evm = PortalEvmRef.init()

  # Set the state to be used during the execution
  evm.state = PortalEvmStateRef.init(Header())

  # Get the abi version
  echo "PortalEvmRef.abiVersion() = ", evm.abiVersion()

  # Get the evm name
  echo "PortalEvmRef.name() = ", evm.name()

  # Get the evm version
  echo "PortalEvmRef.version() = ", evm.version()

  # Execute some code
  block:
    let
      message = PortalEvmMessage(
        kind: PortalEvmMessageKind.CALL,
        # staticCall: false,
        # depth: 0,
        gas: 20000000,
        recipient: address"0xc2edad668740f1aa35e4d8f227fb8e17dca888cd",
        sender: address"0xfffffffffffffffffffffffffffffffffffffffe",
        #inputData: Opt.some(@[0x1.byte, 0x2, 0x3]),
        inputData: Opt.some(
          hexToSeqByte(
            "0x6057361d0000000000000000000000000000000000000000000000000000000000000002"
          )
        ),
          #value: 10.u256(),
          #create2Salt: Bytes32
          #codeAddress: Opt[Address]
          #code: Opt[seq[byte]]
      )
      #code = Opt.some(hexToSeqByte("0x4360005543600052596000f3"))
      code = Opt.some(
        hexToSeqByte(
          "608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033"
        )
      )

    echo evm.execute(message, code)

  let
    message = PortalEvmMessage(
      kind: PortalEvmMessageKind.CALL,
      # staticCall: false,
      # depth: 0,
      gas: 20000000,
      recipient: address"0xc2edad668740f1aa35e4d8f227fb8e17dca888cd",
      sender: address"0xfffffffffffffffffffffffffffffffffffffffe",
      #inputData: Opt.some(@[0x1.byte, 0x2, 0x3]),
      inputData: Opt.some(hexToSeqByte("0x2e64cec1")),
        #value: 10.u256(),
        #create2Salt: Bytes32
        #codeAddress: Opt[Address]
        #code: Opt[seq[byte]]
    )
    #code = Opt.some(hexToSeqByte("0x4360005543600052596000f3"))
    code = Opt.some(
      hexToSeqByte(
        "608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033"
      )
    )

  echo evm.execute(message, code)

  # Check if the evm is cleaned up
  echo "Before calling close... PortalEvmRef.isClosed() = ", evm.isClosed()

  # Cleanup the evm to free the resources
  evm.close()
  echo "After calling close... PortalEvmRef.isClosed() = ", evm.isClosed()
