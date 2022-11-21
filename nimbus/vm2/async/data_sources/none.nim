import
  chronos,
  stint,
  eth/trie/db,
  eth/common/eth_types,
  ../../../db/db_chain,
  ./types

export AsyncOperationFactory, LazyDataSource

# Used in synchronous mode.
proc noLazyDataSource*(): LazyDataSource =
  LazyDataSource(
    ifNecessaryGetSlots:       (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.async.} = discard),
    ifNecessaryGetCode:        (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} = discard),
    ifNecessaryGetAccount:     (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} = discard),
    ifNecessaryGetBlockHeader: (proc(chainDB: BaseChainDB, blockNumber: BlockNumber): Future[void] {.async.} = discard)
  )
