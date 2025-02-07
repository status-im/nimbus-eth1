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
  eth/common/[hashes, accounts, addresses],
  ../../nimbus/evm/evmc_helpers,
  ./[evm_loader, portal_evm_context]

export portal_evm_context


type PortalEvmRef* = ref object
  vmPtr: ptr evmc_vm
  context: PortalEvmContext

func isAbiCompatible*(evm: PortalEvmRef): bool

func init*(T: type PortalEvmRef): T =
  let evm = PortalEvmRef(
    vmPtr: loadEvmcVM(),
    context: PortalEvmContext.init()) # TODO: update this to use nimbus evm
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
    # kind: EVMC_CREATE, # Only support call for now. Do we need to support EVMC_DELEGATECALL or EVMC_CALLCODE?
    # #flags: {EVMC_STATIC}, # Should we use static call?
    # depth: 0, # use zero depth as only call is supported. Double check this
    gas: 99999999999999999.int64, # set a large value for now. Should this be passed in?
    # recipient: recipient.toEvmc(),
    # sender: sender.toEvmc(),
    # input_data: if inputData.len() > 0: inputData[0].addr else: nil,
    # input_size: inputData.len().csize_t,
    # value: value.toEvmc(),
    # #create2_salt: # only required when creating contracts
    # code_address: codeAddress.toEvmc() ,
    # code: code[0].addr,
    # code_size: code.len().csize_t
    )

  var evmc_result = evm.vmPtr.execute(evm.vmPtr,
    hostInteface.addr,
    evm.context.toEvmc(),
    EVMC_LATEST_STABLE_REVISION, # TODO: We may need to support multiple revisions so that we can execute from any block in the history
    msg,
    code[0].addr,
    code.len().csize_t
    )

  let output =
    if evmc_result.output_size.int == 0:
      @[]
    else:
      @(makeOpenArray(evmc_result.output_data, evmc_result.output_size.int))
  echo output

  let res =
    if evmc_result.status_code == EVMC_SUCCESS:
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
  let byteCode = hexToSeqByte("0x4360005543600052596000f3")

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
