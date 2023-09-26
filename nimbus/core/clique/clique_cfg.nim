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
{.push raises: [].}

import
  std/[random, times],
  ethash,
  ../../db/core_db,
  ../../utils/ec_recover,
  ./clique_defs

export
  core_db

const
  prngSeed = 42

type
  CliqueCfg* = ref object of RootRef
    db*: CoreDbRef
      ## All purpose (incl. blockchain) database.

    nSnaps*: uint64
      ## Number of snapshots stored on disk (for logging troublesshoting)

    snapsData*: uint64
      ## Raw payload stored on disk (for logging troublesshoting)

    period: EthTime
      ## Time between blocks to enforce.

    ckpInterval: int
      ## Number of blocks after which to save the vote snapshot to the
      ## disk database.

    roThreshold: int
      ## Number of blocks after which a chain segment is considered immutable
      ## (ie. soft finality). It is used by the downloader as a hard limit
      ## against deep ancestors, by the blockchain against deep reorgs, by the
      ## freezer as the cutoff threshold and by clique as the snapshot trust
      ## limit.

    prng: Rand
      ## PRNG state for internal random generator. This PRNG is
      ## cryptographically insecure but with reproducible data stream.

    signatures: EcRecover
      ## Recent block signatures cached to speed up mining.

    epoch: int
      ## The number of blocks after which to checkpoint and reset the pending
      ## votes.Suggested 30000 for the testnet to remain analogous to the
      ## mainnet ethash epoch.

    logInterval: Duration
      ## Time interval after which the `snapshotApply()` function main loop
      ## produces logging entries.

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newCliqueCfg*(db: CoreDbRef): CliqueCfg =
  result = CliqueCfg(
    db:          db,
    epoch:       EPOCH_LENGTH,
    period:      BLOCK_PERIOD,
    ckpInterval: CHECKPOINT_INTERVAL,
    roThreshold: FULL_IMMUTABILITY_THRESHOLD,
    logInterval: SNAPS_LOG_INTERVAL_MICSECS,
    signatures:  EcRecover.init(),
    prng:        initRand(prngSeed))

# ------------------------------------------------------------------------------
# Public helper funcion
# ------------------------------------------------------------------------------

# clique/clique.go(145): func ecrecover(header [..]
proc ecRecover*(
    cfg: CliqueCfg;
    header: BlockHeader;
      ): auto =
  cfg.signatures.ecRecover(header)

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `epoch=`*(cfg: CliqueCfg; epoch: SomeInteger) =
  ## Setter
  cfg.epoch = if 0 < epoch: epoch
              else: EPOCH_LENGTH

proc `period=`*(cfg: CliqueCfg; period: EthTime) =
  ## Setter
  cfg.period = if period != EthTime(0): period
               else: BLOCK_PERIOD

proc `ckpInterval=`*(cfg: CliqueCfg; numBlocks: SomeInteger) =
  ## Setter
  cfg.ckpInterval = if 0 < numBlocks: numBlocks
                    else: CHECKPOINT_INTERVAL

proc `roThreshold=`*(cfg: CliqueCfg; numBlocks: SomeInteger) =
  ## Setter
  cfg.roThreshold = if 0 < numBlocks: numBlocks
                    else: FULL_IMMUTABILITY_THRESHOLD

proc `logInterval=`*(cfg: CliqueCfg; duration: Duration) =
  ## Setter
  cfg.logInterval = if duration != Duration(): duration
                    else: SNAPS_LOG_INTERVAL_MICSECS

# ------------------------------------------------------------------------------
# Public PRNG, may be overloaded
# ------------------------------------------------------------------------------

method rand*(cfg: CliqueCfg; max: Natural): int {.gcsafe, base, raises: [].} =
  ## The method returns a random number base on an internal PRNG providing a
  ## reproducible stream of random data. This function is supposed to be used
  ## exactly when repeatability comes in handy. Never to be used for crypto key
  ## generation or like (except testing.)
  cfg.prng.rand(max)

# ------------------------------------------------------------------------------
# Public getter
# ------------------------------------------------------------------------------

proc epoch*(cfg: CliqueCfg): BlockNumber =
  ## Getter
  cfg.epoch.u256

proc period*(cfg: CliqueCfg): EthTime =
  ## Getter
  cfg.period

proc ckpInterval*(cfg: CliqueCfg): BlockNumber =
  ## Getter
  cfg.ckpInterval.u256

proc roThreshold*(cfg: CliqueCfg): int =
  ## Getter
  cfg.roThreshold

proc logInterval*(cfg: CliqueCfg): Duration =
  ## Getter
  cfg.logInterval

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
