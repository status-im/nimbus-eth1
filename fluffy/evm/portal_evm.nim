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
  ../../nimbus/evm/evmc_helpers,
  ./[evm_loader, portal_evm_context]

export portal_evm_context, results

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
    context: PortalEvmContextRef

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
    input_data:
      if msg.inputData.isSome():
        msg.inputData.get()[0].addr
      else:
        nil,
    input_size:
      if msg.inputData.isSome():
        csize_t(msg.inputData.get().len())
      else:
        0,
    value: msg.value.toEvmc(),
    create2_salt: msg.create2Salt.toEvmc(),
    code_address:
      if msg.codeAddress.isSome():
        msg.codeAddress.get().toEvmc()
      else:
        default(evmc_address),
    code:
      if msg.code.isSome():
        msg.code.get()[0].addr
      else:
        nil,
    code_size:
      if msg.code.isSome():
        csize_t(msg.code.get().len())
      else:
        0,
  )

func init*(T: type PortalEvmRef, context: PortalEvmContextRef): T =
  PortalEvmRef(vmPtr: loadEvmcVM(), context: context)

proc initContext*(evm: PortalEvmRef, context: PortalEvmContextRef) =
  evm.context = context

func abiVersion(evm: PortalEvmRef): int =
  evm.vmPtr.abi_version.int

func name*(evm: PortalEvmRef): string =
  $evm.vmPtr.name

func version*(evm: PortalEvmRef): string =
  $evm.vmPtr.version

# TODO: do we need to use evm.vmPtr.get_capabilities and/or evm.vmPtr.set_option?

proc execute*(
    evm: PortalEvmRef, message: PortalEvmMessage, code: Opt[seq[byte]]
): Result[seq[byte], string] =
  var
    msg = message.toEvmc()
    evmc_result = evm.vmPtr.execute(
      evm.vmPtr,
      hostInteface.addr,
      evm.context.toEvmc(),
      EVMC_LATEST_STABLE_REVISION,
      msg,
      if code.isSome():
        code.get()[0].addr
      else:
        nil,
      if code.isSome():
        csize_t(code.get().len())
      else:
        0,
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
  let evm = PortalEvmRef.init(PortalEvmContextRef.init(Header()))

  # Get the abi version
  echo "PortalEvmRef.abiVersion() = ", evm.abiVersion()

  # Get the evm name
  echo "PortalEvmRef.name() = ", evm.name()

  # Get the evm version
  echo "PortalEvmRef.version() = ", evm.version()

  # Execute some code
  let
    message = PortalEvmMessage(
      kind: PortalEvmMessageKind.CALL,
      staticCall: false,
      depth: 0,
      gas: 200000,
      recipient: address"0xfffffffffffffffffffffffffffffffffffffffe",
      sender: address"0xfffffffffffffffffffffffffffffffffffffffe",
      inputData: Opt.some(@[0x1.byte, 0x2, 0x3]),
      value: 10.u256(),
        #create2Salt: Bytes32
        #codeAddress: Opt[Address]
        #code: Opt[seq[byte]]
    )
    code = Opt.some(hexToSeqByte("0x4360005543600052596000f3"))

  echo evm.execute(message, code)

  # Check if the evm is cleaned up
  echo "Before calling close... PortalEvmRef.isClosed() = ", evm.isClosed()

  # Cleanup the evm to free the resources
  evm.close()
  echo "After calling close... PortalEvmRef.isClosed() = ", evm.isClosed()
