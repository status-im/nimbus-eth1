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

#{.push raises: [].}

type PortalEvm* = ref object
  historyNetwork: HistoryNetwork
  stateNetwork: StateNetwork

proc init*(T: type PortalEvm, hn: HistoryNetwork, sn: StateNetwork): T =
  PortalEvm(historyNetwork: hn, stateNetwork: sn)

proc call*(
    evm: PortalEvm, tx: TransactionArgs, blockNumOrHash: uint64 | Hash32
): Future[EvmResult[CallResult]] {.async.} = #{.async: (raises: [CancelledError, ValueError]).} =

  let
    to = tx.to.valueOr:
      raise newException(ValueError, "to address missing in transaction")
    header = (await evm.historyNetwork.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
      raise
        newException(ValueError, "Could not find header with requested block number")
    # do we need to get the parent?
    parent = (await evm.historyNetwork.getVerifiedBlockHeader(header.parentHash)).valueOr:
      raise
        newException(ValueError, "Could not find parent header with requested block number")
    # update the get account call
    acc = (await evm.stateNetwork.getAccount(header.stateRoot, to, Opt.none(Hash32))).valueOr:
      raise
        newException(ValueError, "Unable to get account")
    code = (await evm.stateNetwork.getCodeByStateRoot(header.stateRoot, to)).valueOr:
      raise
        newException(ValueError, "Unable to get code")

    # slot1Key = UInt256.fromBytesBE(hexToSeqByte("0x0000000000000000000000000000000000000000000000000000000000000000"))
    # slot2Key = UInt256.fromBytesBE(hexToSeqByte("0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e572"))
    # slot3Key = UInt256.fromBytesBE(hexToSeqByte("0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e574"))
    # slot4Key = UInt256.fromBytesBE(hexToSeqByte("0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e573"))
    # slot5Key = UInt256.fromBytesBE(hexToSeqByte("0xff48e101e1045535d929d495692c383c0f1b7e861d5176a028cb8373d1179af2"))

    # slot1 = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, to, slot1Key)).valueOr:
    #   raise newException(ValueError, "Unable to get slot1")
    # slot2 = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, to, slot2Key)).valueOr:
    #   raise newException(ValueError, "Unable to get slot2")
    # slot3 = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, to, slot3Key)).valueOr:
    #   raise newException(ValueError, "Unable to get slot3")
    # slot4 = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, to, slot4Key)).valueOr:
    #   raise newException(ValueError, "Unable to get slot4")
    # slot5 = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, to, slot5Key)).valueOr:
    #   raise newException(ValueError, "Unable to get slot5")

    com = CommonRef.new(newCoreDbRef DefaultDbMemory, nil)
    # fork = com.toEVMFork(header)
    vmState = BaseVMState()

  vmState.init(parent, header, com, com.db.baseTxFrame())

  vmState.ledger.setBalance(to, acc.balance)
  vmState.ledger.setNonce(to, acc.nonce)
  vmState.ledger.setCode(to, code.asSeq())
  # vmState.ledger.setStorage(to, slot1Key, slot1)
  # vmState.ledger.setStorage(to, slot2Key, slot2)
  # vmState.ledger.setStorage(to, slot3Key, slot3)
  # vmState.ledger.setStorage(to, slot4Key, slot4)
  # vmState.ledger.setStorage(to, slot5Key, slot5)
  vmState.ledger.persist(clearEmptyAccount = false)

  var
    lastMultiKeysCount = -1
    multiKeys = vmState.ledger.makeMultiKeys()
    callResult: EvmResult[CallResult]
    i = 0
  while i < 10: #multiKeys.keys.len() > lastMultiKeysCount:
    inc i

    lastMultiKeysCount = multiKeys.keys.len()

    callResult = rpcCallEvm(tx, header, vmState)
    echo "callResult: ", callResult

    vmState.ledger.collectWitnessData()
    multiKeys = vmState.ledger.makeMultiKeys()

    for k in multiKeys.keys:
      echo "k.storageMode: ", k.storageMode
      echo "k.address: ", k.address
      echo "k.codeTouched: ", k.codeTouched

      if not k.storageMode and k.address != default(Address):
        let account = (await evm.stateNetwork.getAccount(header.stateRoot, k.address, Opt.none(Hash32))).valueOr:
          raise newException(ValueError, "Unable to get account")
        vmState.ledger.setBalance(k.address, account.balance)
        vmState.ledger.setNonce(k.address, account.nonce)

        if k.codeTouched:
          let code = (await evm.stateNetwork.getCodeByStateRoot(header.stateRoot, k.address)).valueOr:
            raise newException(ValueError, "Unable to get code")
          vmState.ledger.setCode(k.address, code.asSeq())

        if not k.storageKeys.isNil():
          for sk in k.storageKeys.keys:
            let slotKey = UInt256.fromBytesBE(sk.storageSlot)
            echo "sk.storageSlot: ", slotKey
            let slotValue = (await evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, k.address, slotKey)).valueOr:
              raise newException(ValueError, "Unable to get slot")
            vmState.ledger.setStorage(k.address, slotKey, slotValue)

    vmState.ledger.persist(clearEmptyAccount = false)

  return callResult
