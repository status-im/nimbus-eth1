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
  eth/[common, trie/nibbles],
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
    tail*: NibblesSeq              ## Portion of non completed path

const
  HikeAcceptableStopsNotFound* = {
      HikeBranchTailEmpty,
      HikeBranchMissingEdge,
      HikeExtTailEmpty,
      HikeExtTailMismatch,
      HikeLeafUnexpected,
      HikeNoLegs}
    ## When trying to find a leaf vertex the Patricia tree, there are several
    ## conditions where the search stops which do not constitute a problem
    ## with the trie (aka sysetm error.)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func getNibblesImpl(hike: Hike; start = 0; maxLen = high(int)): NibblesSeq =
  ## May be needed for partial rebuild, as well
  for n in start ..< min(hike.legs.len, maxLen):
    let leg = hike.legs[n]
    case leg.wp.vtx.vType:
    of Branch:
      result = result & @[leg.nibble.byte].initNibbleRange.slice(1)
    of Extension:
      result = result & leg.wp.vtx.ePfx
    of Leaf:
      result = result & leg.wp.vtx.lPfx

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(rc: Result[Hike,(VertexID,AristoError,Hike)]; T: type Hike): T =
  ## Extract `Hike` from either ok ot error part of argument `rc`.
  if rc.isOk: rc.value else: rc.error[2]

func to*(hike: Hike; T: type NibblesSeq): T =
  ## Convert back
  hike.getNibblesImpl() & hike.tail

func legsTo*(hike: Hike; T: type NibblesSeq): T =
  ## Convert back
  hike.getNibblesImpl()

func legsTo*(hike: Hike; numLegs: int; T: type NibblesSeq): T =
  ## variant of `legsTo()`
  hike.getNibblesImpl(0, numLegs)

# --------

proc hikeUp*(
    path: NibblesSeq;                            # Partial path
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
    var leg = Leg(wp: VidVtxPair(vid: vid), nibble: -1)

    # Fetch next vertex
    leg.wp.vtx = db.getVtxRc(vid).valueOr:
      if error != GetVtxNotFound:
        return err((vid,error,hike))
      if hike.legs.len == 0:
        return err((vid,HikeNoLegs,hike))
      # The vertex ID `vid` was a follow up from a parent vertex, but there is
      # no child vertex on the database. So `vid` is a dangling link which is
      # allowed only if there is a partial trie (e.g. with `snap` sync.)
      return err((vid,HikeDanglingEdge,hike))

    case leg.wp.vtx.vType:
    of Leaf:
      # This must be the last vertex, so there cannot be any `tail` left.
      if hike.tail.len == hike.tail.sharedPrefixLen(leg.wp.vtx.lPfx):
        # Bingo, got full path
        hike.legs.add leg
        hike.tail = EmptyNibbleSeq
        # This is the only loop exit
        break

      return err((vid,HikeLeafUnexpected,hike))

    of Branch:
      # There must be some more data (aka `tail`) after a `Branch` vertex.
      if hike.tail.len == 0:
        hike.legs.add leg
        return err((vid,HikeBranchTailEmpty,hike))

      let
        nibble = hike.tail[0].int8
        nextVid = leg.wp.vtx.bVid[nibble]

      if not nextVid.isValid:
        return err((vid,HikeBranchMissingEdge,hike))

      leg.nibble = nibble
      hike.legs.add leg
      hike.tail = hike.tail.slice(1)
      vid = nextVid

    of Extension:
      # There must be some more data (aka `tail`) after an `Extension` vertex.
      if hike.tail.len == 0:
        hike.legs.add leg
        hike.tail = EmptyNibbleSeq
        return err((vid,HikeExtTailEmpty,hike))    # Well, somehow odd

      if leg.wp.vtx.ePfx.len != hike.tail.sharedPrefixLen(leg.wp.vtx.ePfx):
        return err((vid,HikeExtTailMismatch,hike)) # Need to branch from here

      let nextVid = leg.wp.vtx.eVid
      if not nextVid.isValid:
        return err((vid,HikeExtMissingEdge,hike))

      hike.legs.add leg
      hike.tail = hike.tail.slice(leg.wp.vtx.ePfx.len)
      vid = nextVid

  ok hike

proc hikeUp*(
    lty: LeafTie;
    db: AristoDbRef;
      ): Result[Hike,(VertexID,AristoError,Hike)] =
  ## Variant of `hike()`
  lty.path.to(NibblesSeq).hikeUp(lty.root, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
