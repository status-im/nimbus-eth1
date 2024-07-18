# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common,
  results,
  "."/[aristo_desc, aristo_get]

type
  Leg* = object
    ## For constructing a `VertexPath`
    wp*: VidVtxPair                ## Vertex ID and data ref
    nibble*: int8                  ## Next vertex selector for `Branch` (if any)

  Hike* = object
    ## Trie traversal path
    root*: VertexID                ## Handy for some fringe cases
    legs*: seq[Leg]                ## Chain of vertices and IDs
    tail*: NibblesBuf              ## Portion of non completed path

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
      result = result & leg.wp.vtx.ePfx & NibblesBuf.nibble(leg.nibble.byte)
    of Leaf:
      result = result & leg.wp.vtx.lPfx

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
    path: NibblesBuf, rvid: RootedVertexID, db: AristoDbRef
      ): Result[(VertexRef, NibblesBuf, VertexID), AristoError] =
  # Fetch next vertex
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error != GetVtxNotFound:
      return err(error)

    # The vertex ID `vid` was a follow up from a parent vertex, but there is
    # no child vertex on the database. So `vid` is a dangling link which is
    # allowed only if there is a partial trie (e.g. with `snap` sync.)
    return err(HikeDanglingEdge)

  case vtx.vType:
  of Leaf:
    # This must be the last vertex, so there cannot be any `tail` left.
    if path.len != path.sharedPrefixLen(vtx.lPfx):
      return err(HikeLeafUnexpected)

    ok (vtx, NibblesBuf(), VertexID(0))

  of Branch:
    # There must be some more data (aka `tail`) after a `Branch` vertex.
    if path.len <= vtx.ePfx.len:
      return err(HikeBranchTailEmpty)

    let
      nibble = path[vtx.ePfx.len].int8
      nextVid = vtx.bVid[nibble]

    if not nextVid.isValid:
      return err(HikeBranchMissingEdge)

    ok (vtx, path.slice(vtx.ePfx.len + 1), nextVid)


iterator stepUp*(
    path: NibblesBuf;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoDbRef;                             # Database
): Result[VertexRef, AristoError] =
  ## For the argument `path`, iterate over the logest possible path in the
  ## argument database `db`.
  var
    path = path
    next = root
    vtx: VertexRef
  block iter:
    while true:
      (vtx, path, next) = step(path, (root, next), db).valueOr:
        yield Result[VertexRef, AristoError].err(error)
        break iter

      yield Result[VertexRef, AristoError].ok(vtx)

      if path.len == 0:
        break

proc hikeUp*(
    path: NibblesBuf;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoDbRef;                             # Database
      ): Result[Hike,(VertexID,AristoError,Hike)] =
  ## For the argument `path`, find and return the logest possible path in the
  ## argument database `db`.
  var hike = Hike(
    root: root,
    tail: path)

  if not root.isValid:
    return err((VertexID(0),HikeRootMissing,hike))
  if path.len == 0:
    return err((VertexID(0),HikeEmptyPath,hike))

  var vid = root
  while true:
    let (vtx, path, next) = step(hike.tail, (root, vid), db).valueOr:
      return err((vid,error,hike))

    let wp = VidVtxPair(vid:vid, vtx:vtx)

    case vtx.vType
    of Leaf:
      hike.legs.add Leg(wp: wp, nibble: -1)
      hike.tail = path

      break

    of Branch:
      hike.legs.add Leg(wp: wp, nibble: int8 hike.tail[vtx.ePfx.len])

    hike.tail = path
    vid = next

  ok hike

proc hikeUp*(
    lty: LeafTie;
    db: AristoDbRef;
      ): Result[Hike,(VertexID,AristoError,Hike)] =
  ## Variant of `hike()`
  lty.path.to(NibblesBuf).hikeUp(lty.root, db)

proc hikeUp*(
    path: openArray[byte];
    root: VertexID;
    db: AristoDbRef;
      ): Result[Hike,(VertexID,AristoError,Hike)] =
  ## Variant of `hike()`
  NibblesBuf.fromBytes(path).hikeUp(root, db)

proc hikeUp*(
    path: Hash256;
    root: VertexID;
    db: AristoDbRef;
      ): Result[Hike,(VertexID,AristoError,Hike)] =
  ## Variant of `hike()`
  NibblesBuf.fromBytes(path.data).hikeUp(root, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
