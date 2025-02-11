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
  echo output.to0xHex()

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
