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
  std/sequtils,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_utils, aristo_compute, aristo_serialise]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc chainRlpNodes*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    path: NibblesBuf,
    chain: var seq[Blob];
      ): Result[void,AristoError] =
  ## Inspired by the `getBranchAux()` function from `hexary.nim`
  let
    key = ? db.computeKey rvid
    (vtx,_) = ? db.getVtxRc rvid
    node = vtx.toNode(rvid.root, db).valueOr:
      return err(PartBrNodeConvError)

  # Save rpl encoded node(s)
  chain &= (key,node).to(seq[(Blob,Blob)]).mapIt(it[1])

  # Follow up child node
  case vtx.vType:
  of Leaf:
    if path != vtx.lPfx:
      err(PartBrLeafPathMismatch)
    else:
      ok()

  of Branch:
    if path.len == 0:
      err(PartBrBranchPathMismatch)
    else:
      # Recursion!
      db.chainRlpNodes((rvid.root,vtx.bVid[path[0]]), path.slice(1), chain)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
