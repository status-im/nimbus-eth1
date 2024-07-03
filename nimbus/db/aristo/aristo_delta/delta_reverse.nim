# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/tables,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc revFilter*(
    db: AristoDbRef;                   # Database
    filter: LayerDeltaRef;             # Filter to revert
      ): Result[LayerDeltaRef,(VertexID,AristoError)] =
  ## Assemble reverse filter for the `filter` argument, i.e. changes to the
  ## backend that reverse the effect of applying the this read-only filter.
  ##
  ## This read-only filter is calculated against the current unfiltered
  ## backend (excluding optionally installed read-only filter.)
  ##
  # Register MPT state roots for reverting back
  let rev = LayerDeltaRef()

  # Get vid generator state on backend
  block:
    let rc = db.getTuvUbe()
    if rc.isOk:
      rev.vTop = rc.value
    elif rc.error != GetTuvNotFound:
      return err((VertexID(0), rc.error))

  # Calculate reverse changes for the `sTab[]` structural table
  for rvid in filter.sTab.keys:
    let rc = db.getVtxUbe rvid
    if rc.isOk:
      rev.sTab[rvid] = rc.value
    elif rc.error == GetVtxNotFound:
      rev.sTab[rvid] = VertexRef(nil)
    else:
      return err((rvid.vid,rc.error))

  # Calculate reverse changes for the `kMap` sequence.
  for rvid in filter.kMap.keys:
    let rc = db.getKeyUbe rvid
    if rc.isOk:
      rev.kMap[rvid] = rc.value
    elif rc.error == GetKeyNotFound:
      rev.kMap[rvid] = VOID_HASH_KEY
    else:
      return err((rvid.vid,rc.error))

  ok(rev)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
