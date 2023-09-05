# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/tables,
  results,
  ".."/[aristo_desc, aristo_desc/desc_backend, aristo_get],
  "."/[filter_desc, filter_scheduler]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getLayerStateRoots*(
    db: AristoDbRef;
    layer: LayerRef;
    chunkedMpt: bool;
      ): Result[StateRootPair,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  var spr: StateRootPair

  spr.be = block:
    let rc = db.getKeyBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  block:
    spr.fg = layer.kMap.getOrVoid(VertexID 1).key
    if spr.fg.isValid:
      return ok(spr)

  if chunkedMpt:
    let vid = layer.pAmk.getOrVoid HashLabel(root: VertexID(1), key: spr.be)
    if vid == VertexID(1):
      spr.fg = spr.be
      return ok(spr)

  if layer.sTab.len == 0 and
     layer.kMap.len == 0 and
     layer.pAmk.len == 0:
    return err(FilPrettyPointlessLayer)

  err(FilStateRootMismatch)


proc le*(be: BackendRef; fid: FilterID): QueueID =
  ## This function returns the filter lookup label of type `QueueID` for
  ## the filter item with maximal filter ID `<=` argument `fid`.
  ##
  proc qid2fid(qid: QueueID): FilterID =
      let rc = be.getFilFn qid
      if rc.isErr:
        return FilterID(0)
      rc.value.fid

  if not be.isNil and
     not be.filters.isNil:
    return be.filters.le(fid, qid2fid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
