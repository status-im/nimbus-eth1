# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import eth/common, web3/engine_api_types, web3/execution_types

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

  SimpleQueue[M: static[int], T] = object
    list: array[M, QueueItem[T]]

  PayloadItem = object
    id: PayloadID
    payload: ExecutionPayload
    blockValue: UInt256
    blobsBundle: Opt[BlobsBundleV1]

  HeaderItem = object
    hash: common.Hash256
    header: common.BlockHeader

  PayloadQueue* = object
    payloadQueue: SimpleQueue[MaxTrackedPayloads, PayloadItem]
    headerQueue: SimpleQueue[MaxTrackedHeaders, HeaderItem]

{.push gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template shiftRight[M, T](x: var SimpleQueue[M, T]) =
  x.list[1 ..^ 1] = x.list[0 ..^ 2]

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

proc put*(api: var PayloadQueue, hash: common.Hash256, header: common.BlockHeader) =
  api.headerQueue.put(HeaderItem(hash: hash, header: header))

proc put*(
    api: var PayloadQueue,
    id: PayloadID,
    blockValue: UInt256,
    payload: ExecutionPayload,
    blobsBundle: Opt[BlobsBundleV1],
) =
  api.payloadQueue.put(
    PayloadItem(
      id: id, payload: payload, blockValue: blockValue, blobsBundle: blobsBundle
    )
  )

proc put*(
    api: var PayloadQueue,
    id: PayloadID,
    blockValue: UInt256,
    payload: SomeExecutionPayload,
    blobsBundle: Opt[BlobsBundleV1],
) =
  doAssert blobsBundle.isNone == (payload is ExecutionPayloadV1 | ExecutionPayloadV2)
  api.put(id, blockValue, payload.executionPayload, blobsBundle = blobsBundle)

proc put*(
    api: var PayloadQueue,
    id: PayloadID,
    blockValue: UInt256,
    payload: ExecutionPayloadV1 | ExecutionPayloadV2,
) =
  api.put(id, blockValue, payload, blobsBundle = Opt.none(BlobsBundleV1))

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc get*(
    api: PayloadQueue, hash: common.Hash256, header: var common.BlockHeader
): bool =
  for x in api.headerQueue:
    if x.hash == hash:
      header = x.header
      return true
  false

proc get*(
    api: PayloadQueue,
    id: PayloadID,
    blockValue: var UInt256,
    payload: var ExecutionPayload,
    blobsBundle: var Opt[BlobsBundleV1],
): bool =
  for x in api.payloadQueue:
    if x.id == id:
      payload = x.payload
      blockValue = x.blockValue
      blobsBundle = x.blobsBundle
      return true
  false

proc get*(
    api: PayloadQueue,
    id: PayloadID,
    blockValue: var UInt256,
    payload: var ExecutionPayloadV1,
): bool =
  var
    p: ExecutionPayload
    blobsBundleOpt: Opt[BlobsBundleV1]
  let found = api.get(id, blockValue, p, blobsBundleOpt)
  if found:
    doAssert(p.version == Version.V1)
    payload = p.V1
    doAssert(blobsBundleOpt.isNone)
  return found

proc get*(
    api: PayloadQueue,
    id: PayloadID,
    blockValue: var UInt256,
    payload: var ExecutionPayloadV2,
): bool =
  var
    p: ExecutionPayload
    blobsBundleOpt: Opt[BlobsBundleV1]
  let found = api.get(id, blockValue, p, blobsBundleOpt)
  if found:
    doAssert(p.version == Version.V2)
    payload = p.V2
    doAssert(blobsBundleOpt.isNone)
  return found

proc get*(
    api: PayloadQueue,
    id: PayloadID,
    blockValue: var UInt256,
    payload: var ExecutionPayloadV3,
    blobsBundle: var BlobsBundleV1,
): bool =
  var
    p: ExecutionPayload
    blobsBundleOpt: Opt[BlobsBundleV1]
  let found = api.get(id, blockValue, p, blobsBundleOpt)
  if found:
    doAssert(p.version == Version.V3)
    payload = p.V3
    doAssert(blobsBundleOpt.isSome)
    blobsBundle = blobsBundleOpt.unsafeGet
  return found

proc get*(
    api: PayloadQueue,
    id: PayloadID,
    blockValue: var UInt256,
    payload: var ExecutionPayloadV1OrV2,
): bool =
  var
    p: ExecutionPayload
    blobsBundleOpt: Opt[BlobsBundleV1]
  let found = api.get(id, blockValue, p, blobsBundleOpt)
  if found:
    doAssert(p.version in {Version.V1, Version.V2})
    payload = p.V1V2
    doAssert(blobsBundleOpt.isNone)
  return found
