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
  ./clique/[clique_cfg,
            clique_defs,
            clique_desc,
            clique_signers,
            clique_snapshot,
            clique_verify,
            snapshot/snapshot_desc],
  stew/results

{.push raises: [Defect].}

# note that mining is unsupported, so the `clique_mining` module is ignored
export
  clique_cfg,
  clique_defs,
  clique_desc,
  clique_signers,
  clique_snapshot,
  clique_verify,
  snapshot_desc.Snapshot,
  results

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
