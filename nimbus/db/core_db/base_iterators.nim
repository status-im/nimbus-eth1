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
  ./backend/aristo_db,
  ./base/[api_tracking, base_desc],
  ./base

when CoreDbEnableApiTracking:
  import chronicles

  const
    logTxt = "CoreDb/it "
    newApiTxt = logTxt & "API"

# Annotation helper(s)
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  ##
  kvt.setTrackNewApi KvtPairsIt
  case kvt.distinctBase.parent.dbType:
  of AristoDbMemory:
    for k,v in kvt.aristoKvtPairsMem():
      yield (k,v)
  of AristoDbVoid:
    for k,v in kvt.aristoKvtPairsVoid():
      yield (k,v)
  of Ooops, AristoDbRocks:
    raiseAssert: "Unsupported database type: " & $kvt.distinctBase.parent.dbType
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed

iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) =
  ## Trie traversal, only supported for `CoreDbMptRef`
  ##
  mpt.setTrackNewApi MptPairsIt
  case mpt.distinctBase.parent.dbType:
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for k,v in mpt.aristoMptPairs():
      yield (k,v)
  of Ooops:
    raiseAssert: "Unsupported database type: " & $mpt.distinctBase.parent.dbType
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

iterator slotPairs*(acc: CoreDbAccRef; accPath: Hash256): (Blob, Blob) =
  ## Trie traversal, only supported for `CoreDbMptRef`
  ##
  acc.setTrackNewApi AccSlotPairsIt
  case acc.distinctBase.parent.dbType:
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for k,v in acc.aristoSlotPairs accPath:
      yield (k,v)
  of Ooops:
    raiseAssert: "Unsupported database type: " & $acc.distinctBase.parent.dbType
  acc.ifTrackNewApi:
    doAssert accPath.len == 32
    debug newApiTxt, api, elapsed

iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for non persistent `CoreDbMptRef`
  ##
  mpt.setTrackNewApi MptReplicateIt
  case mpt.distinctBase.parent.dbType:
  of AristoDbMemory:
    for k,v in aristoReplicateMem(mpt):
      yield (k,v)
  of AristoDbVoid:
    for k,v in aristoReplicateVoid(mpt):
      yield (k,v)
  of Ooops, AristoDbRocks:
    raiseAssert: "Unsupported database type: " & $mpt.distinctBase.parent.dbType
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
