# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
    backend*: bool                 ## Sources from backend if `true`

  Hike* = object
    ## Trie traversal path
    root*: VertexID                ## Handy for some fringe cases
    legs*: seq[Leg]                ## Chain of vertices and IDs
    tail*: NibblesSeq              ## Portion of non completed path

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

func to*(rc: Result[Hike,(Hike,AristoError)]; T: type Hike): T =
  ## Extract `Hike` from either ok ot error part of argument `rc`.
  if rc.isOk: rc.value else: rc.error[0]

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
      ): Result[Hike,(Hike,AristoError)] =
  ## For the argument `path`, find and return the logest possible path in the
  ## argument database `db`.
  var hike = Hike(
    root: root,
    tail: path)

  if not root.isValid:
    return err((hike,HikeRootMissing))
  if path.len == 0:
    return err((hike,HikeEmptyPath))

  var vid = root
  while vid.isValid:
    var leg = Leg(wp: VidVtxPair(vid: vid), nibble: -1)

    # Fetch vertex to be checked on this lap
    leg.wp.vtx = db.top.sTab.getOrVoid vid
    if not leg.wp.vtx.isValid:

      # Register vertex fetched from backend (if any)
      let rc = db.getVtxBE vid
      if rc.isErr:
        break
      leg.backend = true
      leg.wp.vtx = rc.value

    case leg.wp.vtx.vType:
    of Leaf:
      if hike.tail.len == hike.tail.sharedPrefixLen(leg.wp.vtx.lPfx):
        # Bingo, got full path
        hike.legs.add leg
        hike.tail = EmptyNibbleSeq
        break

      return err((hike,HikeLeafTooEarly))

    of Branch:
      if hike.tail.len == 0:
        hike.legs.add leg
        return err((hike,HikeBranchTailEmpty))

      let
        nibble = hike.tail[0].int8
        nextVid = leg.wp.vtx.bVid[nibble]

      if not nextVid.isValid:
        return err((hike,HikeBranchBlindEdge))

      leg.nibble = nibble
      hike.legs.add leg
      hike.tail = hike.tail.slice(1)
      vid = nextVid

    of Extension:
      if hike.tail.len == 0:
        hike.legs.add leg
        hike.tail = EmptyNibbleSeq
        return err((hike,HikeExtTailEmpty))    # Well, somehow odd

      if leg.wp.vtx.ePfx.len != hike.tail.sharedPrefixLen(leg.wp.vtx.ePfx):
        return err((hike,HikeExtTailMismatch)) # Need to branch from here

      hike.legs.add leg
      hike.tail = hike.tail.slice(leg.wp.vtx.ePfx.len)
      vid = leg.wp.vtx.eVid

  ok hike

proc hikeUp*(lty: LeafTie; db: AristoDbRef): Result[Hike,(Hike,AristoError)] =
  ## Variant of `hike()`
  lty.path.to(NibblesSeq).hikeUp(lty.root, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
