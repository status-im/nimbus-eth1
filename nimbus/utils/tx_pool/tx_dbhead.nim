# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Block Chain Head State
## =======================================
##

import
  ../../chain_config,
  ../../db/[db_chain, accounts_cache],
  ../../forks,
  ./tx_item,
  eth/[common, keys, p2p]

type
  TxDbHeadRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db*: BaseChainDB       ## block chain database
    head*: BlockHeader     ## new block insertion point
    fork*: Fork            ## current fork relative to head
    accDB*: AccountsCache  ## sender accounts, etc.
    baseFee*: GasPrice     ## current base fee derived from `head`
    trgGasLimit*: GasInt   ## effective `gasLimit` for the packer
    maxGasLimit*: GasInt   ## may increase the `gasLimit` a bit

const
  # currently implemented only fo some tesing
  londonBlock = 12_965_000.u256

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toForkOrLondon(db: BaseChainDB; number: BlockNumber): Fork =
  ## returns the real fork, including *London* which is unsupported by the
  ## current implementation of configutation tools (does not provide for
  ## detecting a *London* fork unless set manually for debugging.)
  ##
  ## This function also returns *London* on a block earlier than `londonBlock`
  ## if configured smaller than that (as mentioned above, when set manually
  ## for testing.)
  if db.networkId == MainNet and londonBlock <= number:
    return FkLondon
  db.config.toFork(number)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc update*(dh: TxDbHeadRef; newHead: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update by block header

  dh.head = newHead
  dh.fork = dh.db.toForkOrLondon(dh.head.blockNumber + 1)
  dh.accDB = AccountsCache.init(dh.db.db, dh.head.stateRoot, dh.db.pruneTrie)

  if FkLondon <= dh.fork:
    dh.baseFee = dh.head.baseFee.truncate(uint64).GasPrice
    # https://ethereum.org/en/developers/docs/blocks/#block-size
    dh.trgGasLimit = 15_000_000_000.GasInt
    dh.trgGasLimit = 2 * dh.trgGasLimit
  else:
    dh.baseFee = 0.GasPrice
    dh.trgGasLimit = dh.head.gasLimit.GasInt

    # https://ethereum.stackexchange.com/questions/592/
    #           /why-was-frontiers-default-gaslimit-3141592/1092#1092
    # block can increase by sort of 1 promille
    dh.maxGasLimit = dh.trgGasLimit + (dh.trgGasLimit shr 10)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxDbHeadRef; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result
  result.db = db
  result.update(db.getCanonicalHead)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
