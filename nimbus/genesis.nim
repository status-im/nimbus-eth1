import
  std/tables,
  eth/[common, rlp, p2p],
  chronicles, eth/trie/[db, trie_defs],
  ./db/[db_chain, state_db],
  "."/[constants, chain_config, forks, p2p/gaslimit]

proc toBlock*(g: Genesis, db: BaseChainDB = nil):
    BlockHeader {.raises: [Defect, RlpError].} =
  let (tdb, pruneTrie) = if db.isNil: (newMemoryDB(), true)
                         else: (db.db, db.pruneTrie)

  # For `eth/trie/db.newMemoryDB()`, the following initialiation is part of
  # the constructor function which is missing for the permanent constructor
  # function `eth/trie/db.trieDB()`.
  if not db.isNil:
    tdb.put(emptyRlpHash.data, emptyRlp)

  var sdb = newAccountStateDB(tdb, emptyRlpHash, pruneTrie)

  for address, account in g.alloc:
    sdb.setAccount(address, newAccount(account.nonce, account.balance))
    sdb.setCode(address, account.code)

    # Kludge:
    #
    #   With the pruning persistent version, the initial/trivial key-value
    #   pair `(emptyRlpHash.data,emptyRlp)` will have been deleted after
    #   adding a non-trivial key-value pair in one of the above functions.
    #   This happens in the function/template
    #
    #      eth/trie/db.del() called by
    #      eth/trie/hexary.prune() invoked by
    #      eth/trie/hexary.origWithNewValue() invoked by
    #      eth/trie/hexary.mergeAt() called by
    #      eth/trie/hexary.put()
    #
    #   if the database contains the trivial key-value pair, only.
    #   Unfortunately, the *trie* is now empty but the previous root hash
    #   is re-used. This leads to an assert exception in any subsequent
    #   invocation of `eth/trie/hexary.put()`.
    #
    # See also https://github.com/status-im/nim-eth/issues/9 where other,
    # probably related debilities are discussed.
    #
    # This kludge also fixes the initial crash described in
    # https://github.com/status-im/nimbus-eth1/issues/932.
    if not db.isNil and db.pruneTrie:
      tdb.put(emptyRlpHash.data, emptyRlp) # <-- kludge

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
