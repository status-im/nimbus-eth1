import
  chronos,
  sequtils,
  times,
  stew/results,
  json_rpc/rpcclient,
  eth/[rlp, common, p2p],
  p2p/chain/[chain_desc, persist_blocks],
  p2p/executor/process_block,
  db/[db_chain, select_backend, storage_types, distinct_tries, incomplete_db, accounts_cache],
  eth/trie/[db, trie_defs],
  vm2/async/rpc_api,
  vm2/async/operations,
  vm2/async/data_sources/on_demand,
  vm2/async/data_sources/types,
  ./vm_state, ./vm_types,
  chronicles

from chain_config import MainNet, networkParams
from genesis import initializeEmptyDb

# Duplicating some code from nimbus.nim.
proc getChain*(dataDir: string,
               pruneTrie: bool = true,
               networkId: NetworkId = MainNet,
               params = networkParams(MainNet)): Chain =
  let dbBackend: ChainDB = newChainDB(dataDir)
  let db: TrieDatabaseRef = trieDB(dbBackend)
  var chainDB: BaseChainDB = newBaseChainDB(db, pruneTrie, networkId, params)
  chainDB.populateProgress()

  if canonicalHeadHashKey().toOpenArray notin db:
    initializeEmptyDb(chainDB)
    doAssert(canonicalHeadHashKey().toOpenArray in db)

  newChain(chainDB)


proc coinbasesOfThisBlockAndUncles(header: BlockHeader, body: BlockBody): seq[EthAddress] =
  result.add header.coinbase
  for uncle in body.uncles:
    result.add(uncle.coinbase)

proc createVmStateForStatelessMode*(chainDB: BaseChainDB, header: BlockHeader, body: BlockBody,
                                    parentHeader: BlockHeader, asyncFactory: AsyncOperationFactory): Result[BaseVMState, string]
                                   {.inline, raises: [Exception].} =
  let vmState = BaseVMState()
  if not vmState.statelessInit(header, chainDB, parentHeader, asyncFactory, {}, false):
    return err("Cannot initialise VmState for block number " & $(header.blockNumber))
  waitFor(ifNecessaryGetAccounts(vmState, coinbasesOfThisBlockAndUncles(header, body)))
  ok(vmState)


# FIXME-Adam: this code is just for debugging. Take it out once I've fixed my state-root problem.
proc debugAdamsBlockStateRootProblem(
  vmState: BaseVMState;
  header: BlockHeader;
  body: BlockBody): Future[void] {.async.} = 
    echo "========================================================="
    let blockNumber = header.blockNumber
    let stateRoot0 = vmState.parent.stateRoot
    let stateRoot1 = vmState.stateDB.rootHash
    let stateRoot2 = header.stateRoot
    warn "about to try to figure out why we got the wrong state root",
      blockNumber = blockNumber,
      parentRoot = stateRoot0,
      actualRoot = stateRoot1,
      expectedRoot = stateRoot2
    
    let db = vmState.chainDB.db
    let trie0 = initAccountsTrie(db, stateRoot0, false)
    let trie1 = initAccountsTrie(db, stateRoot1, false)
    let trie2 = initAccountsTrie(db, stateRoot2, false)
    
    echo "about to fetch the accounts for the correct new state root"
    # let addressesToCheck = vmState.touchedAccounts
    let addressesToCheck: seq[EthAddress] = map(@[
      "0xcb84d72e61e383767c4dfeb2d8ff7f4fb89abc6e",
      "0x5c6ee304399dbdb9c8ef030ab642b10820db8f56",
      "0xc944e90c64b2c07662a292be6244bdf05cda44a7",
      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      "0xdac17f958d2ee523a2206206994597c13d831ec7",
      "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce",
      "0x6b175474e89094c44da98b954eedeac495271d0f",
    ], parseAddress)
    for address in addressesToCheck:
      let acc1 = ifNodesExistGetAccount(trie1, address).get
      # This won't fetch new slots or untouched slots.
      # But I guess this is better than nothing.
      let slots = initStorageTrie(db, acc1.storageRoot).storageSlots
      echo "fetching " & $(address)
      await vmState.asyncFactory.lazyDataSource.ifNecessaryGetSlots(db, blockNumber, stateRoot2, address, slots, stateRoot2)
    echo "done fetching the accounts for the correct new state root"

    var differentSlotsByAddress: Table[EthAddress, HashSet[UInt256]]
    for address in vmState.touchedAccounts:
      let acc0 = ifNodesExistGetAccount(trie0, address).get
      let acc1 = ifNodesExistGetAccount(trie1, address).get
      let acc2 = ifNodesExistGetAccount(trie2, address).get

      let slots = initStorageTrie(db, acc1.storageRoot).storageSlots
      var differentSlots: HashSet[UInt256]
      for slot in slots:
        let maybeV1 = ifNodesExistGetStorageWithinAccount(storageTrieForAccount(trie1, acc1), slot)
        let maybeV2 = ifNodesExistGetStorageWithinAccount(storageTrieForAccount(trie2, acc2), slot)
        if maybeV1 == maybeV2:
          info("slots are the same", address=address, slot=slot, maybeV1=maybeV1, maybeV2=maybeV2)
          #discard
        else:
          error("found a difference in slot", address=address, slot=slot, maybeV1=maybeV1, maybeV2=maybeV2)
          differentSlots.incl(slot)
      differentSlotsByAddress[address] = differentSlots

      if acc1 == acc2:
        # error("accounts are the same", address=address, acc0=acc0, acc1=acc1, acc2=acc2)
        discard
      else:
        error("found a difference in the accounts", address=address, acc0=acc0, acc1=acc1, acc2=acc2)

proc statelesslyRunBlock*(rpcClient: RpcClient, chain: Chain, header: BlockHeader, body: BlockBody): Result[Hash256, string] =
  try:
    let t0 = now()
    
    # FIXME-Adam: this doesn't feel like the right place for this; where should it go?
    chain.db.db.put(emptyRlpHash.data, emptyRlp)
    
    let blockHash: Hash256 = header.blockHash

    let asyncFactory = AsyncOperationFactory(lazyDataSource: realLazyDataSource(rpcClient, false))

    let parentHeader = waitFor(fetchBlockHeaderWithHash(rpcClient, header.parentHash))
    chain.db.persistHeaderToDbWithoutSetHeadOrScore(parentHeader)

    info("statelessly running block", blockNumber=header.blockNumber, blockHash=blockHash)

    let vmState = createVmStateForStatelessMode(chain.db, header, body, parentHeader, asyncFactory).get
    let vres = processBlockNotPoA(vmState, header, body)
    
    let elapsedTime = now() - t0
    info("finished statelessly running the block", vres=vres, elapsedTime=elapsedTime, durationSpentDoingFetches=durationSpentDoingFetches, fetchCounter=fetchCounter)

    let headerStateRoot = header.stateRoot
    let vmStateRoot = rootHash(vmState.stateDB)
    warn("done processing block", headerStateRoot=headerStateRoot, vmStateRoot=vmStateRoot)
    if headerStateRoot != vmStateRoot:
      try:
        waitFor(debugAdamsBlockStateRootProblem(vmState, header, body))
      except:
        echo "error during debugAdamsBlockStateRootProblem: " & $(getCurrentExceptionMsg())
      return err("State roots do not match: header says " & $(headerStateRoot) & ", vmState says " & $(vmStateRoot))
    else:
      if vres == ValidationResult.OK:
        return ok(blockHash)
      else:
        return err("Error while statelessly running a block")
  except:
    let ex = getCurrentException()
    echo getStackTrace(ex)
    error "Got an exception while statelessly running a block", exMsg = ex.msg
    raise ex

proc statelesslyRunBlock*(dataSourceUrl: string, chain: Chain, header: BlockHeader, body: BlockBody): Result[Hash256, string] =
  let rpcClient = waitFor(makeAnRpcClient(dataSourceUrl))
  return statelesslyRunBlock(rpcClient, chain, header, body)

proc statelesslyRunBlock*(dataSourceUrl: string, chain: Chain, hashStr: string) =
  let rpcClient = waitFor(makeAnRpcClient(dataSourceUrl))
  let (header, body) = waitFor(fetchBlockHeaderAndBodyWithHash(rpcClient, hashStr.toHash))
  let r = statelesslyRunBlock(rpcClient, chain, header, body)
  if r.isErr:
    error("stateless execution failed", hash=hashStr, error=r.error)
  else:
    info("stateless execution succeeded", hash=hashStr, resultingHash=r.value)




proc statelesslyRunTransaction*(rpcClient: RpcClient, chain: Chain, headerHash: Hash256, tx: Transaction) =
  let t0 = now()
  
  let (header, body) = waitFor(fetchBlockHeaderAndBodyWithHash(rpcClient, headerHash))

  # FIXME-Adam: this doesn't feel like the right place for this; where should it go?
  chain.db.db.put(emptyRlpHash.data, emptyRlp)

  let blockHash: Hash256 = header.blockHash
  
  let transaction = chain.db.db.beginTransaction()
  defer: transaction.rollback()  # intentionally throwing away the result of this execution

  let asyncFactory = AsyncOperationFactory(lazyDataSource: realLazyDataSource(rpcClient, false))
  let parentHeader = waitFor(fetchBlockHeaderWithHash(rpcClient, header.parentHash))
  chain.db.persistHeaderToDbWithoutSetHeadOrScore(parentHeader)
  
  let vmState = createVmStateForStatelessMode(chain.db, header, body, parentHeader, asyncFactory).get

  let r = processTransactions(vmState, header, @[tx])
  if r.isErr:
    error("error statelessly running tx", tx=tx, error=r.error)
  else:
    let elapsedTime = now() - t0
    let gasUsed = vmState.cumulativeGasUsed
    info("finished statelessly running the tx", elapsedTime=elapsedTime, gasUsed=gasUsed)


# FIXME-Adam: I'm not sure whether these procs that take raw strings are useful;
# maybe just delete them. But the point that I'm expecting these to be called
# from "outside".
proc statelesslyRunTransaction*(dataSourceUrl: string, dataDir: string, headerHashStr: string, tx: Transaction) =
  let chain = getChain(dataDir)
  let rpcClient = waitFor(makeAnRpcClient(dataSourceUrl))
  statelesslyRunTransaction(rpcClient, chain, headerHashStr.toHash, tx)
