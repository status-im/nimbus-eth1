# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import eth/common/hashes, web3/eth_api_types, minilru, results

## Cache for payloads received through block gossip and validated by the
## consensus light client.
## The payloads are stored in order of arrival. When the cache is full, the
## oldest payload is deleted first.
type BlockCache* = ref object
  blocks: LruCache[Hash32, BlockObject]

proc new*(T: type BlockCache, max: uint32): T =
  let maxAsInt = int(max)
  BlockCache(blocks: LruCache[Hash32, BlockObject].init(maxAsInt))

func len*(self: BlockCache): int =
  len(self.blocks)

func isEmpty*(self: BlockCache): bool =
  len(self.blocks) == 0

proc add*(self: BlockCache, payload: BlockObject) =
  # Only add if it didn't exist before - the implementation of `latest` relies
  # on this..
  if payload.hash notin self.blocks:
    self.blocks.put(payload.hash, payload)

proc latest*(self: BlockCache): Opt[BlockObject] =
  for b in self.blocks.values:
    return Opt.some(b)
  Opt.none(BlockObject)

proc getByNumber*(self: BlockCache, number: Quantity): Opt[BlockObject] =
  for b in self.blocks.values:
    if b.number == number:
      return Opt.some(b)

  Opt.none(BlockObject)

proc getPayloadByHash*(self: BlockCache, hash: Hash32): Opt[BlockObject] =
  self.blocks.get(hash)
