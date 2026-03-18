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
    of Empty:
      raiseAssert "unexpected empty vtx"
    of Branch:
      result = result & NibblesBuf.nibble(leg.nibble.byte)
    of ExtBranch:
      result = result & leg.wp.vtx.branch.pfx[] & NibblesBuf.nibble(leg.nibble.byte)
    of AccLeaf:
      result = result & leg.wp.vtx.accLeaf.pfx
    of StoLeaf:
      result = result & leg.wp.vtx.stoLeaf.pfx

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(rc: Result[Hike,(VertexID,AristoError,Hike)]; T: type Hike): T =
  ## Extract `Hike` from either ok ot error part of argument `rc`.
  if rc.isOk: rc.value else: rc.error[2]

func to*(hike: Hike; T: type NibblesBuf): T =
  ## Convert back
  hike.getNibblesImpl() & hike.tail

func legsTo*(hike: Hike; T: type NibblesBuf): T =
  ## Convert back
  hike.getNibblesImpl()

func legsTo*(hike: Hike; numLegs: int; T: type NibblesBuf): T =
  ## variant of `legsTo()`
  hike.getNibblesImpl(0, numLegs)

# --------

proc step*(
    path: NibblesBuf, rvid: RootedVertexID, db: AristoTxRef
      ): Result[(Vertex, NibblesBuf, VertexID), AristoError] =
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
  of Empty:
    raiseAssert "unexpected empty vtx"
  of AccLeaf:
    # This must be the last vertex, so there cannot be any `tail` left.
    if path.len != path.sharedPrefixLen(vtx.accLeaf.pfx):
      return err(HikeLeafUnexpected)

    ok (vtx, NibblesBuf(), VertexID(0))
  of StoLeaf:
    # This must be the last vertex, so there cannot be any `tail` left.
    if path.len != path.sharedPrefixLen(vtx.stoLeaf.pfx):
      return err(HikeLeafUnexpected)

    ok (vtx, NibblesBuf(), VertexID(0))

  of Branch:
    # There must be some more data (aka `tail`) after a `Branch` vertex.
    if path.len <= 0:
      return err(HikeBranchTailEmpty)

    let
      nibble = path[0]
      nextVid = vtx.branch.bVid(nibble)

    if not nextVid.isValid:
      return err(HikeBranchMissingEdge)

    ok (vtx, path.slice(1), nextVid)

  of ExtBranch:
    # There must be some more data (aka `tail`) after a `Branch` vertex.
    if path.len <= vtx.branch.pfx[].len:
      return err(HikeBranchTailEmpty)

    let
      nibble = path[vtx.branch.pfx[].len]
      nextVid = vtx.branch.bVid(nibble)

    if not nextVid.isValid:
      return err(HikeBranchMissingEdge)

    ok (vtx, path.slice(vtx.pfx.len + 1), nextVid)


iterator stepUp*(
    path: NibblesBuf;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoTxRef;                             # Database
    next = VertexID(0)
): Result[Vertex, AristoError] =
  ## For the argument `path`, iterate over the logest possible path in the
  ## argument database `db`.
  var
    path = path
    next = if next == VertexID(0): root else: next
    vtx = emptyVertex
  block iter:
    while true:
      (vtx, path, next) = step(path, (root, next), db).valueOr:
        yield Result[Vertex, AristoError].err(error)
        break iter

      yield Result[Vertex, AristoError].ok(vtx)

      if path.len == 0:
        break

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
  hike.tail = path
  hike.legs.setLen(0)

  if not root.isValid:
    return err((VertexID(0),HikeRootMissing))
  if path.len == 0:
    return err((VertexID(0),HikeEmptyPath))

  var vid = root
  while true:
    if leaf.isSome() and leaf[].isValid and path == leaf[][].pfx:
      when LeafType is Opt[AccLeafData]:
        hike.legs.add Leg(wp: VidVtxPair(vid: vid, vtx: Vertex(vType: AccLeaf, accLeaf: leaf[][])), nibble: -1)
      else:
        hike.legs.add Leg(wp: VidVtxPair(vid: vid, vtx: Vertex(vType: StoLeaf, stoLeaf: leaf[][])), nibble: -1)
      reset(hike.tail)
      break

    let (vtx, path, next) = step(hike.tail, (root, vid), db).valueOr:
      return err((vid,error))

    let wp = VidVtxPair(vid:vid, vtx:vtx)

    case vtx.vType
    of Empty:
      raiseAssert "unexpected empty vtx"
    of Leaves:
      hike.legs.add Leg(wp: wp, nibble: -1)
      hike.tail = path

      break

    of Branch:
      hike.legs.add Leg(wp: wp, nibble: int8 hike.tail[0])

    of ExtBranch:
      hike.legs.add Leg(wp: wp, nibble: int8 hike.tail[vtx.branch.pfx[].len])

    hike.tail = path
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
