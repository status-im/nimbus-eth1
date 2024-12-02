

const libevmone* = "libevmone.so"

import
  std/tables,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses]

export evmc

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

# Host Context

type
  HostContext = object
    accounts: TableRef[Address, Account]

func init(T: type HostContext): HostContext =
  HostContext(accounts: newTable[Address, Account]())

func toEvmc(context: HostContext): evmc_host_context =
  evmc_host_context(context.addr)

# Host Interface

proc accountExists(context: evmc_host_context, address: var evmc_address): c99bool {.evmc_abi.} =
  #let accounts = cast[ptr HostContext](context)[].accounts
  raiseAssert("Not implemented")

proc getStorage(context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32): evmc_bytes32 {.evmc_abi.} =
  raiseAssert("Not implemented")

proc setStorage(context: evmc_host_context, address: var evmc_address,
                              key, value: var evmc_bytes32): evmc_storage_status {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getBalance(context: evmc_host_context, address: var evmc_address): evmc_uint256be {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getCodeSize(context: evmc_host_context, address: var evmc_address): csize_t {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getCodeHash(context: evmc_host_context, address: var evmc_address): evmc_bytes32 {.evmc_abi.} =
  raiseAssert("Not implemented")

proc copyCode(context: evmc_host_context, address: var evmc_address,
                            code_offset: csize_t, buffer_data: ptr byte,
                            buffer_size: csize_t): csize_t {.evmc_abi.} =
  raiseAssert("Not implemented")

proc selfDestruct(context: evmc_host_context, address, beneficiary: var evmc_address) {.evmc_abi.} =
  raiseAssert("Not implemented")

proc call(context: evmc_host_context, msg: var evmc_message): evmc_result {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getTxContext(context: evmc_host_context): evmc_tx_context {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getBlockHash(context: evmc_host_context, number: int64): evmc_bytes32 {.evmc_abi.} =
  raiseAssert("Not implemented")

proc emitLog(context: evmc_host_context, address: var evmc_address,
                           data: ptr byte, data_size: csize_t,
                           topics: ptr evmc_bytes32, topics_count: csize_t) {.evmc_abi.} =
  raiseAssert("Not implemented")

proc accessAccount(context: evmc_host_context, address: var evmc_address): evmc_access_status {.evmc_abi.} =
  raiseAssert("Not implemented")

proc accessStorage(context: evmc_host_context, address: var evmc_address,
                                 key: var evmc_bytes32): evmc_access_status {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getTransientStorage(context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32): evmc_bytes32 {.evmc_abi.} =
  raiseAssert("Not implemented")

proc setTransientStorage(context: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32) {.evmc_abi.} =
  raiseAssert("Not implemented")

proc getDelegateAddress(context: evmc_host_context, address: var evmc_address): evmc_address {.evmc_abi.} =
  raiseAssert("Not implemented")

const hostInteface = evmc_host_interface(
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
  get_delegate_address: getDelegateAddress
)


# Test / Try execute


proc evmc_create_evmone*(): ptr evmc_vm {.cdecl, importc: "evmc_create_evmone", raises: [], gcsafe, dynlib: libevmone.}


when isMainModule:
  let context = HostContext.init()
  let cHost: evmc_host_context = context.toEvmc()

  let host = evmc_host_interface(account_exists: accountExists)

  var adr: evmc_address
  let res = host.account_exists(cHost, adr)
  echo "res: ", res


  let evm = evmc_create_evmone()
  echo "vm.abi_version: ", evm.abi_version
  echo "vm.name: ", evm.name
  echo "vm.version: ", evm.version
  echo "vm.destroy: ", evm.destroy.isNil()
  echo "vm.execute: ", evm.execute.isNil()
