import
  std/tables,
  eth/[common, eip1559],
  eth/trie/trie_defs,
  ../db/[core_db, state_db],
  ../constants,
  ./chain_config

{.push raises: [].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------
proc newStateDB*(
    db: CoreDbRef;
    pruneTrie: bool;
      ): AccountStateDB
      {.gcsafe, raises: [].}=
  newAccountStateDB(db, emptyRlpHash, pruneTrie)

proc toGenesisHeader*(
    g: Genesis;
    sdb: AccountStateDB;
    fork: HardFork;
      ): BlockHeader
      {.gcsafe, raises: [CatchableError].} =
  ## Initialise block chain DB accounts derived from the `genesis.alloc` table
  ## of the `db` descriptor argument.
  ##
  ## The function returns the `Genesis` block header.
  ##

  # The following kludge is needed for the `LegacyDbPersistent` type database
  # when `pruneTrie` is enabled. For other cases, this code is irrelevant.
  sdb.db.compensateLegacySetup()

  for address, account in g.alloc:
    sdb.setAccount(address, newAccount(account.nonce, account.balance))
    sdb.setCode(address, account.code)

    # Kludge:
    #
    # See https://github.com/status-im/nim-eth/issues/9 where other,
    # probably related debilities are discussed.
    #
    # This kludge also fixes the initial crash described in
    # https://github.com/status-im/nimbus-eth1/issues/932.
    if sdb.pruneTrie and 0 < account.storage.len:
      sdb.db.compensateLegacySetup() # <-- kludge

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

  if g.gasLimit == 0:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty.isZero and fork <= London:
    result.difficulty = GENESIS_DIFFICULTY

  if fork >= Shanghai:
    result.withdrawalsRoot = some(EMPTY_ROOT_HASH)

  if fork >= Cancun:
    result.blobGasUsed = g.blobGasUsed.get(0'u64).some
    result.excessBlobGas = g.excessBlobGas.get(0'u64).some
    result.parentBeaconBlockRoot = g.parentBeaconBlockRoot.get(Hash256()).some

proc toGenesisHeader*(
    genesis: Genesis;
    fork: HardFork;
    db = CoreDbRef(nil);
      ): BlockHeader
      {.gcsafe, raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let
    db  = if db.isNil: newCoreDbRef LegacyDbMemory else: db
    sdb = newStateDB(db, pruneTrie = true)
  toGenesisHeader(genesis, sdb, fork)

proc toGenesisHeader*(
    params: NetworkParams;
    db = CoreDbRef(nil);
      ): BlockHeader
      {.raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let map  = toForkTransitionTable(params.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.toBlockNumber, params.genesis.timestamp))
  toGenesisHeader(params.genesis, fork, db)

# End



# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
