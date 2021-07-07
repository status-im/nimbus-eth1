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
## Snapshot for Clique PoA Consensus Protocol
## ==========================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##
## Caveat: Not supporting RLP serialisation encode()/decode()
##

import
  std/[sequtils],
  ./clique_defs,
  ./clique_desc,
  ./snapshot/[lru_snaps, snapshot_desc, snapshot_misc],
  eth/common,
  stew/results

export
  clique_defs.CliqueError,
  snapshot_desc.Snapshot,
  snapshot_misc.signers,
  results


# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
proc snapshot*(c: Clique; blockNumber: BlockNumber; hash: Hash256;
               parents: openArray[Blockheader]): Result[Snapshot,CliqueError]
                    {.gcsafe, raises: [Defect,CatchableError].} =
  ## snapshot retrieves the authorization snapshot at a given point in time.
  c.recents.getLruSnaps:
    LruSnapsArgs(blockHash:   hash,
                 blockNumber: blockNumber,
                 parents:     toSeq(parents))

# End
