# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common/hashes,
  results,
  "."/[aristo_desc, aristo_get]

const
  HikeAcceptableStopsNotFound* = {
      HikeBranchTailEmpty,
      HikeBranchMissingEdge,
      HikeLeafUnexpected,
      HikeNoLegs}
    ## When trying to find a leaf vertex the Patricia tree, there are several
    ## conditions where the search stops which do not constitute a problem
    ## with the trie (aka sysetm error.)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func getNibblesImpl(hike: Hike; start = 0; maxLen = high(int)): NibblesBuf =
  ## May be needed for partial rebuild, as well
  for n in start ..< min(hike.legs.len, maxLen):
    let leg = hike.legs[n]
    case leg.wp.vtx.vType:
    of Branch:
      result = result & NibblesBuf.nibble(leg.nibble.byte)
    of ExtBranch:
      let vtx = ExtBranchRef(leg.wp.vtx)
      result = result & vtx.pfx & NibblesBuf.nibble(leg.nibble.byte)
    of Leaves:
      let vtx = LeafRef(leg.wp.vtx)
      result = result & vtx.pfx

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(rc: Result[Hike,(VertexID,AristoError,Hike)]; T: type Hike): T =
  ## Extract `Hike` from either ok ot error part of argument `rc`.
  if rc.isOk: rc.value else: rc.error[2]

func legsTo*(hike: Hike; T: type NibblesBuf): T =
  ## Convert back
  hike.getNibblesImpl()

# --------

proc step*(
    path: NibblesBuf, rvid: RootedVertexID, db: AristoTxRef
      ): Result[(VertexRef, int, VertexID), AristoError] =
  # Fetch next vertex
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error != GetVtxNotFound:
      return err(error)

    if rvid.root == rvid.vid:
      return err(HikeNoLegs)
    # The vertex ID `vid` was a follow up from a parent vertex, but there is
    # no child vertex on the database. So `vid` is a dangling link which is
    # allowed only if there is a partial trie (e.g. with `snap` sync.)
    return err(HikeDanglingEdge)

  case vtx.vType:
  of Leaves:
    # This must be the last vertex, so there cannot be any `tail` left.
    let vtx = LeafRef(vtx)
    if path.len != path.sharedPrefixLen(vtx.pfx):
      return err(HikeLeafUnexpected)

    ok (vtx, 0, VertexID(0))

  of Branch:
    # There must be some more data (aka `tail`) after a `Branch` vertex.
    let vtx = BranchRef(vtx)
    if path.len <= 0:
      return err(HikeBranchTailEmpty)

    let
      nibble = path[0]
      nextVid = vtx.bVid(nibble)

    if not nextVid.isValid:
      return err(HikeBranchMissingEdge)

    ok (vtx, 1, nextVid)

  of ExtBranch:
    # There must be some more data (aka `tail`) after a `Branch` vertex.
    let vtx = ExtBranchRef(vtx)
    if path.len <= vtx.pfx.len:
      return err(HikeBranchTailEmpty)

    let
      nibble = path[vtx.pfx.len]
      nextVid = vtx.bVid(nibble)

    if not nextVid.isValid:
      return err(HikeBranchMissingEdge)

    ok (vtx, vtx.pfx.len + 1, nextVid)


iterator stepUp*(
    path: NibblesBuf;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoTxRef;                             # Database
    next = VertexID(0)
): Result[VertexRef, AristoError] =
  ## For the argument `path`, iterate over the logest possible path in the
  ## argument database `db`.
  var
    path = path
    next = if next == VertexID(0): root else: next
    vtx = VertexRef(nil)
    common = 0
  block iter:
    while true:
      (vtx, common, next) = step(path, (root, next), db).valueOr:
        yield Result[VertexRef, AristoError].err(error)
        break iter

      yield Result[VertexRef, AristoError].ok(vtx)

      if common == 0:
        break
      path = path.slice(common)


proc hikeUp*[LeafType](
    path: NibblesBuf;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoTxRef;                             # Database
    leaf: Opt[LeafType];
    hike: var Hike;
      ): Result[void,(VertexID,AristoError)] =
  ## For the argument `path`, find and return the logest possible path in the
  ## argument database `db` - this may result in a partial match in which case
  ## hike.tail will be non-empty.
  ##
  ## If a leaf is given, it gets used for the "last" leg of the hike.
  hike.root = root
  hike.legs.setLen(0)

  var path = path
  if not root.isValid:
    return err((VertexID(0),HikeRootMissing))
  if path.len == 0:
    return err((VertexID(0),HikeEmptyPath))

  var vid = root
  while true:
    if leaf.isSome() and leaf[].isValid and path == leaf[].pfx:
      hike.legs.add Leg(wp: VidVtxPair(vid: vid, vtx: leaf[]), nibble: -1)
      #reset(hike.tail)
      break

    let
      (vtx, common, next) = step(path, (root, vid), db).valueOr:
        return err((vid,error))
      wp = VidVtxPair(vid:vid, vtx:vtx)

    case vtx.vType
    of Leaves:
      hike.legs.add Leg(wp: wp, nibble: -1)
      break

    of Branch:
      hike.legs.add Leg(wp: wp, nibble: int8 path[0])

    of ExtBranch:
      let vtx = ExtBranchRef(vtx)
      hike.legs.add Leg(wp: wp, nibble: int8 path[vtx.pfx.len])

    path = path.slice(common)
    vid = next

  ok()

proc hikeUp*[LeafType](
    path: Hash32;
    root: VertexID;
    db: AristoTxRef;
    leaf: Opt[LeafType];
    hike: var Hike
      ): Result[void,(VertexID,AristoError)] =
  ## Variant of `hike()`
  NibblesBuf.fromBytes(path.data).hikeUp(root, db, leaf, hike)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
