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
  minilru,
  eth/common/[blocks, block_access_lists]


type
  Quarantine* = object
    ## Keeps track of unvalidated blocks coming from the network
    ## and that cannot yet be added to the chain
    ##
    ## This only stores blocks that cannot be linked to the
    ## ForkedChain due to missing ancestor(s).

    orphans: LruCache[Hash32, (Block, Opt[BlockAccessListRef])]
      ## Blocks that we don't have a parent for - when we resolve the
      ## parent, we can proceed to resolving the block as well - we
      ## index this by parentHash.

    headers: LruCache[Hash32, Header]
      ## Headers that we don't have a parent for - index by block hash.

const
  # MaxOrphans is the maximum nimber of orphaned blocks stored in quarantine
  # waiting for parent.
  MaxOrphans = 8

  # MaxTrackedHeaders is the maximum number of block headers the execution
  # engine tracks before evicting old ones. Ideally we should only ever track
  # the latest one; but have a slight wiggle room for non-ideal conditions.
  MaxTrackedHeaders = 96

func init*(T: type Quarantine): T =
  T(
    orphans: LruCache[Hash32, (Block, Opt[BlockAccessListRef])].init(MaxOrphans),
    headers: LruCache[Hash32, Header].init(MaxTrackedHeaders),
  )

func addOrphan*(
    quarantine: var Quarantine,
    blockHash: Hash32,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef]
  ) =
  quarantine.orphans.put(blk.header.parentHash, (blk, blockAccessList))
  quarantine.headers.put(blockHash, blk.header)

func popOrphan*(quarantine: var Quarantine, parentHash: Hash32): Opt[(Block, Opt[BlockAccessListRef])] =
  quarantine.orphans.pop(parentHash)

func hasOrphans*(quarantine: Quarantine): bool =
  quarantine.orphans.len > 0

func getHeader*(quarantine: var Quarantine, blockHash: Hash32): Opt[Header] =
  quarantine.headers.get(blockHash)
