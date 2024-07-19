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
  ../aristo/[aristo_walk, aristo_serialise],
  ../kvt as use_kvt,
  ../kvt/[kvt_init/memory_only, kvt_walk],
  ./base/[api_tracking, base_config, base_desc]

when CoreDbEnableApiJumpTable:
  discard
else:
  import ../aristo/[aristo_desc, aristo_path, aristo_tx], ../kvt/[kvt_desc, kvt_tx]

include ./backend/aristo_replicate

when CoreDbEnableApiTracking:
  import chronicles
  logScope:
    topics = "core_db"
  const logTxt = "API"

# Annotation helper(s)
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  ##
  kvt.setTrackNewApi KvtPairsIt
  case kvt.dbType
  of AristoDbMemory:
    let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "kvt/pairs()"
    defer:
      discard kvt.call(forget, p)
    for (k, v) in use_kvt.MemBackendRef.walkPairs p:
      yield (k, v)
  of AristoDbVoid:
    let p = kvt.call(forkTx, kvt.kvt, 0).valueOrApiError "kvt/pairs()"
    defer:
      discard kvt.call(forget, p)
    for (k, v) in use_kvt.VoidBackendRef.walkPairs p:
      yield (k, v)
  of Ooops, AristoDbRocks:
    raiseAssert:
      "Unsupported database type: " & $kvt.dbType
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed

iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) =
  ## Trie traversal, only supported for `CoreDbMptRef`
  ##
  mpt.setTrackNewApi MptPairsIt
  case mpt.dbType
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for (path, data) in mpt.mpt.rightPairsGeneric CoreDbVidGeneric:
      yield (mpt.call(pathAsBlob, path), data)
  of Ooops:
    raiseAssert:
      "Unsupported database type: " & $mpt.dbType
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed

iterator slotPairs*(acc: CoreDbAccRef, accPath: Hash256): (Blob, UInt256) =
  ## Trie traversal, only supported for `CoreDbMptRef`
  ##
  acc.setTrackNewApi AccSlotPairsIt
  case acc.dbType
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for (path, data) in acc.mpt.rightPairsStorage accPath:
      yield (acc.call(pathAsBlob, path), data)
  of Ooops:
    raiseAssert:
      "Unsupported database type: " & $acc.dbType
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed

iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for non persistent `CoreDbMptRef`
  ##
  mpt.setTrackNewApi MptReplicateIt
  case mpt.dbType
  of AristoDbMemory:
    for k, v in aristoReplicate[use_ari.MemBackendRef](mpt):
      yield (k, v)
  of AristoDbVoid:
    for k, v in aristoReplicate[use_ari.VoidBackendRef](mpt):
      yield (k, v)
  of Ooops, AristoDbRocks:
    raiseAssert:
      "Unsupported database type: " & $mpt.dbType
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
