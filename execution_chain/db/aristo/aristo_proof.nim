# nimbus-eth1
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Create and verify MPT proofs
## ===========================================================
##
{.push raises: [].}

import
  eth/common/hashes,
  results,
  ./[aristo_desc, aristo_fetch, aristo_get, aristo_serialise, aristo_utils]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------


const
  ChainRlpNodesNoEntry* = {
    PartChnLeafPathMismatch, PartChnExtPfxMismatch, PartChnBranchVoidEdge}
    ## Partial path errors that can be used to proof that a path does
    ## not exists.

  TrackRlpNodesNoEntry* = {PartTrkLinkExpected, PartTrkLeafPfxMismatch}
    ## This is the opposite of `ChainRlpNodesNoEntry` when verifying that a
    ## node does not exist.

proc chainRlpNodes(
    db: AristoTxRef;
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
  of Leaves:
    if path != vtx.pfx:
      err(PartChnLeafPathMismatch)
    else:
      ok()

  of Branches:
    let vtx = BranchRef(vtx)
    let nChewOff = sharedPrefixLen(vtx.pfx, path)
    if nChewOff != vtx.pfx.len:
      err(PartChnExtPfxMismatch)
    elif path.len == nChewOff:
      err(PartChnBranchPathExhausted)
    else:
      let
        nibble = path[nChewOff]
        rest = path.slice(nChewOff+1)
      if not vtx.bVid(nibble).isValid:
        return err(PartChnBranchVoidEdge)
      # Recursion!
      db.chainRlpNodes((rvid.root,vtx.bVid(nibble)), rest, chain)


proc trackRlpNodes(
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
# Public functions
# ------------------------------------------------------------------------------

proc makeProof(
    db: AristoTxRef;
    root: VertexID;
    path: NibblesBuf;
      ): Result[(seq[seq[byte]],bool), AristoError] =
  ## This function returns a chain of rlp-encoded nodes along the argument
  ## path `(root,path)` followed by a `true` value if the `path` argument
  ## exists in the database. If the argument `path` is not on the database,
  ## a partial path will be returned follwed by a `false` value.
  ##
  ## Errors will only be returned for invalid paths.
  ##
  var chain: seq[seq[byte]]
  let rc = db.chainRlpNodes((root,root), path, chain)
  if rc.isOk:
    ok((chain, true))
  elif rc.error in ChainRlpNodesNoEntry:
    ok((chain, false))
  else:
    err(rc.error)

proc makeAccountProof*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[(seq[seq[byte]],bool), AristoError] =
  db.makeProof(VertexID(1), NibblesBuf.fromBytes accPath.data)

proc makeStorageProof*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[(seq[seq[byte]],bool), AristoError] =
  ## Note that the function returns an error unless
  ## the argument `accPath` is valid.
  let vid = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathStoRootMissing:
      return ok((@[],false))
    return err(error)
  db.makeProof(vid, NibblesBuf.fromBytes stoPath.data)

# ----------

proc verifyProof*(
    chain: openArray[seq[byte]];
    root: Hash32;
    path: Hash32;
      ): Result[Opt[seq[byte]],AristoError] =
  ## Variant of `partUntwigGeneric()`.
  try:
    let
      nibbles = NibblesBuf.fromBytes path.data
      rc = chain.trackRlpNodes(root.to(HashKey), nibbles, start=true)
    if rc.isOk:
      return ok(Opt.some rc.value)
    if rc.error in TrackRlpNodesNoEntry:
      return ok(Opt.none seq[byte])
    return err(rc.error)
  except RlpError:
    return err(PartTrkRlpError)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
