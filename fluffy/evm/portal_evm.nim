# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # std/[tables, sets],
  chronos,
  # taskpools,
  # chronicles,
  stew/byteutils,
  stint,
  results,
  eth/common/[hashes, accounts, addresses, headers, transactions],
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/db/ledger,
  ../../execution_chain/common/common,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/evm/[types, state, evm_errors],
  ../network/history/history_network,
  ../network/state/[state_endpoints, state_network]

from eth/common/eth_types_rlp import rlpHash

export evmc, addresses, stint, headers, state_network

{.push raises: [].}

type PortalEvm* = ref object
  historyNetwork: HistoryNetwork
  stateNetwork: StateNetwork
  com: CommonRef

proc init*(T: type PortalEvm, hn: HistoryNetwork, sn: StateNetwork): T =
  let config =
    try:
      networkParams(MainNet).config
    except ValueError as e:
      raiseAssert(e.msg) # Should not fail
    except RlpError as e:
      raiseAssert(e.msg) # Should not fail

  let com = CommonRef.new(
    DefaultDbMemory.newCoreDbRef(),
    taskpool = nil,
    config = config,
    initializeDb = false,
  )

  PortalEvm(historyNetwork: hn, stateNetwork: sn, com: com)

proc call*(
    evm: PortalEvm, tx: TransactionArgs, blockNumOrHash: uint64 | Hash32
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError]).} =
  let
    to = tx.to.valueOr:
      return err("to address is required")
    header = (await evm.historyNetwork.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
      return err("Unable to get block header")
    acc = (await evm.stateNetwork.getAccount(header.stateRoot, to)).valueOr:
      return err("Unable to get account")
    code = (await evm.stateNetwork.getCodeByStateRoot(header.stateRoot, to)).valueOr:
      return err("Unable to get code")

  let txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  # TODO: review what child header to use here (second parameter)
  let vmState = BaseVMState.new(header, header, evm.com, txFrame)
  vmState.ledger.setBalance(to, acc.balance)
  vmState.ledger.setNonce(to, acc.nonce)
  vmState.ledger.setCode(to, code.asSeq())

  var
    lastMultiKeysCount = -1
    multiKeys = vmState.ledger.makeMultiKeys()
    callResult: EvmResult[CallResult]
    i = 0
  while i < 10: #multiKeys.keys.len() > lastMultiKeysCount:
    inc i
    lastMultiKeysCount = multiKeys.keys.len()

    callResult = rpcCallEvm(tx, header, vmState)

    vmState.ledger.collectWitnessData()
    multiKeys = vmState.ledger.makeMultiKeys()

    for k in multiKeys.keys:
      if not k.storageMode and k.address != default(Address):
        let account = (
          await evm.stateNetwork.getAccount(
            header.stateRoot, k.address, Opt.none(Hash32)
          )
        ).valueOr:
          return err("Unable to get account")
        vmState.ledger.setBalance(k.address, account.balance)
        vmState.ledger.setNonce(k.address, account.nonce)

        if k.codeTouched:
          let code = (
            await evm.stateNetwork.getCodeByStateRoot(header.stateRoot, k.address)
          ).valueOr:
            return err("Unable to get code")
          vmState.ledger.setCode(k.address, code.asSeq())

        if not k.storageKeys.isNil():
          for sk in k.storageKeys.keys:
            let slotKey = UInt256.fromBytesBE(sk.storageSlot)
            let slotValue = (
              await evm.stateNetwork.getStorageAtByStateRoot(
                header.stateRoot, k.address, slotKey
              )
            ).valueOr:
              return err("Unable to get slot")
            vmState.ledger.setStorage(k.address, slotKey, slotValue)

  callResult.mapErr(
    proc(e: EvmErrorObj): string =
      "EVM execution failed: " & $e.code
  )
