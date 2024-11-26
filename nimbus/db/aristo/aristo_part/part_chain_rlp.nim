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
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_utils, aristo_serialise]

const
  ChainRlpNodesNoEntry* = {
    PartChnLeafPathMismatch, PartChnExtPfxMismatch, PartChnBranchVoidEdge}
    ## Partial path errors that can be used to proof that a path does
    ## not exists.

  TrackRlpNodesNoEntry* = {PartTrkLinkExpected, PartTrkLeafPfxMismatch}
    ## This is the opposite of `ChainRlpNodesNoEntry` when verifying that a
    ## node does not exist.

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc chainRlpNodes*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    path: NibblesBuf,
    chain: var seq[seq[byte]];
      ): Result[void,AristoError] =
  ## Inspired by the `getBranchAux()` function from `hexary.nim`
  let
    (vtx,_) = ? db.getVtxRc rvid
    node = vtx.toNode(rvid.root, db).valueOr:
      return err(PartChnNodeConvError)

  # Save rpl encoded node(s)
  chain &= node.to(seq[seq[byte]])

  # Follow up child node
  case vtx.vType:
  of Leaf:
    if path != vtx.pfx:
      err(PartChnLeafPathMismatch)
    else:
      ok()

  of Branch:
    let nChewOff = sharedPrefixLen(vtx.pfx, path)
    if nChewOff != vtx.pfx.len:
      err(PartChnExtPfxMismatch)
    elif path.len == nChewOff:
      err(PartChnBranchPathExhausted)
    else:
      let
        nibble = path[nChewOff]
        rest = path.slice(nChewOff+1)
      if not vtx.bVid[nibble].isValid:
        return err(PartChnBranchVoidEdge)
      # Recursion!
      db.chainRlpNodes((rvid.root,vtx.bVid[nibble]), rest, chain)


proc trackRlpNodes*(
    chain: openArray[seq[byte]];
    topKey: HashKey;
    path: NibblesBuf;
    start = false;
     ): Result[seq[byte],AristoError]
     {.gcsafe, raises: [RlpError]} =
  ## Verify rlp-encoded node chain created by `chainRlpNodes()`.
  if path.len == 0:
    return err(PartTrkEmptyPath)

  # Verify key against rlp-node
  let digest = chain[0].digestTo(HashKey)
  if start:
    if topKey.to(Hash32) != digest.to(Hash32):
      return err(PartTrkFollowUpKeyMismatch)
  else:
    if topKey != digest:
      return err(PartTrkFollowUpKeyMismatch)

  var
    node = rlpFromBytes chain[0]
    nChewOff = 0
    link: seq[byte]

  # Decode rlp-node and prepare for recursion
  case node.listLen
  of 2:
    let (isLeaf, segm) = NibblesBuf.fromHexPrefix node.listElem(0).toBytes
    nChewOff = sharedPrefixLen(path, segm)
    link = node.listElem(1).toBytes # link or payload
    if isLeaf:
      if nChewOff == path.len:
        return ok(link)
      return err(PartTrkLeafPfxMismatch)
  of 17:
    nChewOff = 1
    link = node.listElem(path[0].int).toBytes
  else:
    return err(PartTrkGarbledNode)

  let nextKey = HashKey.fromBytes(link).valueOr:
    return err(PartTrkLinkExpected)
  chain.toOpenArray(1,chain.len-1).trackRlpNodes(nextKey, path.slice nChewOff)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
