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
    filter: FilterRef;                 # Filter to revert
      ): Result[FilterRef,(VertexID,AristoError)] =
  ## Assemble reverse filter for the `filter` argument, i.e. changes to the
  ## backend that reverse the effect of applying the this read-only filter.
  ##
  ## This read-only filter is calculated against the current unfiltered
  ## backend (excluding optionally installed read-only filter.)
  ##
  # Register MPT state roots for reverting back
  let rev = FilterRef(src: filter.kMap.getOrVoid(VertexID 1))

  # Get vid generator state on backend
  block:
    let rc = db.getIdgUbe()
    if rc.isOk:
      rev.vGen = rc.value
    elif rc.error != GetIdgNotFound:
      return err((VertexID(0), rc.error))

  # Calculate reverse changes for the `sTab[]` structural table
  for vid in filter.sTab.keys:
    let rc = db.getVtxUbe vid
    if rc.isOk:
      rev.sTab[vid] = rc.value
    elif rc.error == GetVtxNotFound:
      rev.sTab[vid] = VertexRef(nil)
    else:
      return err((vid,rc.error))

  # Calculate reverse changes for the `kMap` sequence.
  for vid in filter.kMap.keys:
    let rc = db.getKeyUbe vid
    if rc.isOk:
      rev.kMap[vid] = rc.value
    elif rc.error == GetKeyNotFound:
      rev.kMap[vid] = VOID_HASH_KEY
    else:
      return err((vid,rc.error))

  ok(rev)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
