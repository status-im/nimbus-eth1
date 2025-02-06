# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.


import
  std/tables,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses]

export evmc

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}



# Host Context

type
  PortalEvmHostContext = object
    accounts: Table[Address, Account]

func init(T: type PortalEvmHostContext): PortalEvmHostContext =
  PortalEvmHostContext(accounts: initTable[Address, Account]())

func toEvmc(context: PortalEvmHostContext): evmc_host_context =
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


# Using evmone evm

const libevmone* = "libevmone.so"

proc evmc_create_evmone*(): ptr evmc_vm {.cdecl, importc: "evmc_create_evmone", raises: [], gcsafe, dynlib: libevmone.}

# Portal EVM

const EVMC_ABI_VERSION = 10 # TODO: update to support the latest abi version 12

type PortalEvmRef* = ref object
  vmPtr: ptr evmc_vm
  context: PortalEvmHostContext

func isAbiCompatible*(evm: PortalEvmRef): bool

func init*(T: type PortalEvmRef): T =
  let evm = PortalEvmRef(
    vmPtr: evmc_create_evmone(),
    context: PortalEvmHostContext.init()) # TODO: update this to use nimbus evm
  doAssert(evm.isAbiCompatible)
  evm

func abiVersion(evm: PortalEvmRef): int =
  evm.vmPtr.abi_version.int

func isAbiCompatible*(evm: PortalEvmRef): bool =
  evm.abiVersion() == EVMC_ABI_VERSION

func name*(evm: PortalEvmRef): string =
  $evm.vmPtr.name

func version*(evm: PortalEvmRef): string =
  $evm.vmPtr.version

  # Executes the given code using the input from the message.
  #
  # This function MAY be invoked multiple times for a single VM instance.
  #
  # @param vm         The VM instance. This argument MUST NOT be NULL.
  # @param host       The Host interface. This argument MUST NOT be NULL unless
  #                   the @p vm has the ::EVMC_CAPABILITY_PRECOMPILES capability.
  # @param context    The opaque pointer to the Host execution context.
  #                   This argument MAY be NULL. The VM MUST pass the same
  #                   pointer to the methods of the @p host interface.
  #                   The VM MUST NOT dereference the pointer.
  # @param rev        The requested EVM specification revision.
  # @param msg        The call parameters. See ::evmc_message. This argument MUST NOT be NULL.
  # @param code       The reference to the code to be executed. This argument MAY be NULL.
  # @param code_size  The length of the code. If @p code is NULL this argument MUST be 0.
  # @return           The execution result.
  # evmc_execute_fn* = proc(vm: ptr evmc_vm, host: ptr evmc_host_interface,
  #                         context: evmc_host_context, rev: evmc_revision,
  #                         msg: var evmc_message, code: ptr byte, code_size: csize_t):
  #                           evmc_result {.evmc_abi.}
proc execute(evm: PortalEvmRef,
  msg: var evmc_message,
  code: openArray[byte]) =

  doAssert(code.len() > 0)

  discard evm.vmPtr.execute(evm.vmPtr,
    hostInteface.addr,
    evm.context.toEvmc(),
    evmc_revision.EVMC_OSAKA, # TODO: which evm revisions should we support. Just the latest?
    msg, # TODO: message
    code[0].addr,
    code.len().csize_t
    )
  # TODO: return type

func isClosed*(evm: PortalEvmRef): bool =
  evm.vmPtr.isNil()

proc close(evm: PortalEvmRef) =
  if not evm.vmPtr.isNil():
    evm.vmPtr.destroy(evm.vmPtr)
    evm.vmPtr = nil

when isMainModule:
  # let context = HostContext.init()
  # let cHost: evmc_host_context = context.toEvmc()

  # let host = evmc_host_interface(account_exists: accountExists)

  # var adr: evmc_address
  # let res = host.account_exists(cHost, adr)
  # echo "res: ", res


  # echo "vm.execute: ", evm.execute.isNil()

  # Create new instance of the evm
  let evm = PortalEvmRef.init()

  # Get the abi version
  echo "PortalEvmRef.abiVersion() = ", evm.abiVersion()

  # Get the evm name
  echo "PortalEvmRef.name() = ", evm.name()

  # Get the evm version
  echo "PortalEvmRef.version() = ", evm.version()


  # Execute some code




  # Check if the evm is cleaned up
  echo "Before calling close... PortalEvmRef.isClosed() = ", evm.isClosed()

  # Cleanup the evm to free the resources
  evm.close()
  echo "After calling close... PortalEvmRef.isClosed() = ", evm.isClosed()
