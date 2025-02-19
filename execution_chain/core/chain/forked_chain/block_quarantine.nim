# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/tables,
  results,
  eth/common/blocks

const
  MaxOrphans = 128

type
  Quarantine* = object
    ## Keeps track of unvalidated blocks coming from the network
    ## and that cannot yet be added to the chain
    ##
    ## This only stores blocks that cannot be linked to the
    ## ForkedChain due to missing ancestor(s).

    orphans: OrderedTable[Hash32, Block]
      ## Blocks that we don't have a parent for - when we resolve the
      ## parent, we can proceed to resolving the block as well - we
      ## index this by parentHash.

func addOrphan*(quarantine: var Quarantine, blk: Block) =
  if quarantine.orphans.len >= MaxOrphans:
    # Evict based on FIFO
    var oldest_orphan_key: Hash32
    for k in quarantine.orphans.keys:
      oldest_orphan_key = k
      break
    quarantine.orphans.del oldest_orphan_key

  quarantine.orphans[blk.header.parentHash] = blk

func popOrphan*(quarantine: var Quarantine, parentHash: Hash32): Opt[Block] =
  var blk: Block
  if quarantine.orphans.pop(parentHash, blk):
    Opt.some(blk)
  else:
    Opt.none(Block)

func hasOrphans*(quarantine: Quarantine): bool =
  quarantine.orphans.len > 0
