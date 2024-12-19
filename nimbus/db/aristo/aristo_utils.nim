# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Handy Helpers
## ==========================
##
{.push raises: [].}

import
  results,
  "."/[aristo_desc, aristo_compute]

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc toNode*(
    vtx: VertexRef;                    # Vertex to convert
    root: VertexID;                    # Sub-tree root the `vtx` belongs to
    db: AristoDbRef;                   # Database
      ): Result[NodeRef,seq[VertexID]] =
  ## Convert argument the vertex `vtx` to a node type. Missing Merkle hash
  ## keys are searched for on the argument database `db`.
  ##
  ## On error, at least the vertex ID of the first missing Merkle hash key is
  ## returned. If the argument `stopEarly` is set `false`, all missing Merkle
  ## hash keys are returned.
  ##
  ## In the argument `beKeyOk` is set `false`, keys for node links are accepted
  ## only from the cache layer. This does not affect a link key for a payload
  ## storage root.
  ##

  case vtx.vType:
  of Leaf:
    let node = NodeRef(vtx: vtx.dup())
    # Need to resolve storage root for account leaf
    if vtx.lData.pType == AccountData:
      let stoID = vtx.lData.stoID
      if stoID.isValid:
        let key = db.computeKey((stoID.vid, stoID.vid)).valueOr:
          return err(@[stoID.vid])

        node.key[0] = key
    return ok node

  of Branch:
    let node = NodeRef(vtx: vtx.dup())
    for n, subvid in vtx.pairs():
      let key = db.computeKey((root, subvid)).valueOr:
        return err(@[subvid])
      node.key[n] = key
    return ok node

iterator subVids*(vtx: VertexRef): VertexID =
  ## Returns the list of all sub-vertex IDs for the argument `vtx`.
  case vtx.vType:
  of Leaf:
    if vtx.lData.pType == AccountData:
      let stoID = vtx.lData.stoID
      if stoID.isValid:
        yield stoID.vid
  of Branch:
    for _, subvid in vtx.pairs():
      yield subvid

iterator subVidKeys*(node: NodeRef): (VertexID,HashKey) =
  ## Simolar to `subVids()` but for nodes
  case node.vtx.vType:
  of Leaf:
    if node.vtx.lData.pType == AccountData:
      let stoID = node.vtx.lData.stoID
      if stoID.isValid:
        yield (stoID.vid, node.key[0])
  of Branch:
    for n, subvid in node.vtx.pairs():
      yield (subvid,node.key[n])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
