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
  ProvideLegacyAPI = CoreDbProvideLegacyAPI

when ProvideLegacyAPI and CoreDbEnableApiTracking:
  const
    logTxt = "CoreDb/it "
    legaApiTxt = logTxt & "legacy API"
    newApiTxt = logTxt & "API"

# Annotation helper(s)
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator pairs*(kvt: CoreDxKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  ##
  kvt.setTrackNewApi KvtPairsIt
  case kvt.parent.dbType:
  of AristoDbMemory:
    for k,v in kvt.aristoKvtPairsMem():
      yield (k,v)
  of AristoDbVoid:
    for k,v in kvt.aristoKvtPairsVoid():
      yield (k,v)
  else:
    raiseAssert: "Unsupported database type: " & $kvt.parent.dbType
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed

iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) =
  ## Trie traversal, only supported for `CoreDxMptRef` (not `Phk`)
  ##
  mpt.setTrackNewApi MptPairsIt
  case mpt.parent.dbType:
  of AristoDbMemory, AristoDbRocks, AristoDbVoid:
    for k,v in mpt.aristoMptPairs():
      yield (k,v)
  else:
    raiseAssert: "Unsupported database type: " & $mpt.parent.dbType
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, trie

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef` (not `Phk`)
  ##
  mpt.setTrackNewApi MptReplicateIt
  case mpt.parent.dbType:
  of AristoDbMemory:
    for k,v in aristoReplicateMem(mpt):
      yield (k,v)
  of AristoDbVoid:
    for k,v in aristoReplicateVoid(mpt):
      yield (k,v)
  else:
    raiseAssert: "Unsupported database type: " & $mpt.parent.dbType
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, trie

when ProvideLegacyAPI:

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    kvt.setTrackLegaApi LegaKvtPairsIt
    for k,v in kvt.distinctBase.pairs(): yield (k,v)
    kvt.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) =
    ## Trie traversal, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi LegaMptPairsIt
    for k,v in mpt.distinctBase.pairs(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi LegaMptReplicateIt
    for k,v in mpt.distinctBase.replicate(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
