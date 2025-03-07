# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sets,
  stew/byteutils,
  chronos,
  chronicles,
  stint,
  results,
  eth/common/[hashes, addresses, accounts, headers],
  ../../execution_chain/db/ledger,
  ../../execution_chain/common/common,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/evm/[types, state, evm_errors],
  ../network/history/history_network,
  ../network/state/[state_endpoints, state_network]

from web3/eth_api_types import TransactionArgs

export
  results, chronos, hashes, history_network, state_network, TransactionArgs, CallResult

logScope:
  topics = "portal_evm"

# The Portal EVM uses the Nimbus in-memory EVM to execute transactions using the
# portal state network state data. Currently only call is supported.
#
# Rather than wire in the portal state lookups into the EVM directly, the approach
# taken here is to optimistically execute the transaction multiple times with the
# goal of building the correct access list so that we can then lookup the accessed
# state from the portal network, store the state in the in-memory EVM and then
# finally execute the transaction using the correct state. The Portal EVM makes
# use of data in memory during the call and therefore each piece of state is never
# fetched more than once. We know we have found the correct access list if it
# doesn't change after another execution of the transaction.
#
# The assumption here is that network lookups for state data are generally much
# slower than the time it takes to execute a transaction in the EVM and therefore
# executing the transaction multiple times should not significally slow down the
# call given that we gain the ability to fetch the state concurrently.
#
# There are multiple reasons for choosing this approach:
# - Firstly updating the existing Nimbus EVM to support using a different state
#   backend (portal state in this case) is difficult and would require making
#   non-trivial changes to the EVM.
# - This new approach allows us to look up the state concurrently in the event that
#   multiple new state keys are discovered after executing the transaction. This
#   should in theory result in improved performance for certain scenarios. The
#   default approach where the state lookups are wired directly into the EVM gives
#   the worst case performance because all state accesses inside the EVM are
#   completely sequential.

# Limit the max number of calls to prevent infinite loops and/or DOS in the event
# of a bug in the implementation
const EVM_CALL_LIMIT = 10000

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

func init(T: type AccountQuery, adr: Address, fut: Future[Opt[Account]]): T =
  T(address: adr, accFut: fut)

func init(
    T: type StorageQuery, adr: Address, slotKey: UInt256, fut: Future[Opt[UInt256]]
): T =
  T(address: adr, slotKey: slotKey, storageFut: fut)

func init(T: type CodeQuery, adr: Address, fut: Future[Opt[Bytecode]]): T =
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

proc call*(
    evm: PortalEvm, tx: TransactionArgs, blockNumOrHash: uint64 | Hash32
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError]).} =
  let
    to = tx.to.valueOr:
      return err("to address is required")
    header = (await evm.historyNetwork.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
      return err("Unable to get block header")
    # Start fetching code in the background while setting up the EVM
    codeFut = evm.stateNetwork.getCodeByStateRoot(header.stateRoot, to)

  debug "Executing call", to, blockNumOrHash

  let txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  # TODO: review what child header to use here (second parameter)
  let vmState = BaseVMState.new(header, header, evm.com, txFrame)

  # Set code of the 'to' address in the EVM so that we can execute the transaction
  let code = (await codeFut).valueOr:
    return err("Unable to get code")
  vmState.ledger.setCode(to, code.asSeq())
  debug "Code to be executed", code = code.asSeq().to0xHex()

  # Collects the keys of read or modified accounts, code and storage slots
  vmState.ledger.collectWitnessData()

  var
    lastMultiKeys = new MultiKeysRef
    multiKeys = vmState.ledger.makeMultiKeys()
    callResult: EvmResult[CallResult]
    evmCallCount = 0
    # Record the keys of fetched accounts, storage and code so that we don't
    # bother to fetch them multiple times
    fetchedAccounts = initHashSet[Address]()
    fetchedStorage = initHashSet[(Address, UInt256)]()
    fetchedCode = initHashSet[Address]()

  # If the multikeys did not change after the last execution then we can stop
  # because we have already executed the transaction with the correct state
  while evmCallCount < EVM_CALL_LIMIT and not lastMultiKeys.equals(multiKeys):
    debug "Starting PortalEvm execution", evmCallCount

    let sp = vmState.ledger.beginSavepoint()
    callResult = rpcCallEvm(tx, header, vmState)
    inc evmCallCount
    vmState.ledger.rollback(sp) # all state changes from the call are reverted

    # Collect the keys after executing the transaction
    lastMultiKeys = multiKeys
    vmState.ledger.collectWitnessData()
    multiKeys = vmState.ledger.makeMultiKeys()

    try:
      var
        accountQueries = newSeq[AccountQuery]()
        storageQueries = newSeq[StorageQuery]()
        codeQueries = newSeq[CodeQuery]()

      # Loop through the collected keys and fetch all state concurrently
      for k in multiKeys.keys:
        if not k.storageMode and k.address != default(Address):
          if k.address notin fetchedAccounts:
            debug "Fetching account", address = k.address
            let accFut = evm.stateNetwork.getAccount(header.stateRoot, k.address)
            accountQueries.add(AccountQuery.init(k.address, accFut))

          if k.codeTouched and k.address notin fetchedCode:
            debug "Fetching code", address = k.address
            let codeFut =
              evm.stateNetwork.getCodeByStateRoot(header.stateRoot, k.address)
            codeQueries.add(CodeQuery.init(k.address, codeFut))

          if not k.storageKeys.isNil():
            for sk in k.storageKeys.keys:
              let
                slotKey = UInt256.fromBytesBE(sk.storageSlot)
                slotIdx = (k.address, slotKey)
              if slotIdx notin fetchedStorage:
                debug "Fetching storage slot", address = k.address, slotKey
                let storageFut = evm.stateNetwork.getStorageAtByStateRoot(
                  header.stateRoot, k.address, slotKey
                )
                storageQueries.add(StorageQuery.init(k.address, slotKey, storageFut))

      # Store fetched state in the in-memory EVM
      for q in accountQueries:
        let acc = (await q.accFut).valueOr:
          return err("Unable to get account")
        vmState.ledger.setBalance(q.address, acc.balance)
        vmState.ledger.setNonce(q.address, acc.nonce)
        fetchedAccounts.incl(q.address)

      for q in storageQueries:
        let slotValue = (await q.storageFut).valueOr:
          return err("Unable to get slot")
        vmState.ledger.setStorage(q.address, q.slotKey, slotValue)
        fetchedStorage.incl((q.address, q.slotKey))

      for q in codeQueries:
        let code = (await q.codeFut).valueOr:
          return err("Unable to get code")
        vmState.ledger.setCode(q.address, code.asSeq())
        fetchedCode.incl(q.address)
    except CatchableError as e:
      # TODO: why do the above futures throw a CatchableError and not CancelledError?
      raiseAssert(e.msg)

  callResult.mapErr(
    proc(e: EvmErrorObj): string =
      "EVM execution failed: " & $e.code
  )
