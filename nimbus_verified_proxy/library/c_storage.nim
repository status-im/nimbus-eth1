# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronos,
  beacon_chain/spec/forks,
  beacon_chain/spec/eth2_ssz_serialization,
  ../engine/types,
  ./types

const
  checkpointKey* = "lc_checkpoint"
  syncCommitteeLen = fixedPortionSize(altair.SyncCommittee)

proc encodeCheckpoint*(cp: LightClientCheckpoint): seq[byte] =
  withForkyHeader(cp.header):
    when lcDataFork > LightClientDataFork.None:
      @[byte(ord(lcDataFork))] & SSZ.encode(cp.syncCommittee) & SSZ.encode(forkyHeader)
    else:
      @[]

proc decodeCheckpoint*(data: openArray[byte]): Result[LightClientCheckpoint, string] =
  if data.len < 1 + syncCommitteeLen:
    return err("checkpoint too short")

  let kind = int(data[0])
  try:
    let syncCommittee =
      SSZ.decode(data.toOpenArray(1, syncCommitteeLen), altair.SyncCommittee)
    withAll(LightClientDataFork):
      when lcDataFork > LightClientDataFork.None:
        if kind == ord(lcDataFork):
          let header = SSZ.decode(
            data.toOpenArray(1 + syncCommitteeLen, data.high),
            lcDataFork.LightClientHeader,
          )
          return ok(
            LightClientCheckpoint(
              header: ForkedLightClientHeader.init(header), syncCommittee: syncCommittee
            )
          )
    err("unsupported checkpoint fork kind " & $kind)
  except SerializationError as e:
    err("corrupted checkpoint: " & e.msg)

proc deliverStorage*(
    status: cint, data: ptr UncheckedArray[byte], len: cint, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let sctx = cast[StorageContext](userData)
  var bytes: seq[byte]
  if data != nil and len > 0:
    bytes = @(data.toOpenArray(0, len - 1))
  if status == RET_CANCELLED:
    sctx.fut.cancelSoon()
  else:
    sctx.fut.complete((status, bytes))

proc getLightClientStorage*(
    ctx: ptr Context, getProc: StorageGetProc, putProc: StoragePutProc
): LightClientStorage =
  let
    loadProc = proc(): Future[EngineResult[Opt[LightClientCheckpoint]]] {.
        async: (raises: [CancelledError])
    .} =
      let sctx = StorageContext(fut: newFuture[(cint, seq[byte])]())
      getProc(ctx, checkpointKey.cstring, deliverStorage, cast[pointer](sctx))
      let (status, bytes) =
        try:
          await sctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))

      if status == RET_NOT_FOUND:
        return ok(Opt.none(LightClientCheckpoint))
      if status != RET_SUCCESS:
        return err((BackendFetchError, "storage get failed", UNTAGGED))

      let cp = decodeCheckpoint(bytes).valueOr:
        return err((BackendDecodingError, error, UNTAGGED))
      ok(Opt.some(cp))

    saveProc = proc(
        cp: LightClientCheckpoint
    ): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
      var bytes = encodeCheckpoint(cp)
      if bytes.len == 0:
        return err((BackendEncodingError, "cannot store an empty LC header", UNTAGGED))

      let sctx = StorageContext(fut: newFuture[(cint, seq[byte])]())
      putProc(
        ctx,
        checkpointKey.cstring,
        cast[ptr UncheckedArray[byte]](addr bytes[0]),
        cint(bytes.len),
        deliverStorage,
        cast[pointer](sctx),
      )
      let (status, _) =
        try:
          await sctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendFetchError, e.msg, UNTAGGED))

      if status != RET_SUCCESS:
        return err((BackendFetchError, "storage put failed", UNTAGGED))
      ok()

  LightClientStorage(load: loadProc, save: saveProc)
