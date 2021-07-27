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
  std/[sequtils],
  ../db/db_chain,
  ./clique/[clique_cfg, clique_defs, clique_desc, clique_verify],
  ./clique/snapshot/[ballot, snapshot_desc],
  eth/common,
  stew/results

{.push raises: [Defect].}

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

proc newClique*(db: BaseChainDB): Clique =
  ## Constructor for a new Clique proof-of-authority consensus engine. The
  ## initial state of the engine is `empty`, there are no authorised signers.
  db.newCliqueCfg.newClique


proc cliqueSave*(c: var Clique): CliqueState =
  ## Save current `Clique` state. This state snapshot saves the internal
  ## data that make up the list of authorised signers (see `cliqueSigners()`
  ## below.)
  ok(c.snapshot)

proc cliqueRestore*(c: var Clique; state: var CliqueState) =
  ## Restore current `Clique` state from a saved snapshot.
  ##
  ## For the particular `state` argument this fuction is disabled with
  ## `cliqueDispose()`. So it can be savely wrapped in a `defer:` statement.
  ## In transaction lingo, this would then be the rollback function.
  if state.isOk:
    c.snapshot = state.value

proc cliqueDispose*(c: var Clique; state: var CliqueState) =
  ## Disable the function `cliqueDispose()` for the particular `state`
  ## argument.
  ##
  ## In transaction lingo, this would be the commit function if
  ## `cliqueRestore()` was wrapped in a `defer:` statement.
  state = err(CliqueState)


proc cliqueVerify*(c: Clique; header: BlockHeader;
                  parents: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  ## Check whether a header conforms to the consensus rules. The caller may
  ## optionally pass on a batch of parents (ascending order) to avoid looking
  ## those up from the database. This function updates the list of authorised
  ## signers (see `cliqueSigners()` below.)
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor and is accessible as `c.failed`.
  ##
  ## This function is not transaction-save, that is the internal state of
  ## the authorised signers list has the state of the last update after a
  ## successful header verification. The hash of the failing header together
  ## with the error message is then accessible as `c.failed`.
  ##
  ## Use the directives `cliqueSave()`, `cliqueDispose()`, and/or
  ## `cliqueRestore()` for transaction.
  var list = toSeq(parents)
  c.cliqueVerifySeq(header, list)

# clique/clique.go(217): func (c *Clique) VerifyHeader(chain [..]
proc cliqueVerify*(c: Clique; header: BlockHeader): CliqueOkResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  ## Consensus rules verifier without optional parents list.
  var blind: seq[BlockHeader]
  c.cliqueVerifySeq(header, blind)

proc cliqueVerify*(c: Clique;
                   headers: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  ## This function verifies a batch of headers checking each header for
  ## consensus rules conformance (see also the other `cliqueVerify()` function
  ## instance.) The `headers` list is supposed to contain a chain of headers,
  ## i.e. `headers[i]` is parent to `headers[i+1]`.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor and is accessible as `c.failed`.
  ##
  ## This function is not transaction-save, that is the internal state of
  ## the authorised signers list has the state of the last update after a
  ## successful header verification. The hash of the failing header together
  ## with the error message is then accessible as `c.failed`.
  ##
  ## Use the directives `cliqueSave()`, `cliqueDispose()`, and/or
  ## `cliqueRestore()` for transaction.
  var list = toSeq(headers)
  c.cliqueVerifySeq(list)


proc cliqueSigners*(c: Clique): seq[EthAddress] {.inline.} =
  ## Retrieve the sorted list of authorized signers for the current state
  ## of the `Clique` descriptor.
  ##
  ## Note that the return argument list is sorted on-the-fly each time this
  ## function is invoked.
  c.snapshot.ballot.authSigners

proc cliqueSignersLen*(c: Clique): int {.inline.} =
  ## Get the number of authorized signers for the current state of the
  ## `Clique` descriptor. The result is equivalent to `c.cliqueSigners.len`.
  c.snapshot.ballot.authSignersLen

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
