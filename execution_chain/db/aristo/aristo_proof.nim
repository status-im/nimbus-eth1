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
  std/[tables, sets, sequtils],
  eth/common/hashes,
  results,
  ./[aristo_desc, aristo_fetch, aristo_get, aristo_serialise, aristo_utils, aristo_vid, aristo_layers]

const
  ChainRlpNodesNoEntry* = {
    PartChnLeafPathMismatch, PartChnExtPfxMismatch, PartChnBranchVoidEdge}
    ## Partial path errors that can be used to proof that a path does
    ## not exists.

  TrackRlpNodesNoEntry* = {PartTrkLinkExpected, PartTrkLeafPfxMismatch}
    ## This is the opposite of `ChainRlpNodesNoEntry` when verifying that a
    ## node does not exist.

type
  NodesCache = Table[RootedVertexID, array[2, seq[byte]]]
    ## Caches up to two rlp encoded trie nodes in each value

template appendNodes(chain: var seq[seq[byte]], nodePair: array[2, seq[byte]]) =
  chain.add(nodePair[0])
  if nodePair[1].len() > 0:
    chain.add(nodePair[1])

proc chainRlpNodes(
    db: AristoTxRef,
    rvid: RootedVertexID,
    path: NibblesBuf,
    chain: var seq[seq[byte]],
    nodesCache: var NodesCache): Result[void, AristoError] =
  ## Inspired by the `getBranchAux()` function from `hexary.nim`
  let (vtx, _) = ?db.getVtxRc(rvid)

  nodesCache.withValue(rvid, value):
    chain.appendNodes(value[])
  do:
    let node = vtx.toNode(rvid.root, db).valueOr:
      return err(PartChnNodeConvError)

    # Save rpl encoded node(s)
    let rlpNodes = node.to(array[2, seq[byte]])
    nodesCache[rvid] = rlpNodes
    chain.appendNodes(rlpNodes)

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
      db.chainRlpNodes((rvid.root,vtx.bVid(nibble)), rest, chain, nodesCache)

proc makeProof(
    db: AristoTxRef;
    root: VertexID;
    path: NibblesBuf;
    nodesCache: var NodesCache;
    chain: var seq[seq[byte]];
      ): Result[bool, AristoError] =
  ## This function returns a chain of rlp-encoded nodes along the argument
  ## path `(root,path)` followed by a `true` value if the `path` argument
  ## exists in the database. If the argument `path` is not on the database,
  ## a partial path will be returned follwed by a `false` value.
  ##
  ## Errors will only be returned for invalid paths.
  ##
  let rc = db.chainRlpNodes((root,root), path, chain, nodesCache)
  if rc.isOk:
    ok(true)
  elif rc.error in ChainRlpNodesNoEntry:
    ok(false)
  else:
    err(rc.error)

proc makeAccountProof*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[(seq[seq[byte]], bool), AristoError] =
  var
    nodesCache: NodesCache
    proof: seq[seq[byte]]
  let exists = ?db.makeProof(STATE_ROOT_VID, NibblesBuf.fromBytes accPath.data, nodesCache, proof)
  ok((proof, exists))

proc makeStorageProof*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[(seq[seq[byte]], bool), AristoError] =
  ## Note that the function returns an error unless
  ## the argument `accPath` is valid.
  let vid = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathStoRootMissing:
      return ok((@[],false))
    return err(error)
  var
    nodesCache: NodesCache
    proof: seq[seq[byte]]
  let exists = ?db.makeProof(vid, NibblesBuf.fromBytes stoPath.data, nodesCache, proof)
  ok((proof, exists))

proc makeStorageProofs*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPaths: openArray[Hash32];
      ): Result[seq[seq[seq[byte]]], AristoError] =
  ## Note that the function returns an error unless
  ## the argument `accPath` is valid.
  let vid = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathStoRootMissing:
      let emptyProofs = newSeq[seq[seq[byte]]](stoPaths.len())
      return ok(emptyProofs)
    return err(error)

  var
    nodesCache: NodesCache
    proofs = newSeqOfCap[seq[seq[byte]]](stoPaths.len())
  for stoPath in stoPaths:
    var proof: seq[seq[byte]]
    discard ?db.makeProof(vid, NibblesBuf.fromBytes stoPath.data, nodesCache, proof)
    proofs.add(proof)

  ok(proofs)

proc makeStorageMultiProof(
    db: AristoTxRef;
    accPath: Hash32;
    stoPaths: openArray[Hash32];
    nodesCache: var NodesCache;
    multiProof: var HashSet[seq[byte]]
      ): Result[void, AristoError] =
  ## Note that the function returns an error unless
  ## the argument `accPath` is valid.
  let vid = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathStoRootMissing:
      return ok()
    return err(error)

  for stoPath in stoPaths:
    var proof: seq[seq[byte]]
    discard ?db.makeProof(vid, NibblesBuf.fromBytes stoPath.data, nodesCache, proof)
    for node in proof:
      multiProof.incl(node)

  ok()

proc makeMultiProof*(
    db: AristoTxRef;
    paths: Table[Hash32, seq[Hash32]], # maps each account path to a list of storage paths
    multiProof: var seq[seq[byte]]
      ): Result[void, AristoError] =
  var
    nodesCache: NodesCache
    proofNodes: HashSet[seq[byte]]

  for accPath, stoPaths in paths:
    var accProof: seq[seq[byte]]
    let exists = ?db.makeProof(STATE_ROOT_VID, NibblesBuf.fromBytes accPath.data, nodesCache, accProof)
    for node in accProof:
      proofNodes.incl(node)

    if exists:
      ?db.makeStorageMultiProof(accPath, stoPaths, nodesCache, proofNodes)

  multiProof = proofNodes.toSeq()

  ok()

template rlpNodeToBytes(node: Rlp): seq[byte] =
  if node.isList():
    node.rawData.toSeq()
  else:
    node.toBytes()

proc trackRlpNodes(
    chain: openArray[seq[byte]];
    nextIndex: int;
    topKey: HashKey;
    path: NibblesBuf;
    start = false;
     ): Result[seq[byte], AristoError]
     {.gcsafe, raises: [RlpError]} =
  ## Verify rlp-encoded node chain created by `chainRlpNodes()`.

  if nextIndex > chain.high:
    return err(PartTrkLinkExpected)
  if path.len == 0:
    return err(PartTrkEmptyPath)

  # Verify key against rlp-node
  let digest = chain[nextIndex].digestTo(HashKey)
  if start:
    if topKey.to(Hash32) != digest.to(Hash32):
      return err(PartTrkFollowUpKeyMismatch)
  else:
    if topKey != digest:
      return err(PartTrkFollowUpKeyMismatch)

  var
    rlpNode = rlpFromBytes chain[nextIndex]
    nChewOff = 0
    link: seq[byte]

  # Decode rlp-node and prepare for recursion
  case rlpNode.listLen
  of 2:
    let (isLeaf, segm) = NibblesBuf.fromHexPrefix rlpNode.listElem(0).toBytes
    nChewOff = sharedPrefixLen(path, segm)
    link = rlpNode.listElem(1).rlpNodeToBytes() # link or payload
    if isLeaf:
      if nChewOff == path.len:
        return ok(link)
      return err(PartTrkLeafPfxMismatch)
  of 17:
    nChewOff = 1
    link = rlpNode.listElem(path[0].int).rlpNodeToBytes()
  else:
    return err(PartTrkGarbledNode)

  let nextKey = HashKey.fromBytes(link).valueOr:
    return err(PartTrkLinkExpected)

  trackRlpNodes(chain, nextIndex + 1, nextKey, path.slice nChewOff)

proc trackRlpNodes(
    nodes: Table[Hash32, seq[byte]];
    visitedNodes: var HashSet[Hash32];
    topKey: HashKey;
    path: NibblesBuf;
    start = false;
     ): Result[seq[byte], AristoError]
     {.gcsafe, raises: [RlpError]} =
  ## Verify rlp-encoded node chain created by `chainRlpNodes()`.

  let nodeHash = topKey.to(Hash32)
  if visitedNodes.contains(nodeHash):
    return err(PartTrkFollowUpKeyMismatch)
  if nodeHash notin nodes:
    if start:
      return err(PartTrkFollowUpKeyMismatch)
    else:
      return err(PartTrkLinkExpected)
  if path.len == 0:
    return err(PartTrkEmptyPath)

  let node = nodes.getOrDefault(nodeHash)
  visitedNodes.incl(nodeHash)

  # Verify key against rlp-node
  let digest = node.digestTo(HashKey)
  if start:
    if topKey.to(Hash32) != digest.to(Hash32):
      return err(PartTrkFollowUpKeyMismatch)
  else:
    if topKey != digest:
      return err(PartTrkFollowUpKeyMismatch)

  var
    rlpNode = rlpFromBytes node
    nChewOff = 0
    link: seq[byte]

  # Decode rlp-node and prepare for recursion
  case rlpNode.listLen
  of 2:
    let (isLeaf, segm) = NibblesBuf.fromHexPrefix rlpNode.listElem(0).toBytes
    nChewOff = sharedPrefixLen(path, segm)
    link = rlpNode.listElem(1).rlpNodeToBytes() # link or payload
    if isLeaf:
      if nChewOff == path.len:
        return ok(link)
      return err(PartTrkLeafPfxMismatch)
  of 17:
    nChewOff = 1
    link = rlpNode.listElem(path[0].int).rlpNodeToBytes()
  else:
    return err(PartTrkGarbledNode)

  let nextKey = HashKey.fromBytes(link).valueOr:
    return err(PartTrkLinkExpected)

  trackRlpNodes(nodes, visitedNodes, nextKey, path.slice nChewOff)

proc verifyProof*(
    chain: openArray[seq[byte]];
    root: Hash32;
    path: Hash32;
      ): Result[Opt[seq[byte]], AristoError] =
  if chain.len() == 0:
    return err(PartTrkEmptyProof)

  try:
    let
      nibbles = NibblesBuf.fromBytes path.data
      rc = trackRlpNodes(chain, 0, root.to(HashKey), nibbles, start=true)
    if rc.isOk:
      return ok(Opt.some rc.value)
    if rc.error in TrackRlpNodesNoEntry:
      return ok(Opt.none seq[byte])
    return err(rc.error)
  except RlpError:
    return err(PartTrkRlpError)

proc verifyProof*(
    nodes: Table[Hash32, seq[byte]];
    root: Hash32;
    path: Hash32;
      ): Result[Opt[seq[byte]], AristoError] =
  if nodes.len() == 0:
    return err(PartTrkEmptyProof)

  try:
    var visitedNodes: HashSet[Hash32]
    let
      nibbles = NibblesBuf.fromBytes path.data
      rc = trackRlpNodes(nodes, visitedNodes, root.to(HashKey), nibbles, start=true)
    if rc.isOk:
      return ok(Opt.some rc.value)
    if rc.error in TrackRlpNodesNoEntry:
      return ok(Opt.none seq[byte])
    return err(rc.error)
  except RlpError:
    return err(PartTrkRlpError)

proc putAccTrieNode(
    db: AristoTxRef,
    node: NodeRef): Result[Opt[VertexID], AristoError] =

  let
    vid = db.vidFetch(16)
    rvid = (STATE_ROOT_VID, vid) # pass in state root?

  db.layersPutVtx(rvid, node.vtx)

  case node.vtx.vType:
    of AccLeaf:
      let
        accVtx = AccLeafRef(node.vtx)
        stoID = accVtx.stoID
        useID =
          if stoID.isValid: stoID                     # Use as is
          elif stoID.vid.isValid: (true, stoID.vid)   # Re-use previous vid
          else: (true, db.vidFetch())                 # Create new vid
    of StoLeaf:
      raiseAssert("Unsupported vType")
    of Branch, ExtBranch:
      for n, subvid in node.vtx.pairs():
        db.layersPutKey((STATE_ROOT_VID, subvid), BranchRef(node.vtx), node.key[n])
