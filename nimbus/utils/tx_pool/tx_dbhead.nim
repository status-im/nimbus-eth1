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
  ../../config,
  ../../db/[db_chain, accounts_cache],
  ../../forks,
  chronicles,
  eth/[common, keys]

type
  TxDbHead* = object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db*: BaseChainDB                  ## block chain
    head*: BlockHeader                ## block chain insertion point
    fork*: Fork                       ## current fork relative to head
    accDB*: AccountsCache             ## sender accounts, etc.

{.push raises: [Defect].}

logScope:
  topics = "tx-pool block chain head"

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(dh: var TxDbHead; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  dh.db = db
  dh.head = db.getCanonicalHead
  dh.fork = db.config.toFork(dh.head.blockNumber + 1)
  dh.accDB = AccountsCache.init(db.db, dh.head.stateRoot, db.pruneTrie)

proc init*(T: type TxDbHead; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  result.init(db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
