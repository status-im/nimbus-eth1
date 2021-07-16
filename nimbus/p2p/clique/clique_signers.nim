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
## Signers for Clique PoA Consensus Protocol
## =========================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  ./clique_defs,
  ./clique_desc,
  ./snapshot/[ballot, snapshot_desc],
  eth/common,
  stew/results

type
  SignersResult* = ##\
    ## Address list/error result type
    Result[seq[EthAddress],CliqueError]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc cliqueSigners*(c: Clique; lastOk = false): SignersResult {.inline.} =
  ## Retrieves the sorted list of authorized signers for the last registered
  ## snapshot.
  ##
  ## If the argument `lastOk` is `true`, the signers result are generated
  ## from the last successfully generated snapshot (if any).
  let rc = c.snapshot(lastOk)
  if rc.isErr:
    return err(rc.error)

  # FIXME: Need to compile `signers` value before passing it to the `ok()`
  #        directive. NIM (as of 1.2.10) will somehow garble references and
  #        produce a runtime crash.
  let signers = rc.value.ballot.authSigners
  ok(signers)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
