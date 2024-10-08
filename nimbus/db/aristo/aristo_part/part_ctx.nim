# nimbus-eth1
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
  std/sets,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_hike, aristo_layers, aristo_utils],
  #./part_debug,
  ./part_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc newCtx(ps: PartStateRef; hike: Hike): Result[PartStateCtx,AristoError]  =
  ## ..
  doAssert 0 <= hike.legs[^1].nibble

  let
    wp = hike.legs[^1].wp
    nibble = hike.legs[^1].nibble
    fromVid = wp.vtx.bVid[nibble]

  if not ps.isPerimeter(fromVid) or ps.isExtension(fromVid):
    return err(PartCtxNotAvailable)

  let
    vtx2 = wp.vtx.dup
    psc = PartStateCtx(
      ps:       ps,
      location: (hike.root,wp.vid),
      nibble:   nibble,
      fromVid:  fromVid)

  # Update database so that is space for adding a new sub-tree here
  vtx2.bVid[nibble] = VertexID(0)
  ps.db.layersPutVtx(psc.location,vtx2)
  ok psc

proc removedCompletedNode(
    ps: PartStateRef;
    rvid: RootedVertexID;
    key: HashKey;
      ): bool =
  let vtx = ps.db.getVtx rvid
  if vtx.isNil:
    return false

  var subVids: seq[VertexID]
  for vid in vtx.subVids():
    # Only accept perimeter nodes with all links on the database (i.e. links
    # must nor refere t a core node.)
    if not ps.db.getVtx((rvid.root, vid)).isValid or ps.isCore(vid):
      return false # not complete
    subVids.add vid

  # No need to keep that core vertex any longer
  ps.delCore(rvid.root, key)
  for vid in subVids:
    ps.del vid

  true

proc removeCompletedNodes(ps: PartStateRef; rvid: RootedVertexID) =
  let key = ps[rvid.vid]
  if ps.removedCompletedNode(rvid, key):
    # Rather stupid loop to clear additional nodes. Note that the set
    # of core nodes is assumed to be small, i.e. not more than a hand full.
    while true:
      ps.core.withValue(rvid.root, coreKeys):
        block removeItem:
          for cKey in coreKeys[]:
            let rv = ps[cKey]
            if ps.removedCompletedNode(rv, cKey):
              break removeItem # continue `while`
          return               # done
      do: return               # done

# -------------------

proc ctxAcceptChange(psc: PartStateCtx): Result[bool,AristoError] =
  ## Apply `psc` context if there was a change on the targeted vertex,
  ## otherwise restore. Returns `true` exactly if there was a change on
  ## the database which could be applied.
  ##
  let
    ps = psc.ps
    db = ps.db
    (vtx,_) = ? db.getVtxRc psc.location
    toVid = vtx.bVid[psc.nibble]

  if not toVid.isValid:
    # Nothing changed, so restore
    let vtx2 = vtx.dup
    vtx2.bVid[psc.nibble] = psc.fromVid
    db.layersPutVtx(psc.location, vtx2)
    ok(false)

  elif toVid != psc.fromVid:
    # Replace `fromVid` by `toVid` in state descriptor `ps`
    let key = ps.move(psc.fromVid, toVid)
    doAssert key.isValid
    ps.changed.incl key

    # Remove parent vertex it it has become complete.
    ps.removeCompletedNodes(psc.location)
    ok(true)

  else:
    ok(false)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc ctxMergeBegin*(
    ps: PartStateRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[PartStateCtx,AristoError] =
  ## This function clears the way for mering some payload at the argument
  ## path `(root,path)`.
  var hike: Hike
  path.hikeUp(root,ps.db, Opt.none(VertexRef), hike).isOkOr:
    if error[1] != HikeDanglingEdge:
      return err error[1] # Cannot help here
    return ps.newCtx hike

  ok PartStateCtx(nil) # Nothing to do

proc ctxMergeBegin*(
    ps: PartStateRef;
    accPath: Hash32;
      ): Result[PartStateCtx,AristoError] =
  ## Variant of `partMergeBegin()` for different path representation
  ps.ctxMergeBegin(VertexID(1), accPath.data)


proc ctxMergeCommit*(psc: PartStateCtx): Result[bool,AristoError] =
  ##
  if psc.isNil:
    return ok(false) # Nothing to do
  if psc.ps.isNil:
    return err(PartCtxStaleDescriptor)

  let yn = ? psc.ctxAcceptChange()
  psc[].reset
  ok(yn)


proc ctxMergeRollback*(psc: PartStateCtx): Result[void,AristoError] =
  ## ..
  if psc.isNil:
    return ok() # Nothing to do
  if psc.ps.isNil:
    return err(PartCtxStaleDescriptor)

  let yn = ? psc.ctxAcceptChange()
  psc[].reset
  if yn: err(PartVtxSlotWasModified) else: ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
