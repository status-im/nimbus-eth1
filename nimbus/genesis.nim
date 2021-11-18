import
  std/tables,
  eth/[common, rlp, trie, p2p],
  chronicles, eth/trie/[db, trie_defs],
  ./db/[db_chain, state_db],
  "."/[constants, chain_config, forks, p2p/gaslimit]

proc toBlock*(g: Genesis, db: BaseChainDB = nil):
    BlockHeader {.raises: [Defect, RlpError].} =
  let (tdb, pruneTrie) = if db.isNil: (newMemoryDB(), true)
                         else: (db.db, db.pruneTrie)
  tdb.put(emptyRlpHash.data, emptyRlp)
  var sdb = newAccountStateDB(tdb, emptyRlpHash, pruneTrie)

  for address, account in g.alloc:
    sdb.setAccount(address, newAccount(account.nonce, account.balance))
    sdb.setCode(address, account.code)
    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixDigest: g.mixhash,
    coinbase: g.coinbase,
    stateRoot: sdb.rootHash,
    parentHash: GENESIS_PARENT_HASH,
    txRoot: BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH,
    ommersHash: EMPTY_UNCLE_HASH
  )

  if g.baseFeePerGas.isSome:
    result.baseFee = g.baseFeePerGas.get()
  elif db.isNil.not and db.config.toFork(0.toBlockNumber) >= FkLondon:
    result.baseFee = EIP1559_INITIAL_BASE_FEE.u256

  if g.gasLimit.isZero:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty.isZero:
    result.difficulty = GENESIS_DIFFICULTY

proc initializeEmptyDb*(db: BaseChainDB) =
  trace "Writing genesis to DB"
  let b = db.genesis.toBlock(db)
  doAssert(b.blockNumber.isZero, "can't commit genesis block with number > 0")
  discard db.persistHeaderToDb(b)
