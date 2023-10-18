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
## EIP-225 Clique PoA Consensus Protocol
## =====================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  ./clique/[clique_cfg, clique_defs, clique_desc],
  ./clique/snapshot/[ballot, snapshot_desc],
  stew/results

{.push raises: [].}

# Note that mining is unsupported. Unused code ported from the Go
# implementation is stashed into the `clique_unused` module.
export
  clique_cfg,
  clique_defs,
  clique_desc.Clique

type
  CliqueState* = ##\
    ## Descriptor state snapshot which can be used for implementing
    ## transaction trasnaction handling. Nore the the `Snapshot` type
    ## inside the `Result[]` is most probably opaque.
    Result[Snapshot,void]

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc newClique*(db: CoreDbRef, cliquePeriod: EthTime, cliqueEpoch: int): Clique =
  ## Constructor for a new Clique proof-of-authority consensus engine. The
  ## initial state of the engine is `empty`, there are no authorised signers.
  ##
  ## If chain_config provides `Period` or `Epoch`, then `Period` or `Epoch`
  ## will be taken from chain_config. Otherwise, default value in `newCliqueCfg`
  ## will be used

  let cfg = db.newCliqueCfg
  if cliquePeriod > 0:
    cfg.period = cliquePeriod
  if cliqueEpoch > 0:
    cfg.epoch = cliqueEpoch
  cfg.newClique

proc cliqueSave*(c: Clique): CliqueState =
  ## Save current `Clique` state. This state snapshot saves the internal
  ## data that make up the list of authorised signers (see `cliqueSigners()`
  ## below.)
  ok(c.snapshot)

proc cliqueRestore*(c: Clique; state: var CliqueState) =
  ## Restore current `Clique` state from a saved snapshot.
  ##
  ## For the particular `state` argument this fuction is disabled with
  ## `cliqueDispose()`. So it can be savely wrapped in a `defer:` statement.
  ## In transaction lingo, this would then be the rollback function.
  if state.isOk:
    c.snapshot = state.value

proc cliqueDispose*(c: Clique; state: var CliqueState) =
  ## Disable the function `cliqueDispose()` for the particular `state`
  ## argument.
  ##
  ## In transaction lingo, this would be the commit function if
  ## `cliqueRestore()` was wrapped in a `defer:` statement.
  state = err(CliqueState)

proc cliqueSigners*(c: Clique): seq[EthAddress] =
  ## Retrieve the sorted list of authorized signers for the current state
  ## of the `Clique` descriptor.
  ##
  ## Note that the return argument list is sorted on-the-fly each time this
  ## function is invoked.
  c.snapshot.ballot.authSigners

proc cliqueSignersLen*(c: Clique): int =
  ## Get the number of authorized signers for the current state of the
  ## `Clique` descriptor. The result is equivalent to `c.cliqueSigners.len`.
  c.snapshot.ballot.authSignersLen

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
