# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/tables,
  eth/[common, eip1559],
  eth/trie/trie_defs,
  ../db/[accounts_cache, core_db, distinct_tries, state_db/read_write],
  ../constants,
  ./chain_config

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   rlpRaise, gcsafe, raises: [RlpError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

type
  GenesisAddAccountFn = proc(
    address: EthAddress; nonce: AccountNonce; balance: UInt256;
    code: openArray[byte]) {.catchRaise.}

  GenesisCompensateLegacySetupFn = proc() {.noRaise.}

  GenesisSetStorageFn = proc(
    address: EthAddress; slot: UInt256; val: UInt256) {.rlpRaise.}

  GenesisCommitFn = proc() {.noRaise.}

  GenesisRootHashFn = proc: Hash256 {.noRaise.}

  GenesisGetTrieFn = proc: CoreDbMptRef {.noRaise.}

  GenesisLedgerRef* = ref object
    ## Exportable ledger DB just for initialising Genesis. This is needed
    ## when using the `Aristo` backend which is not fully supported by the
    ## `AccountStateDB` object.
    ##
    ## Currently, using other than the `AccountStateDB` ledgers are
    ## experimental and test only. Eventually, the `GenesisLedgerRef` wrapper
    ## should disappear so that the `Ledger` object (which encapsulates
    ## `AccountsCache` and `AccountsLedger`) will prevail.
    ##
    addAccount: GenesisAddAccountFn
    compensateLegacySetup: GenesisCompensateLegacySetupFn
    setStorage: GenesisSetStorageFn
    commit: GenesisCommitFn
    rootHash: GenesisRootHashFn
    getTrie: GenesisGetTrieFn

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc initStateDbledgerRef(db: CoreDbRef; pruneTrie: bool): GenesisLedgerRef =
  let sdb = newAccountStateDB(db, emptyRlpHash, pruneTrie)

  GenesisLedgerRef(
    addAccount: proc(
        address: EthAddress;
        nonce: AccountNonce;
        balance: UInt256;
        code: openArray[byte];
          ) {.catchRaise.} =
      sdb.setAccount(address, newAccount(nonce, balance))
      sdb.setCode(address, code),

    compensateLegacySetup: proc() =
      if pruneTrie: db.compensateLegacySetup(),

    setStorage: proc(
        address: EthAddress;
        slot: UInt256;
        val: UInt256;
          ) {.rlpRaise.} =
      sdb.setStorage(address, slot, val),

    commit: proc() =
      discard,

    rootHash: proc(): Hash256 =
      sdb.rootHash(),

    getTrie: proc(): CoreDbMptRef =
      sdb.getTrie())


proc initAccountsLedgerRef(db: CoreDbRef; pruneTrie: bool): GenesisLedgerRef =
  let ac = AccountsCache.init(db, emptyRlpHash, pruneTrie)

  GenesisLedgerRef(
    addAccount: proc(
        address: EthAddress;
        nonce: AccountNonce;
        balance: UInt256;
        code: openArray[byte];
          ) =
      ac.setNonce(address, nonce)
      ac.setBalance(address, balance)
      ac.setCode(address, @code),

    compensateLegacySetup: proc() =
      if pruneTrie: db.compensateLegacySetup(),

    setStorage: proc(
        address: EthAddress;
        slot: UInt256;
        val: UInt256;
          ) {.rlpRaise.} =
      ac.setStorage(address, slot, val),

    commit: proc() =
      ac.persist(),

    rootHash: proc(): Hash256 =
      ac.rootHash(),

    getTrie: proc(): CoreDbMptRef =
      ac.rawTrie.mpt)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc newStateDB*(
    db: CoreDbRef;
    pruneTrie: bool;
    avoidStateDb = false;
      ): GenesisLedgerRef =
  ## The flag `avoidStateDb` is set `false` for compatibility with legacy apps
  ## `(see `test_state_network`).
  if avoidStateDb:
    db.initAccountsLedgerRef pruneTrie
  else:
    db.initStateDbledgerRef pruneTrie

proc getTrie*(sdb: GenesisLedgerRef): CoreDbMptRef =
  ## Getter, used in `test_state_network`
  sdb.getTrie()

proc toGenesisHeader*(
    g: Genesis;
    sdb: GenesisLedgerRef;
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
  sdb.compensateLegacySetup()

  for address, account in g.alloc:
    sdb.addAccount(address, account.nonce, account.balance, account.code)

    # Kludge:
    #
    # See https://github.com/status-im/nim-eth/issues/9 where other,
    # probably related debilities are discussed.
    #
    # This kludge also fixes the initial crash described in
    # https://github.com/status-im/nimbus-eth1/issues/932.
    sdb.compensateLegacySetup() # <-- kludge

    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  sdb.commit()

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixDigest: g.mixHash,
    coinbase: g.coinbase,
    stateRoot: sdb.rootHash(),
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
    avoidStateDb = false;
      ): BlockHeader
      {.gcsafe, raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let
    db  = if db.isNil: newCoreDbRef LegacyDbMemory else: db
    sdb = newStateDB(db, pruneTrie = true, avoidStateDb)
  toGenesisHeader(genesis, sdb, fork)

proc toGenesisHeader*(
    params: NetworkParams;
    db = CoreDbRef(nil);
    avoidStateDb = false;
      ): BlockHeader
      {.raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let map  = toForkTransitionTable(params.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.toBlockNumber, params.genesis.timestamp))
  toGenesisHeader(params.genesis, fork, db, avoidStateDb)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
