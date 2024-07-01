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
  ./backend/[aristo_db, aristo_rocksdb],
  ./base/[api_tracking, base_desc],
  ./base

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
  case mpt.parent.dbType:
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
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
