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
  std/[options, tables],
  eth/common,
  results,
  ".."/[aristo_desc, aristo_desc/desc_backend, aristo_get],
  ./filter_scheduler

type
  StateRootPair* = object
    ## Helper structure for analysing state roots.
    be*: Hash256                   ## Backend state root
    fg*: Hash256                   ## Layer or filter implied state root

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getLayerStateRoots*(
    db: AristoDbRef;
    delta: LayerDeltaRef;
    chunkedMpt: bool;
      ): Result[StateRootPair,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  ##
  var spr: StateRootPair

  let sprBeKey = block:
    let rc = db.getKeyBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)
  spr.be = sprBeKey.to(Hash256)

  spr.fg = block:
    let key = delta.kMap.getOrVoid VertexID(1)
    if key.isValid:
      key.to(Hash256)
    else:
      EMPTY_ROOT_HASH
  if spr.fg.isValid:
    return ok(spr)

  if not delta.kMap.hasKey(VertexID(1)) and
     not delta.sTab.hasKey(VertexID(1)):
    # This layer is unusable, need both: vertex and key
    return err(FilPrettyPointlessLayer)
  elif not delta.sTab.getOrVoid(VertexID(1)).isValid:
    # Root key and vertex has been deleted
    return ok(spr)

  if chunkedMpt:
    if sprBeKey == delta.kMap.getOrVoid VertexID(1):
      spr.fg = spr.be
      return ok(spr)

  if delta.sTab.len == 0 and
     delta.kMap.len == 0:
    return err(FilPrettyPointlessLayer)

  err(FilStateRootMismatch)


proc getFilterFromFifo*(
    be: BackendRef;
    fid = none(FilterID);
    earlierOK = false;
      ): Result[FilterIndexPair,AristoError] =
  ## If there is some argument `fid`, find the filter on the journal with ID
  ## not larger than `fid` (i e. the resulting filter must not be more recent.)
  ##
  ## If the argument `earlierOK` is passed `false`, the function succeeds only
  ## if the filter ID of the returned filter is equal to the argument `fid`.
  ##
  ## In case that there is no argument `fid`, the filter with the smallest
  ## filter ID (i.e. the oldest filter) is returned. here, the argument
  ## `earlierOK` is ignored.
  ##
  if be.journal.isNil:
    return err(FilQuSchedDisabled)

  var cache = (QueueID(0),FilterRef(nil))  # Avoids double lookup for last entry
  proc qid2fid(qid: QueueID): Result[FilterID,void] =
    if qid == cache[0]:                    # Avoids double lookup for last entry
      return ok cache[1].fid
    let fil = be.getFilFn(qid).valueOr:
      return err()
    cache = (qid,fil)
    ok fil.fid

  let qid = block:
    if fid.isNone:
      # Get oldest filter
      be.journal[^1]
    else:
      # Find filter with ID not smaller than `fid`
      be.journal.le(fid.unsafeGet, qid2fid, forceEQ = not earlierOK)

  if not qid.isValid:
    return err(FilFilterNotFound)

  var fip = FilterIndexPair()
  fip.fil = block:
    if cache[0] == qid:
      cache[1]
    else:
      be.getFilFn(qid).valueOr:
        return err(error)

  fip.inx = be.journal[qid]
  if fip.inx < 0:
    return err(FilInxByQidFailed)

  ok fip


proc getFilterOverlap*(
    be: BackendRef;
    filter: FilterRef;
      ): int =
  ## Return the number of journal filters in the leading chain that is
  ## reverted by the argument `filter`. A heuristc approach is used here
  ## for an argument `filter` with a valid filter ID when the chain is
  ## longer than one items. Only single step filter overlaps are guaranteed
  ## to be found.
  ##
  # Check against the top-fifo entry.
  let qid = be.journal[0]
  if not qid.isValid:
    return 0

  let top = be.getFilFn(qid).valueOr:
    return 0

  # The `filter` must match the `top`
  if filter.src != top.src:
    return 0

  # Does the filter revert the fitst entry?
  if filter.trg == top.trg:
    return 1

  # Check against some stored filter IDs
  if filter.isValid:
    let fp = be.getFilterFromFifo(some(filter.fid), earlierOK=true).valueOr:
      return 0
    if filter.trg == fp.fil.trg:
      return 1 + fp.inx

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
