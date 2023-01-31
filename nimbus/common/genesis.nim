import
  std/tables,
  eth/[common, rlp, eip1559],
  eth/trie/[db, trie_defs],
  ../db/state_db,
  ../constants,
  ./chain_config

{.push raises: [].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------
proc newStateDB*(
    db: TrieDatabaseRef;
    pruneTrie: bool;
      ): AccountStateDB
      {.gcsafe, raises: [].}=
  newAccountStateDB(db, emptyRlpHash, pruneTrie)

proc toGenesisHeader*(
    g: Genesis;
    sdb: AccountStateDB;
    fork: HardFork;
      ): BlockHeader
      {.gcsafe, raises: [RlpError].} =
  ## Initialise block chain DB accounts derived from the `genesis.alloc` table
  ## of the `db` descriptor argument.
  ##
  ## The function returns the `Genesis` block header.
  ##

  # For `eth/trie/db.newMemoryDB()`, the following initialisation is part of
  # the constructor function which is missing for the permanent constructor
  # function `eth/trie/db.trieDB()`.
  sdb.db.put(emptyRlpHash.data, emptyRlp)

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
    if sdb.pruneTrie and 0 < account.storage.len:
      sdb.db.put(emptyRlpHash.data, emptyRlp) # <-- kludge

    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixDigest: g.mixHash,
    coinbase: g.coinbase,
    stateRoot: sdb.rootHash,
    parentHash: GENESIS_PARENT_HASH,
    txRoot: EMPTY_ROOT_HASH,
    receiptRoot: EMPTY_ROOT_HASH,
    ommersHash: EMPTY_UNCLE_HASH
  )

  if g.baseFeePerGas.isSome:
    result.baseFee = g.baseFeePerGas.get()
  elif fork >= London:
    result.baseFee = EIP1559_INITIAL_BASE_FEE.u256

  if g.gasLimit.isZero:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty.isZero and fork <= London:
    result.difficulty = GENESIS_DIFFICULTY

proc toGenesisHeader*(
    genesis: Genesis;
    fork: HardFork;
    db = TrieDatabaseRef(nil);
      ): BlockHeader
      {.gcsafe, raises: [RlpError].} =
  ## Generate the genesis block header from the `genesis` and `config` argument value.
  let
    db  = if db.isNil: newMemoryDB() else: db
    sdb = newStateDB(db, pruneTrie = true)
  toGenesisHeader(genesis, sdb, fork)

proc toGenesisHeader*(
    params: NetworkParams;
    db = TrieDatabaseRef(nil);
      ): BlockHeader
      {.raises: [RlpError].} =
  ## Generate the genesis block header from the `genesis` and `config` argument value.
  let map  = toForkToBlockNumber(params.config)
  let fork = map.toHardFork(0.toBlockNumber)
  toGenesisHeader(params.genesis, fork, db)

# End



# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
