import
  chronicles,
  chronos,
  sequtils,
  stint,
  eth/common/eth_types,
  ../../common,
  ../../db/distinct_tries,
  ../../db/accounts_cache,
  ../../db/incomplete_db,
  ../../sync/protocol,
  ../types,
  ./data_sources



proc ifNecessaryGetAccount*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  await vmState.asyncFactory.ifNecessaryGetAccount(vmState.com.db.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetCode*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  await vmState.asyncFactory.ifNecessaryGetCode(vmState.com.db.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetSlots*(vmState: BaseVMState, address: EthAddress, slots: seq[UInt256]): Future[void] {.async.} =
  await vmState.asyncFactory.ifNecessaryGetSlots(vmState.com.db.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, slots, vmState.stateDB.rawTrie.rootHash)

proc ifNecessaryGetSlot*(vmState: BaseVMState, address: EthAddress, slot: UInt256): Future[void] {.async.} =
  await ifNecessaryGetSlots(vmState, address, @[slot])

proc ifNecessaryGetBlockHeaderByNumber*(vmState: BaseVMState, blockNumber: BlockNumber): Future[void] {.async.} =
  await vmState.asyncFactory.ifNecessaryGetBlockHeaderByNumber(vmState.com.db, blockNumber)

proc snapTriePathFromByteSeqs(byteSeqs: seq[seq[byte]]): SnapTriePaths =
  SnapTriePaths(
    accPath: byteSeqs[0],
    slotPaths: byteSeqs[1 ..< byteSeqs.len]
  )

proc fetchAndPopulateNodes*(vmState: BaseVMState, pathByteSeqs: seq[seq[seq[byte]]], nodeHashes: seq[Hash256]): Future[void] {.async.} =
  if vmState.asyncFactory.maybeDataSource.isSome:
    # let stateRoot = vmState.stateDB.rawTrie.rootHash # FIXME-Adam: this might not be right, huh? the peer might expect the parent block's final stateRoot, not this weirdo intermediate one
    let stateRoot = vmState.parent.stateRoot
    let paths = pathByteSeqs.map(snapTriePathFromByteSeqs)
    let nodes = await vmState.asyncFactory.maybeDataSource.get.fetchNodes(stateRoot, paths, nodeHashes)
    populateDbWithNodes(vmState.stateDB.rawDb, nodes)


# Sometimes it's convenient to be able to do multiple at once.

proc ifNecessaryGetAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  for address in addresses:
    await ifNecessaryGetAccount(vmState, address)

proc ifNecessaryGetCodeForAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  for address in addresses:
    await ifNecessaryGetCode(vmState, address)
