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
  ../aristo as use_ari,
  ../aristo/aristo_init/rocks_db,
  ../aristo/[aristo_desc, aristo_walk/persistent, aristo_tx],
  ../kvt, # needed for `aristo_replicate`
  ./base/[api_tracking, base_desc],
  ./base

include
  ./backend/aristo_replicate

when CoreDbEnableApiTracking:
  import chronicles

  const
    logTxt = "CoreDb/itp "
    newApiTxt = logTxt & "API"

# Annotation helper(s)
{.pragma: rlpRaise, gcsafe, raises: [CoreDbApiError].}

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator replicatePersistent*(mpt: CoreDbMptRef): (Blob, Blob) {.rlpRaise.} =
  ## Extended version of `replicate()` for `Aristo` persistent backend.
  ##
  mpt.setTrackNewApi MptReplicateIt
  case mpt.dbType:
  of AristoDbMemory:
    for k,v in aristoReplicate[use_ari.MemBackendRef](mpt):
      yield (k,v)
  of AristoDbVoid:
    for k,v in aristoReplicate[use_ari.VoidBackendRef](mpt):
      yield (k,v)
  of AristoDbRocks:
    for k, v in aristoReplicate[rocks_db.RdbBackendRef](mpt):
      yield (k, v)
  else:
    raiseAssert: "Unsupported database type: " & $mpt.dbType
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
