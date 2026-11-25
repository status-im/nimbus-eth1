# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, strutils],
  chronos,
  beacon_chain/spec/[digest, forks],
  ../engine/[types, beacon_frontend],
  ./types,
  ./utils

proc encodeBeacon(
    engine: RpcVerificationEngine, obj: SomeForkedLightClientObject
): Result[string, string] {.raises: [].} =
  let versioned = engine.versioned(obj).valueOr:
    return err("Light client object has no data")
  ok(RestApiResponse.prepareJsonStringResponse(versioned))

proc encodeBeacon(
    engine: RpcVerificationEngine, updates: seq[ForkedLightClientUpdate]
): Result[string, string] {.raises: [].} =
  var entries: seq[string]
  for versioned in engine.versioned(updates):
    entries.add(RestApiResponse.prepareJsonStringResponse(versioned))
  ok("[" & entries.join(",") & "]")

template beaconCallbackToC(
    ctx: ptr Context, cb: CallBackProc, userData: pointer, asyncCall: untyped
) =
  if ctx.beaconFrontend.getLightClientBootstrap.isNil:
    cb(ctx, RET_ERROR, alloc("beacon frontend unavailable"), userData)
    return

  inc ctx.pendingCalls
  let fut = asyncCall

  proc sendResult(_: pointer) {.gcsafe.} =
    dec ctx.pendingCalls
    let (status, response) =
      if fut.cancelled():
        (RET_CANCELLED, escapeJson(fut.error().msg))
      elif fut.failed():
        (RET_ERROR, escapeJson(fut.error().msg))
      else:
        let res = fut.value()
        if res.isErr():
          (RET_ERROR, $res.error.errType & ": " & res.error.errMsg)
        else:
          let encoded = ctx.engine.encodeBeacon(res.get())
          if encoded.isErr():
            (RET_ERROR, encoded.error)
          else:
            (RET_SUCCESS, encoded.get())

    cb(ctx, status, alloc(response), userData)

  if fut.finished:
    sendResult(nil)
  else:
    fut.addCallback sendResult

proc beaconBootstrap*(
    ctx: ptr Context, params: JsonNode, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  let rootNode = params{"block_root"}
  if rootNode.isNil or rootNode.kind != JString:
    cb(ctx, RET_DESER_ERROR, alloc("block_root must be a hex string"), userData)
    return
  let blockRoot =
    try:
      Eth2Digest.strictParse(rootNode.getStr())
    except CatchableError as e:
      cb(ctx, RET_DESER_ERROR, alloc("invalid block_root: " & e.msg), userData)
      return

  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientBootstrap(blockRoot)

proc beaconUpdates*(
    ctx: ptr Context, params: JsonNode, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  let
    startNode = params{"start_period"}
    countNode = params{"count"}
  if startNode.isNil or countNode.isNil or startNode.kind != JInt or
      countNode.kind != JInt or startNode.getBiggestInt() < 0 or
      countNode.getBiggestInt() < 0:
    cb(
      ctx,
      RET_DESER_ERROR,
      alloc("start_period and count must be non-negative integers"),
      userData,
    )
    return
  let
    startPeriod = SyncCommitteePeriod(uint64(startNode.getBiggestInt()))
    count = uint64(countNode.getBiggestInt())

  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientUpdatesByRange(startPeriod, count)

proc beaconFinality*(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientFinalityUpdate()

proc beaconOptimistic*(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientOptimisticUpdate()
