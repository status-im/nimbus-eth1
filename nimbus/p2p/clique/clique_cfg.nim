# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Clique PoA Conmmon Config
## =========================
##
## Constants used by Clique proof-of-authority consensus protocol, see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  ../../db/db_chain,
  ./clique_defs,
  ./ec_recover,
  random,
  times

const
  prngSeed = 42

type
  CliqueCfg* = ref object
    dbChain*: BaseChainDB
    signatures*: EcRecover  ## Recent block signatures to speed up mining
    period*: Duration       ## time between blocks to enforce
    epoch*: uint64          ## Epoch length to reset votes and checkpoint
    prng*: Rand             ## PRNG state

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc newCliqueCfg*(dbChain: BaseChainDB;
                   period = BLOCK_PERIOD; epoch = EPOCH_LENGTH): CliqueCfg =
  CliqueCfg(
    dbChain:    dbChain,
    period:     period,
    epoch:      epoch,
    signatures: initEcRecover(),
    prng:       initRand(prngSeed))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
