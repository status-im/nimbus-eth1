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
  stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses],
  ../../nimbus/evm/evmc_helpers

export evmc

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

type PortalEvmContext* = object
  accounts: Table[Address, Account]

func init*(T: type PortalEvmContext): PortalEvmContext =
  PortalEvmContext(accounts: initTable[Address, Account]())

func toEvmc*(context: PortalEvmContext): evmc_host_context =
  evmc_host_context(context.addr)

# The below functions implement the EVMC host interface

proc accountExists(
    context: evmc_host_context, address: var evmc_address
): c99bool {.evmc_abi.} =
  echo "accountExists called"
  #let accounts = cast[ptr HostContext](context)[].accounts
  raiseAssert("Not implemented")

proc getStorage(
    context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_bytes32 {.evmc_abi.} =
  echo "getStorage called"
  raiseAssert("Not implemented")

proc setStorage(
    context: evmc_host_context, address: var evmc_address, key, value: var evmc_bytes32
): evmc_storage_status {.evmc_abi.} =
  echo "setStorage called"
  raiseAssert("Not implemented")

proc getBalance(
    context: evmc_host_context, address: var evmc_address
): evmc_uint256be {.evmc_abi.} =
  echo "getBalance called"
  raiseAssert("Not implemented")

proc getCodeSize(
    context: evmc_host_context, address: var evmc_address
): csize_t {.evmc_abi.} =
  echo "getCodeSize called"
  raiseAssert("Not implemented")

proc getCodeHash(
    context: evmc_host_context, address: var evmc_address
): evmc_bytes32 {.evmc_abi.} =
  echo "getCodeHash called"
  raiseAssert("Not implemented")

proc copyCode(
    context: evmc_host_context,
    address: var evmc_address,
    code_offset: csize_t,
    buffer_data: ptr byte,
    buffer_size: csize_t,
): csize_t {.evmc_abi.} =
  echo "copyCode called"
  raiseAssert("Not implemented")

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
  raiseAssert("Not implemented")

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
  raiseAssert("Not implemented")

proc accessStorage(
    context: evmc_host_context, address: var evmc_address, key: var evmc_bytes32
): evmc_access_status {.evmc_abi.} =
  echo "accessStorage called"
  raiseAssert("Not implemented")

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
