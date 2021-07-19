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
  ./clique/[clique_cfg, clique_defs, clique_desc, clique_verify],
  ./clique/snapshot/[ballot, snapshot_desc],
  eth/common,
  stew/results

{.push raises: [Defect].}

# note that mining is unsupported, so the `clique_mining` module is ignored
export
  clique_cfg,
  clique_defs,
  clique_desc

type
  CliqueState* = ##\
    ## Descriptor state snapshot which can be used for implementing
    ## transaction trasnaction handling. Nore the the `Snapshot` type
    ## inside the `Result[]` is most probably opaque.
    Result[Snapshot,void]

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc cliqueSave*(c: var Clique): CliqueState =
  ## Save current `Clique` state.
  ok(c.snapshot)

proc cliqueRestore*(c: var Clique; state: var CliqueState) =
  ## Restore current `Clique` state from a saved snapshot.
  ##
  ## For the particular `state` argument this fuction is disabled with
  ## `cliqueDispose()`. So it can be savely handled in a `defer:` statement.
  if state.isOk:
    c.snapshot = state.value

proc cliqueDispose*(c: var Clique; state: var CliqueState) =
  ## Disable the function `cliqueDispose()` for the particular `state`
  ## argument
  state = err(CliqueState)


proc cliqueVerify*(c: Clique; header: BlockHeader;
                  parents: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  ## Check whether a header conforms to the consensus rules. The caller may
  ## optionally pass on a batch of parents (ascending order) to avoid looking
  ## those up from the database. This might be useful for concurrently
  ## verifying a batch of new headers.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor
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
  ## consensus rules conformance. The `headers` list is supposed to contain a
  ## chain of headers, i e. `headers[i]` is parent to `headers[i+1]`.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor
  ##
  ## If there is an error, this error is also stored within the `Clique`
  ## descriptor and can be retrieved via `c.failed` along with the hash/ID of
  ## the failed block header.
  var list = toSeq(headers)
  c.cliqueVerifySeq(list)


proc cliqueSigners*(c: Clique): seq[EthAddress] {.inline.} =
  ## Retrieve the sorted list of authorized signers for the current state
  ## of the `Clique` descriptor.
  ##
  ## Note the the returned list is sorted on-the-fly each time this function
  ## is invoked.
  c.snapshot.ballot.authSigners

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
