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
  ./clique_desc,
  ./snapshot/[ballot, snapshot_desc],
  eth/common

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc cliqueSigners*(c: Clique): seq[EthAddress] {.inline.} =
  ## Retrieves the sorted list of authorized signers for the last registered
  ## snapshot. If there was no snapshot, an empty list is returned.
  c.snapshot.ballot.authSigners

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
