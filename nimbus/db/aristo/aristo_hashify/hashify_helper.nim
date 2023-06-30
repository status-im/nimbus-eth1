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
  #std/[tables],
  eth/common,
  stew/results,
  ".."/[aristo_constants, aristo_desc, aristo_get, aristo_transcode]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toNode*(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDb;                      # Database, top layer
    stopEarly = true;                  # Full list of missing links if `false`
      ): Result[NodeRef,seq[VertexID]] =
  ## Convert argument vertex to node
  case vtx.vType:
  of Leaf:
    return ok NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    var missing: seq[VertexID]
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let key = db.getKey vid
        if key.isValid:
          node.key[n] = key
        else:
          missing.add vid
          if stopEarly:
            break
      else:
        node.key[n] = VOID_HASH_KEY
    if 0 < missing.len:
      return err(missing)
    return ok node
  of Extension:
    let
      vid = vtx.eVid
      key = db.getKey vid
    if key.isValid:
      let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
      node.key[0] = key
      return ok node
    return err(@[vid])

# This function cannot go into `aristo_desc` as it depends on `aristo_transcode`
# which depends on `aristo_desc`.
proc toHashKey*(node: NodeRef): HashKey =
  ## Convert argument `node` to Merkle hash key
  node.encode.digestTo(HashKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
