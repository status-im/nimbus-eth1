# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import eth/keys
import stew/byteutils
import unittest2
import ../nimbus/common
import ../nimbus/vm_state
import ../nimbus/vm_types
import ../nimbus/transaction
import ../nimbus/transaction/call_evm
import ../nimbus/db/core_db
import ../nimbus/db/ledger

const
  data = [0x5b.uint8, 0x5a, 0x5a, 0x30, 0x30, 0x30, 0x30, 0x72, 0x00, 0x00, 0x00, 0x58,
    0x58, 0x24, 0x58, 0x58, 0x3a, 0x19, 0x75, 0x75, 0x2e, 0x2e, 0x2e, 0x2e,
    0xec, 0x9f, 0x69, 0x67, 0x7f, 0xff, 0xff, 0xff, 0xff, 0x6c, 0x5a, 0x32,
    0x07, 0xf4, 0x75, 0x75, 0xf5, 0x75, 0x75, 0x75, 0x7f, 0x5b, 0xd9, 0x32,
    0x5a, 0x07, 0x19, 0x34, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
    0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
    0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0xec,
    0x9f, 0x69, 0x67, 0x7f, 0xff, 0xff, 0xff, 0xff, 0x6c, 0xfc, 0xf7, 0xfc,
    0xfc, 0xfc, 0xfc, 0xf4, 0x03, 0x03, 0x81, 0x81, 0x81, 0xfb, 0x7a, 0x30,
    0x80, 0x3d, 0x59, 0x59, 0x59, 0x59, 0x81, 0x00, 0x59, 0x2f, 0x45, 0x30,
    0x32, 0xf4, 0x5d, 0x5b, 0x37, 0x19]

  codeAddress = hexToByteArray[20]("000000000000000000000000636f6e7472616374")
  coinbase = hexToByteArray[20]("4444588443C3a91288c5002483449Aba1054192b")

proc overflowMain*() =
  test "GasCall unhandled overflow":
    let header = BlockHeader(
      blockNumber: u256(1150000),
      coinBase: coinbase,
      gasLimit: 30000000,
      timeStamp: EthTime(123456),
    )

    let com = CommonRef.new(newCoreDbRef(LegacyDbMemory), config = chainConfigForNetwork(MainNet))

    let s = BaseVMState.new(
      header,
      header,
      com,
    )

    s.stateDB.setCode(codeAddress, @data)
    let unsignedTx = Transaction(
      txType: TxLegacy,
      nonce: 0,
      chainId: MainNet.ChainId,
      gasPrice: 0.GasInt,
      gasLimit: 30000000,
      to: codeAddress.some,
      value: 0.u256,
      payload: @data
    )

    let privateKey = PrivateKey.fromHex("0000000000000000000000000000000000000000000000000000001000000000")[]
    let tx = signTransaction(unsignedTx, privateKey, ChainId(1), false)
    let res = testCallEvm(tx, tx.getSender, s, FkHomestead)
    when defined(evmc_enabled):
      check res.error == "EVMC_FAILURE"
    else:
      check res.error == "Opcode Dispatch Error: GasInt overflow, gasCost=2199123918888, gasRefund=9223372036845099570, depth=1"

when isMainModule:
  overflowMain()
