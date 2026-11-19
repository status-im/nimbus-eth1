# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, strutils],
  chronos,
  beacon_chain/spec/[digest, forks, helpers],
  beacon_chain/spec/eth2_apis/eth2_rest_json_serialization,
  ../engine/types,
  ./types,
  ./utils

{.pragma: exported, cdecl, exportc, dynlib, raises: [].}

proc encodeBeacon(
    cfg: RuntimeConfig, obj: SomeForkedLightClientObject
): Result[string, string] {.raises: [].} =
  withForkyObject(obj):
    when lcDataFork > LightClientDataFork.None:
      try:
        ok(
          "{\"version\":\"" & cfg.consensusForkAtEpoch(forkyObject.contextEpoch).toString() &
            "\",\"data\":" & RestJson.encode(forkyObject) & "}"
        )
      except CatchableError as e:
        err("Light client object couldn't be encoded: " & e.msg)
    else:
      err("Light client object has no data")

proc encodeBeacon(
    cfg: RuntimeConfig, updates: seq[ForkedLightClientUpdate]
): Result[string, string] {.raises: [].} =
  var entries = newSeqOfCap[string](updates.len)
  for update in updates:
    entries.add(?cfg.encodeBeacon(update))
  ok("[" & entries.join(",") & "]")

template beaconCallbackToC(
    ctx: ptr Context, cb: CallBackProc, userData: pointer, asyncCall: untyped
) =
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
          let encoded = ctx.engine.cfg.encodeBeacon(res.get())
          if encoded.isErr():
            (RET_ERROR, encoded.error)
          else:
            (RET_SUCCESS, encoded.get())

    cb(ctx, status, alloc(response), userData)

  if fut.finished:
    sendResult(nil)
  else:
    fut.addCallback sendResult

proc beaconBootstrap(
    ctx: ptr Context, blockRoot: Eth2Digest, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientBootstrap(blockRoot)

proc beaconUpdates(
    ctx: ptr Context,
    startPeriod: SyncCommitteePeriod,
    count: uint64,
    cb: CallBackProc,
    userData: pointer,
) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientUpdatesByRange(startPeriod, count)

proc beaconFinality(ctx: ptr Context, cb: CallBackProc, userData: pointer) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientFinalityUpdate()

proc beaconOptimistic(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.raises: [].} =
  beaconCallbackToC(ctx, cb, userData):
    ctx.beaconFrontend.getLightClientOptimisticUpdate()

proc beaconCall(
    ctx: ptr Context,
    endpoint: cstring,
    params: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  if ctx.beaconFrontend.getLightClientBootstrap.isNil:
    cb(ctx, RET_ERROR, alloc("beacon frontend unavailable"), userData)
    return

  let node =
    try:
      if params.isNil or ($params).len == 0:
        newJObject()
      else:
        parseJson($params)
    except CatchableError as e:
      cb(ctx, RET_DESER_ERROR, alloc(e.msg), userData)
      return

  case $endpoint
  of "getLightClientBootstrap":
    let blockRoot =
      try:
        Eth2Digest.fromHex(node["block_root"].getStr())
      except CatchableError as e:
        cb(ctx, RET_DESER_ERROR, alloc("invalid block_root: " & e.msg), userData)
        return
    beaconBootstrap(ctx, blockRoot, cb, userData)
  of "getLightClientUpdatesByRange":
    let (startPeriod, count) =
      try:
        let
          startNode = node["start_period"]
          countNode = node["count"]
        if startNode.kind != JInt or countNode.kind != JInt or
            startNode.getBiggestInt() < 0 or countNode.getBiggestInt() < 0:
          cb(
            ctx,
            RET_DESER_ERROR,
            alloc("start_period and count must be non-negative integers"),
            userData,
          )
          return
        (
          SyncCommitteePeriod(uint64(startNode.getBiggestInt())),
          uint64(countNode.getBiggestInt()),
        )
      except CatchableError as e:
        cb(ctx, RET_DESER_ERROR, alloc("missing parameter: " & e.msg), userData)
        return
    beaconUpdates(ctx, startPeriod, count, cb, userData)
  of "getLightClientFinalityUpdate":
    beaconFinality(ctx, cb, userData)
  of "getLightClientOptimisticUpdate":
    beaconOptimistic(ctx, cb, userData)
  else:
    cb(ctx, RET_DESER_ERROR, alloc("unknown endpoint"), userData)
