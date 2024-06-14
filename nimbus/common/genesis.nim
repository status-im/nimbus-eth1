# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  ../db/[ledger, core_db],
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

  GenesisSetStorageFn = proc(
    address: EthAddress; slot: UInt256; val: UInt256) {.rlpRaise.}

  GenesisCommitFn = proc() {.noRaise.}

  GenesisRootHashFn = proc: Hash256 {.noRaise.}

  GenesisLedgerRef* = ref object
    ## Exportable ledger DB just for initialising Genesis.
    ##
    addAccount: GenesisAddAccountFn
    setStorage: GenesisSetStorageFn
    commit: GenesisCommitFn
    rootHash: GenesisRootHashFn

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc initAccountsLedgerRef(
    db: CoreDbRef;
     ): GenesisLedgerRef =
  ## Methods jump table
  let ac = LedgerRef.init(db, EMPTY_ROOT_HASH)

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

    setStorage: proc(
        address: EthAddress;
        slot: UInt256;
        val: UInt256;
          ) =
      ac.setStorage(address, slot, val),

    commit: proc() =
      ac.persist(),

    rootHash: proc(): Hash256 =
      ac.state())

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc newStateDB*(
    db: CoreDbRef;
      ): GenesisLedgerRef =
  db.initAccountsLedgerRef()

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

  for address, account in g.alloc:
    sdb.addAccount(address, account.nonce, account.balance, account.code)

    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  sdb.commit()

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixHash: g.mixHash,
    coinbase: g.coinbase,
    stateRoot: sdb.rootHash(),
    parentHash: GENESIS_PARENT_HASH,
    txRoot: EMPTY_ROOT_HASH,
    receiptsRoot: EMPTY_ROOT_HASH,
    ommersHash: EMPTY_UNCLE_HASH
  )

  if g.baseFeePerGas.isSome:
    result.baseFeePerGas = Opt.some(g.baseFeePerGas.get)
  elif fork >= London:
    result.baseFeePerGas = Opt.some(EIP1559_INITIAL_BASE_FEE)

  if g.gasLimit == 0:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty.isZero and fork <= London:
    result.difficulty = GENESIS_DIFFICULTY

  if fork >= Shanghai:
    result.withdrawalsRoot = Opt.some(EMPTY_ROOT_HASH)

  if fork >= Cancun:
    result.blobGasUsed           = Opt.some g.blobGasUsed.get(0'u64)
    result.excessBlobGas         = Opt.some g.excessBlobGas.get(0'u64)
    result.parentBeaconBlockRoot = Opt.some g.parentBeaconBlockRoot.get(Hash256())

proc toGenesisHeader*(
    genesis: Genesis;
    fork: HardFork;
    db = CoreDbRef(nil)): BlockHeader
      {.gcsafe, raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let
    db  = if db.isNil: AristoDbMemory.newCoreDbRef() else: db
    sdb = db.newStateDB()
  toGenesisHeader(genesis, sdb, fork)

proc toGenesisHeader*(
    params: NetworkParams;
    db = CoreDbRef(nil)
      ): BlockHeader
      {.raises: [CatchableError].} =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let map  = toForkTransitionTable(params.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.BlockNumber, params.genesis.timestamp))
  toGenesisHeader(params.genesis, fork, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
