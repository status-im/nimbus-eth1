

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

# Host Interface

proc accountExists(context: evmc_host_context, address: var evmc_address): c99bool {.evmc_abi.} =
  #let accounts = cast[ptr HostContext](context)[].accounts
  raiseAssert("Not implemented")
  discard

proc getStorage(context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32): evmc_bytes32 {.evmc_abi.} =
  raiseAssert("Not implemented")
  discard

proc setStorage(context: evmc_host_context, address: var evmc_address,
                              key, value: var evmc_bytes32): evmc_storage_status {.evmc_abi.} =
  raiseAssert("Not implemented")
  discard

const hostInteface = evmc_host_interface(
  account_exists: accountExists,
  get_storage: getStorage,
  set_storage: setStorage,
  # get_balance: evmc_get_balance_fn,
  # get_code_size: evmc_get_code_size_fn,
  # get_code_hash: evmc_get_code_hash_fn,
  # copy_code: evmc_copy_code_fn,
  # selfdestruct: evmc_selfdestruct_fn,
  # call: evmc_call_fn,
  # get_tx_context: evmc_get_tx_context_fn,
  # get_block_hash: evmc_get_block_hash_fn,
  # emit_log: evmc_emit_log_fn,
  # access_account: evmc_access_account_fn,
  # access_storage: evmc_access_storage_fn,
  # get_transient_storage: evmc_get_transient_storage_fn
  # set_transient_storage: evmc_set_transient_storage_fn,
  # get_delegate_address: evmc_get_delegate_address_fn
)


# Test / Try execute


proc evmc_create_evmone*(): ptr evmc_vm {.cdecl, importc: "evmc_create_evmone", raises: [], gcsafe, dynlib: libevmone.}


when isMainModule:
  # let hostContext = HostContext.init()
  # let cHost: evmc_host_context = evmc_host_context(hostContext.addr)

  # let host = evmc_host_interface(account_exists: accountExists)

  # var adr: evmc_address
  # let res = host.account_exists(cHost, adr)
  # echo "res: ", res
  # host.account_exists = accountExists


  let evm = evmc_create_evmone()
  echo "vm.abi_version: ", evm.abi_version
  echo "vm.name: ", evm.name
  echo "vm.version: ", evm.version
  echo "vm.destroy: ", evm.destroy.isNil()
  echo "vm.execute: ", evm.execute.isNil()
