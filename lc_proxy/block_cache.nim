# light client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/tables,
  web3/ethtypes,
  stew/[results, keyed_queue]


## payloads received through block gossip (and validated by light client).
## Payloads are stored in order of arrival. When cache is full the oldest
## payload is deleted first.
type BlockCache* = ref object
  max: int
  blocks: KeyedQueue[BlockHash, ExecutionPayloadV1]

proc `==`(x, y: Quantity): bool {.borrow, noSideEffect.}

proc new*(T: type BlockCache, max: uint32): T =
  let maxAsInt = int(max)
  return BlockCache(
    max: maxAsInt,
    blocks: KeyedQueue[BlockHash, ExecutionPayloadV1].init(maxAsInt)
  )

func len*(self: BlockCache): int =
  return len(self.blocks)

func isEmpty*(self: BlockCache): bool =
  return len(self.blocks) == 0

proc add*(self: BlockCache, payload: ExecutionPayloadV1) =
  if self.blocks.hasKey(payload.blockHash):
    return

  if len(self.blocks) >= self.max:
   discard self.blocks.shift()

  discard self.blocks.append(payload.blockHash, payload)

proc latest*(self: BlockCache): results.Opt[ExecutionPayloadV1] =
  let latestPair = ? self.blocks.last()
  return Opt.some(latestPair.data)

proc getByNumber*(
    self: BlockCache,
    number: Quantity): Opt[ExecutionPayloadV1] =

  var payloadResult: Opt[ExecutionPayloadV1]

  for payload in self.blocks.prevValues:
    if payload.blockNumber == number:
      payloadResult = Opt.some(payload)
      break

  return payloadResult
