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
  eth/eip1559,
  eth/common/[hashes, accounts, headers, addresses],
  ../db/[ledger, core_db],
  ../constants,
  ./chain_config

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toGenesisHeader*(
    g: Genesis;
    db: CoreDbRef;
    fork: HardFork;
      ): Header =
  ## Initialise block chain DB accounts derived from the `genesis.alloc` table
  ## of the `db` descriptor argument.
  ##
  ## The function returns the `Genesis` block header.
  ##
  let ac = LedgerRef.init(db)

  for address, account in g.alloc:
    ac.setNonce(address, account.nonce)
    ac.setBalance(address, account.balance)
    ac.setCode(address, account.code)

    for k, v in account.storage:
      ac.setStorage(address, k, v)

  ac.persist()

  result = Header(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixHash: g.mixHash,
    coinbase: g.coinbase,
    stateRoot: ac.getStateRoot(),
    parentHash: GENESIS_PARENT_HASH,
    transactionsRoot: EMPTY_ROOT_HASH,
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
    result.parentBeaconBlockRoot = Opt.some g.parentBeaconBlockRoot.get(default(Hash32))

proc toGenesisHeader*(
    genesis: Genesis;
    fork: HardFork;
    db = CoreDbRef(nil)): Header =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let
    db  = if db.isNil: AristoDbMemory.newCoreDbRef() else: db
  toGenesisHeader(genesis, db, fork)

proc toGenesisHeader*(
    params: NetworkParams;
    db = CoreDbRef(nil)
      ): Header =
  ## Generate the genesis block header from the `genesis` and `config`
  ## argument value.
  let map  = toForkTransitionTable(params.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.BlockNumber, params.genesis.timestamp))
  toGenesisHeader(params.genesis, fork, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
