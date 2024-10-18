# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import eth/common/hashes, web3/primitives, stew/keyed_queue, results, ./rpc/rpc_utils

## Cache for payloads received through block gossip and validated by the
## consensus light client.
## The payloads are stored in order of arrival. When the cache is full, the
## oldest payload is deleted first.
type BlockCache* = ref object
  max: int
  blocks: KeyedQueue[Hash32, ExecutionData]

proc `==`(x, y: Quantity): bool {.borrow, noSideEffect.}

proc new*(T: type BlockCache, max: uint32): T =
  let maxAsInt = int(max)
  return
    BlockCache(max: maxAsInt, blocks: KeyedQueue[Hash32, ExecutionData].init(maxAsInt))

func len*(self: BlockCache): int =
  return len(self.blocks)

func isEmpty*(self: BlockCache): bool =
  return len(self.blocks) == 0

proc add*(self: BlockCache, payload: ExecutionData) =
  if self.blocks.hasKey(payload.blockHash):
    return

  if len(self.blocks) >= self.max:
    discard self.blocks.shift()

  discard self.blocks.append(payload.blockHash, payload)

proc latest*(self: BlockCache): results.Opt[ExecutionData] =
  let latestPair = ?self.blocks.last()
  return Opt.some(latestPair.data)

proc getByNumber*(self: BlockCache, number: Quantity): Opt[ExecutionData] =
  var payloadResult: Opt[ExecutionData]

  for payload in self.blocks.prevValues:
    if payload.blockNumber == number:
      payloadResult = Opt.some(payload)
      break

  return payloadResult

proc getPayloadByHash*(self: BlockCache, hash: Hash32): Opt[ExecutionData] =
  return self.blocks.eq(hash)
