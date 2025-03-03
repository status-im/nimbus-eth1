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
  ../network/state/[state_endpoints, state_network, state_content]

from eth/common/eth_types_rlp import rlpHash

export evmc, addresses, stint, headers, state_network

{.push raises: [].}

const evmCallLimit = 1024

type
  AccountQuery = object
    address: Address
    accFut: Future[Opt[Account]]

  StorageQuery = object
    address: Address
    slotKey: UInt256
    storageFut: Future[Opt[UInt256]]

  CodeQuery = object
    address: Address
    codeFut: Future[Opt[Bytecode]]

  PortalEvm* = ref object
    historyNetwork: HistoryNetwork
    stateNetwork: StateNetwork
    com: CommonRef

template init(T: type AccountQuery, adr: Address, fut: Future[Opt[Account]]): T =
  T(address: adr, accFut: fut)

template init(T: type StorageQuery, adr: Address, slotKey: UInt256, fut: Future[Opt[UInt256]]): T =
  T(address: adr, slotKey: slotKey, storageFut: fut)

template init(T: type CodeQuery, adr: Address, fut: Future[Opt[Bytecode]]): T =
  T(address: adr, codeFut: fut)

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

func equals(mkeys1: MultiKeysRef, mkeys2: MultiKeysRef): bool =
  doAssert(not mkeys1.isNil())
  doAssert(not mkeys2.isNil())

  let
    keys1 = mkeys1.keys
    keys2 = mkeys2.keys

  if keys1.len() != keys2.len():
    return false

  for i in 0..keys1.high:
    let
      k1 = keys1[i]
      k2 = keys2[i]

    if k1.hash != k2.hash or k1.address != k2.address or k1.codeTouched != k2.codeTouched:
      return false

    if k1.storageKeys.isNil() or k2.storageKeys.isNil():
      if k1.storageKeys != k2.storageKeys:
        return false
    else:
      if k1.storageKeys.keys.len() != k2.storageKeys.keys.len():
        return false

      for j in 0..k1.storageKeys.keys.high:
        if k1.storageKeys.keys[j].storageSlot != k2.storageKeys.keys[j].storageSlot:
          return false

  return true

proc call*(
    evm: PortalEvm, tx: TransactionArgs, blockNumOrHash: uint64 | Hash32
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError, CatchableError]).} =
  let
    to = tx.to.valueOr:
      return err("to address is required")
    header = (await evm.historyNetwork.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
      return err("Unable to get block header")
    # Fetch account and code concurrently
    accFut = evm.stateNetwork.getAccount(header.stateRoot, to)
    codeFut = evm.stateNetwork.getCodeByStateRoot(header.stateRoot, to)

  let txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  # TODO: review what child header to use here (second parameter)
  let vmState = BaseVMState.new(header, header, evm.com, txFrame)

  let acc = (await accFut).valueOr:
    return err("Unable to get account")
  vmState.ledger.setBalance(to, acc.balance)
  vmState.ledger.setNonce(to, acc.nonce)

  let code = (await codeFut).valueOr:
    return err("Unable to get code")
  vmState.ledger.setCode(to, code.asSeq())

  vmState.ledger.collectWitnessData()

  var
    lastMultiKeys = new MultiKeysRef
    multiKeys = vmState.ledger.makeMultiKeys()
    callResult: EvmResult[CallResult]
    evmCallCount = 0

  while evmCallCount < evmCallLimit and not lastMultiKeys.equals(multiKeys):
    let sp = vmState.ledger.beginSavepoint()
    callResult = rpcCallEvm(tx, header, vmState)
    inc evmCallCount
    vmState.ledger.rollback(sp)

    lastMultiKeys = multiKeys
    vmState.ledger.collectWitnessData()
    multiKeys = vmState.ledger.makeMultiKeys()


    var
      accountQueries = newSeq[AccountQuery]()
      storageQueries = newSeq[StorageQuery]()
      codeQueries = newSeq[CodeQuery]()

    for k in multiKeys.keys:
      if not k.storageMode and k.address != default(Address):
        let accFut = evm.stateNetwork.getAccount(header.stateRoot, k.address)
        accountQueries.add(AccountQuery.init(k.address, accFut))

        if k.codeTouched:
          let codeFut = evm.stateNetwork.getCodeByStateRoot(header.stateRoot, k.address)
          codeQueries.add(CodeQuery.init(k.address, codeFut))

        if not k.storageKeys.isNil():
          for sk in k.storageKeys.keys:
            let
              slotKey = UInt256.fromBytesBE(sk.storageSlot)
              storageFut = evm.stateNetwork.getStorageAtByStateRoot(header.stateRoot, k.address, slotKey)
            storageQueries.add(StorageQuery.init(k.address, slotKey, storageFut))

    for q in accountQueries:
      let acc = (await q.accFut).valueOr:
        return err("Unable to get account")
      vmState.ledger.setBalance(q.address, acc.balance)
      vmState.ledger.setNonce(q.address, acc.nonce)

    for q in storageQueries:
      let slotValue = (await q.storageFut).valueOr:
        return err("Unable to get slot")
      vmState.ledger.setStorage(q.address, q.slotKey, slotValue)

    for q in codeQueries:
      let code = (await q.codeFut).valueOr:
        return err("Unable to get code")
      vmState.ledger.setCode(q.address, code.asSeq())

  callResult.mapErr(
    proc(e: EvmErrorObj): string =
      "EVM execution failed: " & $e.code
  )
