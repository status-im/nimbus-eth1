import
  options,
  chronos,
  stint,
  eth/common,
  eth/trie/db,
  ../../sync/protocol,
  ../../db/db_chain

type
  AsyncDataSource* = ref object of RootObj
    ifNecessaryGetSlots*:       proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetCode*:        proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetAccount*:     proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetBlockHeaderByNumber*: proc(chainDB: ChainDBRef, blockNumber: BlockNumber): Future[void] {.gcsafe.}
    fetchNodes*: proc(stateRoot: Hash256, paths: seq[SnapTriePaths], nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.gcsafe.}
    fetchBlockHeaderWithHash*: proc(h: Hash256): Future[BlockHeader] {.gcsafe.}
    fetchBlockHeaderWithNumber*: proc(n: BlockNumber): Future[BlockHeader] {.gcsafe.}
    fetchBlockHeaderAndBodyWithHash*: proc(h: Hash256): Future[(BlockHeader, BlockBody)] {.gcsafe.}
    fetchBlockHeaderAndBodyWithNumber*: proc(n: BlockNumber): Future[(BlockHeader, BlockBody)] {.gcsafe.}

  # FIXME-Adam: maybe rename this?
  AsyncOperationFactory* = ref object of RootObj
    maybeDataSource*: Option[AsyncDataSource]


# FIXME-Adam: Can I make a singleton?
proc asyncFactoryWithNoDataSource*(): AsyncOperationFactory =
  AsyncOperationFactory(maybeDataSource: none[AsyncDataSource]())


# FIXME-Adam: Ugly but straightforward; can this be cleaned up using some combination of:
#   - an ifSome/map operation on Options
#   - some kind of "what are we fetching" tuple, so that this is just one thing

proc ifNecessaryGetSlots*(asyncFactory: AsyncOperationFactory, db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  if asyncFactory.maybeDataSource.isSome:
    await asyncFactory.maybeDataSource.get.ifNecessaryGetSlots(db, blockNumber, stateRoot, address, slots, newStateRootForSanityChecking)

proc ifNecessaryGetCode*(asyncFactory: AsyncOperationFactory, db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  if asyncFactory.maybeDataSource.isSome:
    await asyncFactory.maybeDataSource.get.ifNecessaryGetCode(db, blockNumber, stateRoot, address, newStateRootForSanityChecking)

proc ifNecessaryGetAccount*(asyncFactory: AsyncOperationFactory, db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  if asyncFactory.maybeDataSource.isSome:
    await asyncFactory.maybeDataSource.get.ifNecessaryGetAccount(db, blockNumber, stateRoot, address, newStateRootForSanityChecking)

proc ifNecessaryGetBlockHeaderByNumber*(asyncFactory: AsyncOperationFactory, chainDB: ChainDBRef, blockNumber: BlockNumber): Future[void] {.async.} =
  if asyncFactory.maybeDataSource.isSome:
    await asyncFactory.maybeDataSource.get.ifNecessaryGetBlockHeaderByNumber(chainDB, blockNumber)
