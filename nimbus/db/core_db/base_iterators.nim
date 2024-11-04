# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  eth/common,
  ../../errors,
  ../aristo as use_ari,
  ../kvt as use_kvt,
  ../kvt/[kvt_init/memory_only, kvt_walk],
  ./base/[api_tracking, base_config, base_desc]

when CoreDbEnableApiJumpTable:
  discard
else:
  import
    ../aristo/[aristo_desc, aristo_path],
    ../kvt/[kvt_desc, kvt_tx]

when CoreDbEnableApiTracking:
  import
    chronicles
  logScope:
    topics = "core_db"
  const
    logTxt = "API"

# Annotation helper(s)
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

template valueOrApiError[U,V](rc: Result[U,V]; info: static[string]): U =
  rc.valueOr: raise (ref CoreDbApiError)(msg: info)

template dbType(dsc: CoreDbKvtRef | CoreDbAccRef): CoreDbType =
  dsc.distinctBase.parent.dbType

# ---------------

template kvt(dsc: CoreDbKvtRef): KvtDbRef =
  dsc.distinctBase.kvt

template call(api: KvtApiRef; fn: untyped; args: varargs[untyped]): untyped =
  when CoreDbEnableApiJumpTable:
    api.fn(args)
  else:
    fn(args)

template call(kvt: CoreDbKvtRef; fn: untyped; args: varargs[untyped]): untyped =
  kvt.distinctBase.parent.kvtApi.call(fn, args)

# ---------------

template mpt(dsc: CoreDbAccRef): AristoDbRef =
  dsc.distinctBase.mpt

template call(api: AristoApiRef; fn: untyped; args: varargs[untyped]): untyped =
  when CoreDbEnableApiJumpTable:
    api.fn(args)
  else:
    fn(args)

template call(
    acc: CoreDbAccRef;
    fn: untyped;
    args: varargs[untyped];
      ): untyped =
  acc.distinctBase.parent.ariApi.call(fn, args)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator pairs*(kvt: CoreDbKvtRef): (seq[byte], seq[byte]) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  ##
  kvt.setTrackNewApi KvtPairsIt
  case kvt.dbType:
  of AristoDbMemory:
    let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "kvt/pairs()"
    defer: discard kvt.call(forget, p)
    for (k,v) in use_kvt.MemBackendRef.walkPairs p:
      yield (k,v)
  of AristoDbVoid:
    let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "kvt/pairs()"
    defer: discard kvt.call(forget, p)
    for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
      yield (k,v)
  of Ooops, AristoDbRocks:
    raiseAssert: "Unsupported database type: " & $kvt.dbType
  kvt.ifTrackNewApi: debug logTxt, api, elapsed

iterator slotPairs*(acc: CoreDbAccRef; accPath: Hash32): (seq[byte], UInt256) =
  acc.setTrackNewApi AccSlotPairsIt
  case acc.dbType:
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for (path,data) in acc.mpt.rightPairsStorage accPath:
      yield (acc.call(pathAsBlob, path), data)
  of Ooops:
    raiseAssert: "Unsupported database type: " & $acc.dbType
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
