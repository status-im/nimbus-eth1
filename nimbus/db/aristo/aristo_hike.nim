# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
    error*: AristoError            ## Info for whoever wants it to see

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

func to*(hike: Hike; T: type NibblesSeq): T =
  ## Convert back
  hike.getNibblesImpl() & hike.tail

func legsTo*(hike: Hike; T: type NibblesSeq): T =
  ## Convert back
  hike.getNibblesImpl()

# --------

proc hikeUp*(
    path: NibblesSeq;                            # Partial path
    root: VertexID;                              # Start vertex
    db: AristoDb;                                # Database
      ): Hike =
  ## For the argument `path`, find and return the logest possible path in the
  ## argument database `db`.
  result = Hike(
    root: root,
    tail: path)

  if not root.isValid:
    result.error = PathRootMissing

  else:
    var vid = root
    while vid.isValid:
      var vtx = db.getVtx vid
      if not vtx.isValid:
        break

      var leg = Leg(wp: VidVtxPair(vid: vid, vtx: vtx), nibble: -1)

      case vtx.vType:
      of Leaf:
        if result.tail.len == result.tail.sharedPrefixLen(vtx.lPfx):
          # Bingo, got full path
          result.legs.add leg
          result.tail = EmptyNibbleSeq
        else:
          result.error = PathLeafTooEarly # Ooops
        break # Buck stops here

      of Branch:
        if result.tail.len == 0:
          result.legs.add leg
          result.error = PathBranchTailEmpty # Ooops
          break

        let
          nibble = result.tail[0].int8
          nextVid = vtx.bVid[nibble]

        if not nextVid.isValid:
          result.error = PathBranchBlindEdge # Ooops
          break

        leg.nibble = nibble
        result.legs.add leg
        result.tail = result.tail.slice(1)
        vid = nextVid

      of Extension:
        if result.tail.len == 0:
          result.legs.add leg
          result.tail = EmptyNibbleSeq
          result.error = PathExtTailEmpty # Well, somehow odd
          break

        if vtx.ePfx.len != result.tail.sharedPrefixLen(vtx.ePfx):
          result.error = PathExtTailMismatch # Need to branch from here
          break

        result.legs.add leg
        result.tail = result.tail.slice(vtx.ePfx.len)
        vid = vtx.eVid

proc hikeUp*(lty: LeafTie; db: AristoDb): Hike =
  ## Variant of `hike()`
  lty.path.to(NibblesSeq).hikeUp(lty.root, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
