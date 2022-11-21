import
  chronos,
  stint,
  json_rpc/rpcclient,
  eth/common/eth_types,
  eth/trie/db,
  ../../../db/db_chain,
  ../data_fetching,
  ./types

export AsyncOperationFactory, LazyDataSource


# Will be used in asynchronous on-demand-data-fetching mode, once
# that is implemented.
proc realLazyDataSource*(client: RpcClient, justChecking: bool): LazyDataSource =
  LazyDataSource(
    ifNecessaryGetAccount: (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, @[], false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetSlots:   (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, slots, false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetCode: (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetCode(client, db, blockNumber, stateRoot, address, justChecking, newStateRootForSanityChecking)
    ),
    ifNecessaryGetBlockHeader: (proc(chainDB: BaseChainDB, blockNumber: BlockNumber): Future[void] {.async.} =
      await ifNecessaryGetBlockHeader(client, chainDB, blockNumber, justChecking)
    )
  )
