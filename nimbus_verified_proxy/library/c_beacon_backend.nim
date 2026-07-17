# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  chronos,
  beacon_chain/spec/digest,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/forks,
  beacon_chain/spec/eth2_apis/eth2_rest_json_serialization,
  ../engine/types,
  ./types

proc newBeaconTransportCtx*(url, endpoint, params: string): TransportBeaconContext =
  TransportBeaconContext(
    url: url, endpoint: endpoint, params: params, fut: newFuture[string]()
  )

proc deliverBeaconTransport*(
    status: cint, res: cstring, userData: pointer
) {.cdecl, exportc, gcsafe, raises: [].} =
  let tctx = cast[TransportBeaconContext](userData)
  let response =
    if res != nil:
      $res
    else:
      ""
  if status == RET_CANCELLED:
    tctx.fut.cancelSoon()
  elif status == RET_SUCCESS:
    tctx.fut.complete(response)
  else:
    tctx.fut.fail(newException(CatchableError, response))

proc beaconCtxUrl*(userData: pointer): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportBeaconContext](userData).url.cstring

proc beaconCtxEndpoint*(
    userData: pointer
): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportBeaconContext](userData).endpoint.cstring

proc beaconCtxParams*(
    userData: pointer
): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportBeaconContext](userData).params.cstring

proc getBeaconApiBackend*(
    ctx: ptr Context, url: string, transportProc: BeaconTransportProc
): BeaconApiBackend =
  let
    bootstrapProc = proc(
        blockRoot: Eth2Digest
    ): Future[EngineResult[ForkedLightClientBootstrap]] {.
        async: (raises: [CancelledError])
    .} =
      let tctx = newBeaconTransportCtx(
        url, "getLightClientBootstrap", "{\"block_root\": \"" & $blockRoot & "\"}"
      )
      transportProc(ctx, deliverBeaconTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))
      try:
        return ok(
          RestJson.decode(raw, ForkedLightClientBootstrap, allowUnknownFields = true)
        )
      except SerializationError as e:
        return err((BackendDecodingError, e.msg, UNTAGGED))

    updatesProc = proc(
        startPeriod: SyncCommitteePeriod, count: uint64
    ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
        async: (raises: [CancelledError])
    .} =
      let tctx = newBeaconTransportCtx(
        url,
        "getLightClientUpdatesByRange",
        "{\"start_period\": " & $startPeriod.uint64 & ", \"count\": " & $count & "}",
      )
      transportProc(ctx, deliverBeaconTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))
      try:
        return ok(
          RestJson.decode(raw, seq[ForkedLightClientUpdate], allowUnknownFields = true)
        )
      except SerializationError as e:
        return err((BackendDecodingError, e.msg, UNTAGGED))

    optimisticProc = proc(): Future[EngineResult[ForkedLightClientOptimisticUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let tctx = newBeaconTransportCtx(url, "getLightClientOptimisticUpdate", "{}")
      transportProc(ctx, deliverBeaconTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))
      try:
        return ok(
          RestJson.decode(
            raw, ForkedLightClientOptimisticUpdate, allowUnknownFields = true
          )
        )
      except SerializationError as e:
        return err((BackendDecodingError, e.msg, UNTAGGED))

    finalityProc = proc(): Future[EngineResult[ForkedLightClientFinalityUpdate]] {.
        async: (raises: [CancelledError])
    .} =
      let tctx = newBeaconTransportCtx(url, "getLightClientFinalityUpdate", "{}")
      transportProc(ctx, deliverBeaconTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))
      try:
        return ok(
          RestJson.decode(
            raw, ForkedLightClientFinalityUpdate, allowUnknownFields = true
          )
        )
      except SerializationError as e:
        return err((BackendDecodingError, e.msg, UNTAGGED))

  BeaconApiBackend(
    getLightClientBootstrap: bootstrapProc,
    getLightClientUpdatesByRange: updatesProc,
    getLightClientOptimisticUpdate: optimisticProc,
    getLightClientFinalityUpdate: finalityProc,
  )
