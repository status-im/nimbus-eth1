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
  ../../db/db_chain,
  ./clique_defs,
  ./clique_desc,
  ./snapshot/[ballot, lru_snaps, snapshot_desc],
  eth/common,
  stew/results

export
  clique_defs.CliqueError,
  clique_defs.CliqueOkResult,
  snapshot_desc.Snapshot,
  snapshot_desc.SnapshotResult,
  results

{.push raises: [Defect].}

# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
#proc snapshotRegister*(c: Clique; blockNumber: BlockNumber; hash: Hash256;
#                       parents: openArray[Blockheader]): CliqueOkResult
#                        {.deprecated,gcsafe,raises: [Defect,CatchableError].} =
#  ## Create authorisation state snapshot of a given point in the block chain
#  ## and store it in the `Clique` descriptor to be retrievable as `c.lastSnap`.
#  c.lastSnap = c.recents.getLruSnaps:
#    LruSnapsArgs(blockHash:   hash,
#                 blockNumber: blockNumber,
#                 parents:     toSeq(parents))
#
#  return if c.lastSnap.isErr: err((c.lastSnap.error)) else: ok()


proc snapshotRegister*(c: Clique; header: Blockheader;
                       parents: openArray[Blockheader]): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as `c.lastSnap`.
  c.lastSnap = c.recents.getLruSnaps(header, parents)
  return if c.lastSnap.isErr: err((c.lastSnap.error)) else: ok()

proc snapshotRegister*(c: Clique; header: Blockheader): CliqueOkResult
                         {.inline,gcsafe,raises: [Defect,CatchableError].} =
  c.snapshotRegister(header, @[])


proc snapshotRegister*(c: Clique; hash: Hash256;
                       parents: openArray[Blockheader]): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as `c.lastSnap`.
  var header: BlockHeader
  if not c.cfg.db.getBlockHeader(hash, header):
    return err((errUnknownHash,""))
  c.snapshotRegister(header, parents)

proc snapshotRegister*(c: Clique; hash: Hash256): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  c.snapshotRegister(hash, @[])


proc snapshotSigners*(c: Clique): seq[EthAddress] {.inline.} =
  ## Retrieves the sorted list of currently authorized signers if there was
  ## an snapshor registered recently. Otherrwise an empty list is returned.
  if c.lastSnap.isOK:
    result = c.lastSnap.value.ballot.authSigners

# End
