# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import unittest2, stew/byteutils, ../../evm/portal_evm

suite "Portal EVM Tests":
  let
    recipient = address"0xc2edad668740f1aa35e4d8f227fb8e17dca888cd"
    code = hexToSeqByte(
      "608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033"
    )

  test "Basic call":
    let
      evm = PortalEvm.init()
      state = PortalEvmState.init()

    state.setCode(recipient, code)
    evm.setExecutionContext(state, Header(number: 21844782, timestamp: EthTime.now()))

    let
      r1 = evm.call(
        toAddr = recipient,
        input = Opt.some(
          hexToSeqByte(
            "0x6057361d0000000000000000000000000000000000000000000000000000000000000002"
          )
        ),
      )
      r2 = evm.call(toAddr = recipient, input = Opt.some(hexToSeqByte("0x2e64cec1")))

    check:
      evm.abiVersion() == 12
      r1.isOk()
      r1.get().len() == 0
      r2.isOk()
      UInt256.fromBytesBE(r2.get()) == 2.u256()

    evm.close()

  # Execute some code
  # block:
  #   let
  #     message = PortalEvmMessage(
  #       kind: PortalEvmMessageKind.CALL,
  #       # staticCall: false,
  #       # depth: 0,
  #       gas: 20000000,
  #       recipient: address"0xc2edad668740f1aa35e4d8f227fb8e17dca888cd",
  #       sender: address"0xfffffffffffffffffffffffffffffffffffffffe",
  #       #inputData: Opt.some(@[0x1.byte, 0x2, 0x3]),
  #       inputData: Opt.some(
  #         hexToSeqByte(
  #           "0x6057361d0000000000000000000000000000000000000000000000000000000000000002"
  #         )
  #       ),
  #         #value: 10.u256(),
  #         #create2Salt: Bytes32
  #         #codeAddress: Opt[Address]
  #         #code: Opt[seq[byte]]
  #     )
  #     #code = Opt.some(hexToSeqByte("0x4360005543600052596000f3"))
  #     code = Opt.some(
  #       hexToSeqByte(
  #         "608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033"
  #       )
  #     )

  #   echo evm.execute(message, code)

  # let
  #   recipient = address"0xc2edad668740f1aa35e4d8f227fb8e17dca888cd"
  #   code = hexToSeqByte("608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033")

  # evm.state.setCode(recipient, code)
  # echo evm.call(toAddr = recipient, input = Opt.some(hexToSeqByte("0x2e64cec1")))

  # # Check if the evm is cleaned up
  # echo "Before calling close... PortalEvm.isClosed() = ", evm.isClosed()

  # # Cleanup the evm to free the resources
  # evm.close()
  # echo "After calling close... PortalEvm.isClosed() = ", evm.isClosed()
