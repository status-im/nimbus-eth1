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
  ./backend/[aristo_db, aristo_rocksdb, legacy_db],
  ./base/[api_tracking, base_desc],
  ./base

when CoreDbEnableApiTracking:
  import chronicles

const
  ProvideLegacyAPI = CoreDbProvideLegacyAPI

when ProvideLegacyAPI and CoreDbEnableApiTracking:
  const
    logTxt = "CoreDb/itp "
    legaApiTxt = logTxt & "legacy API"
    newApiTxt = logTxt & "API"

# Annotation helper(s)
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError, LegacyApiRlpError].}

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator replicatePersistent*(mpt: CoreDxMptRef): (Blob, Blob) {.rlpRaise.} =
  ## Extended version of `replicate()` for `Aristo` persistent backend.
  ##
  mpt.setTrackNewApi MptReplicateIt
  case mpt.parent.dbType:
  of LegacyDbMemory, LegacyDbPersistent:
    for k,v in mpt.legaReplicate():
      yield (k,v)
  of AristoDbMemory:
    for k,v in aristoReplicateMem(mpt):
      yield (k,v)
  of AristoDbVoid:
    for k,v in aristoReplicateVoid(mpt):
      yield (k,v)
  of AristoDbRocks:
    for k,v in aristoReplicateRdb(mpt):
      yield (k,v)
  else:
    raiseAssert: "Unsupported database type: " & $mpt.parent.dbType
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie

when ProvideLegacyAPI:

  iterator replicatePersistent*(mpt: CoreDbMptRef): (Blob, Blob) {.rlpRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi LegaMptReplicateIt
    for k,v in mpt.distinctBase.replicatePersistent(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
