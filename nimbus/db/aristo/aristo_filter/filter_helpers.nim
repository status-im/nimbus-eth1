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
  ./filter_scheduler

type
  StateRootPair* = object
    ## Helper structure for analysing state roots.
    be*: HashKey                   ## Backend state root
    fg*: HashKey                   ## Layer or filter implied state root

  FilterIndexPair* = object
    ## Helper structure for fetching filters from cascaded fifo
    inx*: int                      ## Non negative fifo index
    fil*: FilterRef                ## Valid filter

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
  ##
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


proc getFilterFromFifo*(
    be: BackendRef;
    fid: FilterID;
    earlierOK = false;
      ): Result[FilterIndexPair,AristoError] =
  ## Find filter on cascaded fifos and return its index and filter ID.
  ##
  var cache = (QueueID(0),FilterRef(nil))  # Avoids double lookup for last entry
  proc qid2fid(qid: QueueID): FilterID =
    if qid == cache[0]:                    # Avoids double lookup for last entry
      return cache[1].fid
    let rc = be.getFilFn qid
    if rc.isErr:
      return FilterID(0)
    cache = (qid,rc.value)
    rc.value.fid

  if be.filters.isNil:
    return err(FilQuSchedDisabled)

  let qid = be.filters.le(fid, qid2fid, forceEQ = not earlierOK)
  if not qid.isValid:
    return err(FilFilterNotFound)

  var fip = FilterIndexPair()
  fip.fil = block:
    if cache[0] == qid:
      cache[1]
    else:
      let rc = be.getFilFn qid
      if rc.isErr:
        return err(rc.error)
      rc.value

  fip.inx = be.filters[qid]
  if fip.inx < 0:
    return err(FilInxByQidFailed)

  ok fip


proc getFilterOverlap*(
    be: BackendRef;
    filter: FilterRef;
      ): int =
  ## Return the number of filters in the leading chain that is reverted by the
  ## argument `filter`. A heuristc approach is used here for an argument
  ## `filter` with a valid filter ID when the chain is longer than one items.
  ## So only single chain overlaps a guaranteed to be found.
  ##
  # Check against the top-fifo entry
  let qid = be.filters[0]
  if not qid.isValid:
    return 0
  let top = block:
    let rc = be.getFilFn qid
    if rc.isErr:
      return 0
    rc.value

  # The `filter` must match the `top`
  if filter.src != top.src:
    return 0

  # Does the filter revert the fitst entry?
  if filter.trg == top.trg:
    return 1

  # Check against sme stored filter IDs
  if filter.isValid:
    let rc = be.getFilterFromFifo(filter.fid, earlierOK=true)
    if rc.isOk:
      if filter.trg == rc.value.fil.trg:
        return 1 + rc.value.inx

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
