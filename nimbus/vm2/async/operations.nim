import
  chronos,
  stint,
  eth/common,
  ../../db/distinct_tries,
  ../../db/accounts_cache,
  ../types



proc ifNecessaryGetAccount*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  await vmState.asyncFactory.lazyDataSource.ifNecessaryGetAccount(vmState.chainDB.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetCode*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  await vmState.asyncFactory.lazyDataSource.ifNecessaryGetCode(vmState.chainDB.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetSlots*(vmState: BaseVMState, address: EthAddress, slots: seq[UInt256]): Future[void] {.async.} =
  await vmState.asyncFactory.lazyDataSource.ifNecessaryGetSlots(vmState.chainDB.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, slots, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetSlot*(vmState: BaseVMState, address: EthAddress, slot: UInt256): Future[void] {.async.} =
  await ifNecessaryGetSlots(vmState, address, @[slot])

proc ifNecessaryGetBlockHeader*(vmState: BaseVMState, blockNumber: BlockNumber): Future[void] {.async.} =
  await vmState.asyncFactory.lazyDataSource.ifNecessaryGetBlockHeader(vmState.chainDB, blockNumber)


# Sometimes it's convenient to be able to do multiple at once.

proc ifNecessaryGetAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  for address in addresses:
    await ifNecessaryGetAccount(vmState, address)

proc ifNecessaryGetCodeForAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  for address in addresses:
    await ifNecessaryGetCode(vmState, address)
