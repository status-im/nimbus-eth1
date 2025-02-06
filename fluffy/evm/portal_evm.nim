# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  stew/byteutils,
  stew/ptrops, stint,
  results,
  evmc/evmc,
  eth/common/[hashes, accounts, addresses]

# export evmc

{.pragma: evmc_abi, cdecl, gcsafe, raises: [].}

# Evmc Conversions

const
  evmc_native* {.booldefine.} = false

func toEvmc(a: Address): evmc_address {.inline.} =
  evmc_address(bytes: a.data)

func toEvmc(n: UInt256): evmc_uint256be {.inline.} =
  when evmc_native:
    cast[evmc_uint256be](n)
  else:
    cast[evmc_uint256be](n.toBytesBE)

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

# TODO: do we need to use evm.vmPtr.get_capabilities and/or evm.vmPtr.set_option?

proc execute*(evm: PortalEvmRef,
  recipient: Address,
  sender: Address,
  inputData: openArray[byte],
  value: UInt256,
  codeAddress: Address,
  code: openArray[byte]): Result[seq[byte], string] =
  doAssert(code.len() > 0)

  var msg = evmc_message(
    kind: EVMC_CALL, # Only support call for now. Do we need to support EVMC_DELEGATECALL or EVMC_CALLCODE?
    #flags: {EVMC_STATIC}, # Should we use static call?
    depth: 0, # use zero depth as only call is supported. Double check this
    gas: 99999999999999999.int64, # set a large value for now. Should this be passed in?
    recipient: recipient.toEvmc(),
    sender: sender.toEvmc(),
    input_data: if inputData.len() > 0: inputData[0].addr else: nil,
    input_size: inputData.len().csize_t,
    value: value.toEvmc(),
    #create2_salt: # only required when creating contracts
    code_address: codeAddress.toEvmc(),
    code: code[0].addr,
    code_size: code.len().csize_t)

  var evmc_result = evm.vmPtr.execute(evm.vmPtr,
    hostInteface.addr,
    evm.context.toEvmc(),
    evmc_revision.EVMC_OSAKA, # TODO: which evm revisions should we support. Just the latest?
    msg,
    code[0].addr,
    code.len().csize_t
    )

  let res =
    if evmc_result.status_code == EVMC_SUCCESS:
      let output =
        if evmc_result.output_size.int == 0:
          @[]
        else:
          @(makeOpenArray(evmc_result.output_data, evmc_result.output_size.int))
      ok(output)
    else:
      err($evmc_result.status_code)

  # Release the evmc_result
  if not evmc_result.release.isNil():
    evmc_result.release(evmc_result)

  return res

func isClosed*(evm: PortalEvmRef): bool =
  evm.vmPtr.isNil()

proc close(evm: PortalEvmRef) =
  if not evm.vmPtr.isNil():
    evm.vmPtr.destroy(evm.vmPtr)
    evm.vmPtr = nil

when isMainModule:
  # Create new instance of the evm
  let evm = PortalEvmRef.init()

  # Get the abi version
  echo "PortalEvmRef.abiVersion() = ", evm.abiVersion()

  # Get the evm name
  echo "PortalEvmRef.name() = ", evm.name()

  # Get the evm version
  echo "PortalEvmRef.version() = ", evm.version()


  # Execute some code
  let byteCode = hexToSeqByte("0x6080604052348015600e575f80fd5b506101438061001c5f395ff3fe608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033")

  echo evm.execute(
    default(Address),
    default(Address),
    hexToSeqByte("0x"),
    1.u256,
    default(Address),
    byteCode)

  # Check if the evm is cleaned up
  echo "Before calling close... PortalEvmRef.isClosed() = ", evm.isClosed()

  # Cleanup the evm to free the resources
  evm.close()
  echo "After calling close... PortalEvmRef.isClosed() = ", evm.isClosed()
