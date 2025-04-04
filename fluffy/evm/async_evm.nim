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
  ../../execution_chain/evm/[types, state, evm_errors]

from web3/eth_api_types import TransactionArgs

export
  results, chronos, hashes, addresses, accounts, headers, TransactionArgs, CallResult

logScope:
  topics = "async_evm"

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
#
# Note: The BLOCKHASH opt code is not yet supported by this implementation and so
# transactions which use this opt code will simply get the empty/default hash
# for any requested block. After the Pectra hard fork this opt code will be
# implemented using a system contract with the data stored in the Ethereum state
# trie/s and at that point it should just work without changes to the async evm here.

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
    codeFut: Future[Opt[seq[byte]]]

  GetAccountProc* = proc(stateRoot: Hash32, address: Address): Future[Opt[Account]] {.
    async: (raises: [CancelledError])
  .}

  GetStorageProc* = proc(
    stateRoot: Hash32, address: Address, slotKey: UInt256
  ): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).}

  GetCodeProc* = proc(stateRoot: Hash32, address: Address): Future[Opt[seq[byte]]] {.
    async: (raises: [CancelledError])
  .}

  AsyncEvmStateBackend* = object
    getAccount: GetAccountProc
    getStorage: GetStorageProc
    getCode: GetCodeProc

  AsyncEvm* = ref object
    com: CommonRef
    backend: AsyncEvmStateBackend

func init(T: type AccountQuery, adr: Address, fut: Future[Opt[Account]]): T =
  T(address: adr, accFut: fut)

func init(
    T: type StorageQuery, adr: Address, slotKey: UInt256, fut: Future[Opt[UInt256]]
): T =
  T(address: adr, slotKey: slotKey, storageFut: fut)

func init(T: type CodeQuery, adr: Address, fut: Future[Opt[seq[byte]]]): T =
  T(address: adr, codeFut: fut)

proc init*(
    T: type AsyncEvmStateBackend,
    accProc: GetAccountProc,
    storageProc: GetStorageProc,
    codeProc: GetCodeProc,
): T =
  AsyncEvmStateBackend(getAccount: accProc, getStorage: storageProc, getCode: codeProc)

proc init*(
    T: type AsyncEvm, backend: AsyncEvmStateBackend, networkId: NetworkId = MainNet
): T =
  let com = CommonRef.new(
    DefaultDbMemory.newCoreDbRef(),
    taskpool = nil,
    config = chainConfigForNetwork(networkId),
    initializeDb = false,
  )

  AsyncEvm(com: com, backend: backend)

proc call*(
    evm: AsyncEvm, header: Header, tx: TransactionArgs, optimisticStateFetch = true
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError]).} =
  let
    to = tx.to.valueOr:
      return err("to address is required")

    # Start fetching code in the background while setting up the EVM
    codeFut = evm.backend.getCode(header.stateRoot, to)

  debug "Executing call", blockNumber = header.number, to

  let txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  let blockContext = BlockContext(
    timestamp: EthTime.now(),
    gasLimit: header.gasLimit,
    baseFeePerGas: header.baseFeePerGas,
    prevRandao: header.prevRandao,
    difficulty: header.difficulty,
    coinbase: header.coinbase,
    excessBlobGas: header.excessBlobGas.get(0'u64),
    parentHash: header.blockHash(),
  )
  let vmState = BaseVMState.new(header, blockContext, evm.com, txFrame)

  var
    # Record the keys of fetched accounts, storage and code so that we don't
    # bother to fetch them multiple times
    fetchedAccounts = initHashSet[Address]()
    fetchedStorage = initHashSet[(Address, UInt256)]()
    fetchedCode = initHashSet[Address]()

  # Set code of the 'to' address in the EVM so that we can execute the transaction
  let code = (await codeFut).valueOr:
    return err("Unable to get code")
  vmState.ledger.setCode(to, code)
  fetchedCode.incl(to)
  debug "Code to be executed", code = code.to0xHex()

  var
    lastWitnessKeys: WitnessTable
    witnessKeys = vmState.ledger.getWitnessKeys()
    callResult: EvmResult[CallResult]
    evmCallCount = 0

  # Limit the max number of calls to prevent infinite loops and/or DOS in the
  # event of a bug in the implementation.
  while evmCallCount < EVM_CALL_LIMIT:
    debug "Starting AsyncEvm execution", evmCallCount

    let sp = vmState.ledger.beginSavepoint()
    callResult = rpcCallEvm(tx, header, vmState)
    inc evmCallCount
    vmState.ledger.rollback(sp) # all state changes from the call are reverted

    # Collect the keys after executing the transaction
    lastWitnessKeys = ensureMove(witnessKeys)
    witnessKeys = vmState.ledger.getWitnessKeys()
    vmState.ledger.clearWitnessKeys()

    try:
      var
        accountQueries = newSeq[AccountQuery]()
        storageQueries = newSeq[StorageQuery]()
        codeQueries = newSeq[CodeQuery]()

      # Loop through the collected keys and fetch the state concurrently.
      # If optimisticStateFetch is enabled then we fetch state for all the witness
      # keys and await all queries before continuing to the next call.
      # If optimisticStateFetch is disabled then we only fetch and then await on
      # one piece of state (the next in the ordered witness keys) while the remaining
      # state queries are still issued in the background just incase the state is
      # needed in the next iteration.
      var stateFetchDone = false
      for k, v in witnessKeys:
        let (adr, _) = k

        if v.storageMode:
          let slotIdx = (adr, v.storageSlot)
          if slotIdx notin fetchedStorage:
            debug "Fetching storage slot", address = adr, slotKey = v.storageSlot
            let storageFut =
              evm.backend.getStorage(header.stateRoot, adr, v.storageSlot)
            if not stateFetchDone:
              storageQueries.add(StorageQuery.init(adr, v.storageSlot, storageFut))
              if not optimisticStateFetch:
                stateFetchDone = true
        elif adr != default(Address):
          doAssert(adr == v.address)

          if adr notin fetchedAccounts:
            debug "Fetching account", address = adr
            let accFut = evm.backend.getAccount(header.stateRoot, adr)
            if not stateFetchDone:
              accountQueries.add(AccountQuery.init(adr, accFut))
              if not optimisticStateFetch:
                stateFetchDone = true

          if v.codeTouched and adr notin fetchedCode:
            debug "Fetching code", address = adr
            let codeFut = evm.backend.getCode(header.stateRoot, adr)
            if not stateFetchDone:
              codeQueries.add(CodeQuery.init(adr, codeFut))
              if not optimisticStateFetch:
                stateFetchDone = true

      if optimisticStateFetch:
        # If the witness keys did not change after the last execution then we can
        # stop the execution loop because we have already executed the transaction
        # with the correct state.
        if lastWitnessKeys == witnessKeys:
          break
      else:
        # When optimisticStateFetch is disabled and stateFetchDone is not set then
        # we know that all the state has already been fetched in the last iteration
        # of the loop and therefore we have already executed the transaction with
        # the correct state.
        if not stateFetchDone:
          break

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
        vmState.ledger.setCode(q.address, code)
        fetchedCode.incl(q.address)
    except CatchableError as e:
      # TODO: why do the above futures throw a CatchableError and not CancelledError?
      raiseAssert(e.msg)

  callResult.mapErr(
    proc(e: EvmErrorObj): string =
      "EVM execution failed: " & $e.code
  )
