# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common,
  web3/engine_api_types,
  ./execution_types

const
  # maxTrackedPayloads is the maximum number of prepared payloads the execution
  # engine tracks before evicting old ones. Ideally we should only ever track
  # the latest one; but have a slight wiggle room for non-ideal conditions.
  MaxTrackedPayloads = 10

  # maxTrackedHeaders is the maximum number of executed payloads the execution
  # engine tracks before evicting old ones. Ideally we should only ever track
  # the latest one; but have a slight wiggle room for non-ideal conditions.
  MaxTrackedHeaders = 96

type
  QueueItem[T] = object
    used: bool
    data: T

  SimpleQueue[M: static[int]; T] = object
    list: array[M, QueueItem[T]]

  PayloadItem = object
    id: PayloadID
    payload: ExecutionPayload
    blockValue: UInt256

  HeaderItem = object
    hash: common.Hash256
    header: common.BlockHeader

  PayloadQueue* = object
    payloadQueue: SimpleQueue[MaxTrackedPayloads, PayloadItem]
    headerQueue: SimpleQueue[MaxTrackedHeaders, HeaderItem]

{.push gcsafe, raises:[].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template shiftRight[M, T](x: var SimpleQueue[M, T]) =
  x.list[1..^1] = x.list[0..^2]

proc put[M, T](x: var SimpleQueue[M, T], val: T) =
  x.shiftRight()
  x.list[0] = QueueItem[T](used: true, data: val)

iterator items[M, T](x: SimpleQueue[M, T]): T =
  for z in x.list:
    if z.used:
      yield z.data

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc put*(api: var PayloadQueue,
          hash: common.Hash256, header: common.BlockHeader) =
  api.headerQueue.put(HeaderItem(hash: hash, header: header))

proc put*(api: var PayloadQueue, id: PayloadID,
          blockValue: UInt256, payload: ExecutionPayload) =
  api.payloadQueue.put(PayloadItem(id: id,
    payload: payload, blockValue: blockValue))

proc put*(api: var PayloadQueue, id: PayloadID,
          blockValue: UInt256, payload: SomeExecutionPayload) =
  api.put(id, blockValue, payload.executionPayload)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc get*(api: PayloadQueue, hash: common.Hash256,
          header: var common.BlockHeader): bool =
  for x in api.headerQueue:
    if x.hash == hash:
      header = x.header
      return true
  false

proc get*(api: PayloadQueue, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayload): bool =
  for x in api.payloadQueue:
    if x.id == id:
      payload = x.payload
      blockValue = x.blockValue
      return true
  false

proc get*(api: PayloadQueue, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV1): bool =
  var p: ExecutionPayload
  let found = api.get(id, blockValue, p)
  doAssert(p.version == Version.V1)
  payload = p.V1
  return found

proc get*(api: PayloadQueue, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV2): bool =
  var p: ExecutionPayload
  let found = api.get(id, blockValue, p)
  doAssert(p.version == Version.V2)
  payload = p.V2
  return found

proc get*(api: PayloadQueue, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV3): bool =
  var p: ExecutionPayload
  let found = api.get(id, blockValue, p)
  doAssert(p.version == Version.V3)
  payload = p.V3
  return found

proc get*(api: PayloadQueue, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV1OrV2): bool =
  var p: ExecutionPayload
  let found = api.get(id, blockValue, p)
  doAssert(p.version in {Version.V1, Version.V2})
  payload = p.V1V2
  return found
