# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # std/[tables, sets],
  chronos,
  # chronicles,
  stint,
  results,
  eth/common/[hashes, accounts, addresses, headers, transactions],
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/common/common,
  ../../execution_chain/db/ledger,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/[evm/types, evm/state, evm/evm_errors],
  ../network/history/history_network,
  ../network/state/[state_endpoints, state_network]

from eth/common/eth_types_rlp import rlpHash

export evmc, addresses, stint, headers, state_network

#{.push raises: [].}

type
  PortalEvm* = ref object
    historyNetwork: HistoryNetwork
    stateNetwork: StateNetwork

proc init*(T: type PortalEvm, hn: HistoryNetwork, sn: StateNetwork) =
  PortalEvm(historyNetwork: hn, stateNetwork: sn)

proc call*(evm: PortalEvm, tx: TransactionArgs, blockNumOrHash: uint64 | Hash32): EvmResult[CallResult] =
  let
    header = (waitFor evm.historyNetwork.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
      raise newException(ValueError, "Could not find header with requested block number")
    parent = (waitFor evm.historyNetwork.getVerifiedBlockHeader(header.parentHash)).valueOr:
      raise newException(ValueError, "Could not find header with requested block number")
    com = CommonRef.new(newCoreDbRef DefaultDbMemory, nil)
    fork = com.toEVMFork(header)
    vmState = BaseVMState()

  vmState.init(parent, header, com, com.db.baseTxFrame())

  vmState.mutateLedger:
    db.setBalance(default(Address), 0.u256())
    # for accessPair in accessList:
    #   let
    #     accountAddr = accessPair.address
    #     acc = await lcProxy.getAccount(accountAddr, quantityTag)
    #     accCode = await lcProxy.getCode(accountAddr, quantityTag)

    #   db.setNonce(accountAddr, acc.nonce)
    #   db.setBalance(accountAddr, acc.balance)
    #   db.setCode(accountAddr, accCode)

    #   for slot in accessPair.storageKeys:
    #     let slotInt = UInt256.fromHex(toHex(slot))
    #     let slotValue = await lcProxy.getStorageAt(accountAddr, slotInt, quantityTag)
    #     db.setStorage(accountAddr, slotInt, slotValue)
    db.persist(clearEmptyAccount = false) # settle accounts storage

  rpcCallEvm(tx, header, vmState)
