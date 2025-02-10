# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[tables, sets],
  chronos,
  chronicles,
  stew/byteutils,
  stew/ptrops,
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses, headers],
  ../../nimbus/evm/evmc_helpers,
  ../network/state/state_endpoints

export evmc, addresses, stint, headers, state_network

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

logScope:
  topics = "portal_evm"

# TODO: transaction context
type PortalEvmContextRef* = ref object
  header: Header
  accounts: Table[Address, Account]
  code: Table[Address, seq[byte]]
  storage: Table[Address, Table[UInt256, UInt256]]
  transientStorage: Table[Address, Table[UInt256, UInt256]]
  stateNetwork: Opt[StateNetwork] # when none network lookups are disabled
  fetchedAccounts: HashSet[Address]
  fetchedCode: HashSet[Address]
  fetchedStorage: Table[Address, HashSet[UInt256]]

func init*(
    T: type PortalEvmContextRef, header: Header, stateNetwork = Opt.none(StateNetwork)
): PortalEvmContextRef =
  PortalEvmContextRef(header: header, stateNetwork: stateNetwork)

# TODO: implement a function to clear the transient storage after executing a transaction

template toEvmc*(context: PortalEvmContextRef): evmc_host_context =
  evmc_host_context(context.addr)

template fromEvmc(context: evmc_host_context): PortalEvmContextRef =
  cast[ptr PortalEvmContextRef](context)[]

proc fetchAccountIfRequired(context: PortalEvmContextRef, address: Address) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in context.fetchedAccounts:
    return # already fetched account

  try:
    let account = waitFor(sn.getAccount(context.header.stateRoot, address)).valueOr:
      raiseAssert("account lookup failed") # how should we handle this?
    context.accounts[address] = account
    context.fetchedAccounts.incl(address)
  except CancelledError:
    trace "stateNetwork.getAccount canceled"

proc fetchCodeIfRequired(context: PortalEvmContextRef, address: Address) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if address in context.fetchedCode:
    return # already fetched code

  try:
    let code = waitFor(sn.getCodeByStateRoot(context.header.stateRoot, address)).valueOr:
      raiseAssert("code lookup failed") # how should we handle this?
    context.code[address] = code.asSeq()
    context.fetchedCode.incl(address)
  except CancelledError:
    trace "stateNetwork.getCodeByStateRoot canceled"

proc fetchStorageIfRequired(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
) =
  let sn = context.stateNetwork.valueOr:
    return # state lookups over portal network are disabled

  if slotKey in context.fetchedStorage.getOrDefault(address):
    return # already fetched storage

  try:
    let slotValue = waitFor(
      sn.getStorageAtByStateRoot(context.header.stateRoot, address, slotKey)
    ).valueOr:
      raiseAssert("storage lookup failed") # how should we handle this?

    context.storage.withValue(address, value):
      value[][slotKey] = slotValue
    do:
      context.storage[address] = {slotKey: slotValue}.toTable

    context.fetchedStorage.withValue(address, value):
      value[].incl(slotKey)
    do:
      context.fetchedStorage[address] = toHashSet([slotKey])
  except CancelledError:
    trace "stateNetwork.getStorageAtByStateRoot canceled"

proc accountExists*(context: PortalEvmContextRef, address: Address): bool =
  context.fetchAccountIfRequired(address)
  context.accounts.contains(address)

proc getStorage*(
    context: PortalEvmContextRef, address: Address, slotKey: UInt256
): UInt256 =
  context.fetchStorageIfRequired(address, slotKey)
  context.storage.getOrDefault(address).getOrDefault(slotKey)

proc setStorage*(context: PortalEvmContextRef, address: Address, slotKey, slotValue: UInt256) =
  context.storage.withValue(address, value):
    value[][slotKey] = slotValue
  do:
    context.storage[address] = {slotKey: slotValue}.toTable

proc getBalance*(context: PortalEvmContextRef, address: Address): UInt256 =
  context.fetchAccountIfRequired(address)
  context.accounts.getOrDefault(address).balance

proc getCode*(context: PortalEvmContextRef, address: Address): seq[byte] =
  context.fetchCodeIfRequired(address)
  context.code.getOrDefault(address)

proc getCodeSize*(context: PortalEvmContextRef, address: Address): int =
  context.getCode(address).len()

proc getCodeHash*(context: PortalEvmContextRef, address: Address): Hash32 =
  context.getCode(address).keccak256()

proc copyCode*(context: PortalEvmContextRef, address: Address, codeOffset: int, buffer: var openArray[byte]): int =
  let code = context.getCode(address)
  var
    i = 0
  while (i + codeOffset) < code.len() and i < buffer.len():
    buffer[i] = code[i + codeOffset]
    inc i
  i

proc accessAccount*(context: PortalEvmContextRef, address: Address): bool =
  let warm = context.fetchedAccounts.contains(address)
  context.fetchAccountIfRequired(address)
  warm

proc accessStorage*(context: PortalEvmContextRef, address: Address, slotKey: UInt256): bool =
  let warm = context.fetchedStorage.getOrDefault(address).contains(slotKey)
  context.fetchStorageIfRequired(address, slotKey)
  warm

# proc getTransientStorage(
#     context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
# ): evmc_bytes32 {.evmc_abi.} =
#   echo "getTransientStorage called"
#   raiseAssert("Not implemented")

# proc setTransientStorage(
#     context: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
# ) {.evmc_abi.} =
#   echo "setTransientStorage called"
#   raiseAssert("Not implemented")





###############################################################################
# The below functions implement the EVMC host interface
###############################################################################

proc accountExists(
    context: evmc_host_context, address: var evmc_address
): c99bool {.evmc_abi.} =
  echo "accountExists called"
  context.fromEvmc().accountExists(address.fromEvmc()).c99bool

proc getStorage(
    context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  echo "getStorage called"
  context.fromEvmc().getStorage(address.fromEvmc(), UInt256.fromEvmc(key)).toEvmc()

proc setStorage(
    context: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
): evmc_storage_status {.evmc_abi.} =
  echo "setStorage called"
  context.fromEvmc().setStorage(address.fromEvmc(), UInt256.fromEvmc(key), UInt256.fromEvmc(value))
  EVMC_STORAGE_ASSIGNED # TODO: return correct status

proc getBalance(
    context: evmc_host_context, address: var evmc_address
): evmc_uint256be {.evmc_abi.} =
  echo "getBalance called"
  context.fromEvmc().getBalance(address.fromEvmc()).toEvmc()

proc getCodeSize(
    context: evmc_host_context, address: var evmc_address
): csize_t {.evmc_abi.} =
  echo "getCodeSize called"
  context.fromEvmc().getCodeSize(address.fromEvmc()).csize_t

proc getCodeHash(
    context: evmc_host_context, address: var evmc_address
): evmc_bytes32 {.evmc_abi.} =
  echo "getCodeHash called"
  context.fromEvmc().getCodeHash(address.fromEvmc()).toEvmc()

proc copyCode(
    context: evmc_host_context,
    address: var evmc_address,
    code_offset: csize_t,
    buffer_data: ptr byte,
    buffer_size: csize_t,
): csize_t {.evmc_abi.} =
  echo "copyCode called"
  context.fromEvmc().copyCode(address.fromEvmc(), code_offset.int, makeOpenArray(buffer_data, buffer_size.int)).csize_t

proc selfDestruct(
    context: evmc_host_context, address, beneficiary: var evmc_address
) {.evmc_abi.} =
  echo "selfDestruct called"
  raiseAssert("Not implemented")

proc call(context: evmc_host_context, msg: var evmc_message): evmc_result {.evmc_abi.} =
  echo "call called"
  raiseAssert("Not implemented")

proc getTxContext(context: evmc_host_context): evmc_tx_context {.evmc_abi.} =
  echo "getTxContext called"
  evmc_tx_context()
  # raiseAssert("Not implemented")

proc getBlockHash(
    context: evmc_host_context, number: int64
): evmc_bytes32 {.evmc_abi.} =
  echo "getBlockHash called"
  raiseAssert("Not implemented")

proc emitLog(
    context: evmc_host_context,
    address: var evmc_address,
    data: ptr byte,
    data_size: csize_t,
    topics: ptr evmc_bytes32,
    topics_count: csize_t,
) {.evmc_abi.} =
  echo "emitLog called"
  raiseAssert("Not implemented")

proc accessAccount(
    context: evmc_host_context, address: var evmc_address
): evmc_access_status {.evmc_abi.} =
  echo "accessAccount called"
  context.fromEvmc().accessAccount(address.fromEvmc()).evmc_access_status

proc accessStorage(
    context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_access_status {.evmc_abi.} =
  echo "accessStorage called"
  context.fromEvmc().accessStorage(address.fromEvmc(), UInt256.fromEvmc(key)).evmc_access_status

proc getTransientStorage(
    context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  echo "getTransientStorage called"
  raiseAssert("Not implemented")

proc setTransientStorage(
    context: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
) {.evmc_abi.} =
  echo "setTransientStorage called"
  raiseAssert("Not implemented")

proc getDelegateAddress(
    context: evmc_host_context, address: var evmc_address
): evmc_address {.evmc_abi.} =
  echo "getDelegateAddress called"
  raiseAssert("Not implemented")

const hostInteface* = evmc_host_interface(
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
  get_delegate_address: getDelegateAddress,
)
