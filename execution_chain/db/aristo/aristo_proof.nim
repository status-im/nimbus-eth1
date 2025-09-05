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
  eth/common/[hashes, accounts_rlp],
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

template verifyAgainstKey(node: openArray[byte], topKey: HashKey, start: bool): auto =
  let digest = node.digestTo(HashKey)
  if start:
    if topKey.to(Hash32) != digest.to(Hash32):
      return err(PartTrkFollowUpKeyMismatch)
  else:
    if topKey != digest:
      return err(PartTrkFollowUpKeyMismatch)

template verifyRlp(node: openArray[byte]): (HashKey, NibblesBuf) =
  var
    rlpNode = rlpFromBytes(node)
    nChewOff = 0
    link: seq[byte]

  # Decode rlp-node and prepare for recursion
  case rlpNode.listLen()
  of 2:
    let (isLeaf, segm) = NibblesBuf.fromHexPrefix(rlpNode.listElem(0).toBytes())
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

  (nextKey, path.slice(nChewOff))

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
  let nextNode = chain[nextIndex]
  nextNode.verifyAgainstKey(topKey, start)

  let (nextKey, path) = nextNode.verifyRlp()
  trackRlpNodes(chain, nextIndex + 1, nextKey, path)

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
  visitedNodes.incl(nodeHash)

  # Verify key against rlp-node
  let nextNode = nodes.getOrDefault(nodeHash)
  nextNode.verifyAgainstKey(topKey, start)

  let (nextKey, path) = nextNode.verifyRlp()
  trackRlpNodes(nodes, visitedNodes, nextKey, path)

template handleTrackRlpNodesResult(blk: untyped): auto =
  try:
    let rc = blk
    if rc.isOk():
      return ok(Opt.some rc.value)
    if rc.error() in TrackRlpNodesNoEntry:
      return ok(Opt.none seq[byte])
    return err(rc.error())
  except RlpError:
    return err(PartTrkRlpError)

proc verifyProof*(
    chain: openArray[seq[byte]];
    root: Hash32;
    path: Hash32): Result[Opt[seq[byte]], AristoError] =
  if chain.len() == 0:
    return err(PartTrkEmptyProof)

  handleTrackRlpNodesResult():
    let nibbles = NibblesBuf.fromBytes(path.data)
    trackRlpNodes(chain, 0, root.to(HashKey), nibbles, start = true)

proc verifyProof*(
    nodes: Table[Hash32, seq[byte]];
    root: Hash32;
    path: Hash32;
    visitedNodes: var HashSet[Hash32]
      ): Result[Opt[seq[byte]], AristoError] =
  if nodes.len() == 0:
    return err(PartTrkEmptyProof)

  handleTrackRlpNodesResult():
    let nibbles = NibblesBuf.fromBytes(path.data)
    trackRlpNodes(nodes, visitedNodes, root.to(HashKey), nibbles, start = true)

proc verifyProof*(
    nodes: Table[Hash32, seq[byte]];
    root: Hash32;
    path: Hash32;
      ): Result[Opt[seq[byte]], AristoError] =
  var visitedNodes: HashSet[Hash32]
  verifyProof(nodes, root, path, visitedNodes)

proc convertLeaf(
    link: openArray[byte],
    segm: NibblesBuf,
    isStorage: bool): Result[NodeRef, AristoError] {.gcsafe, raises: [RlpError]} =

  let node =
    if isStorage:
      let slotValue = rlp.decode(link, UInt256)
      NodeRef(vtx: StoLeafRef.init(segm, slotValue))
    else: # account leaf
      let
        acc = rlp.decode(link, Account)
        aristoAcc = AristoAccount(nonce: acc.nonce, balance: acc.balance, codeHash: acc.codeHash)
        stoID = (acc.storageRoot != EMPTY_ROOT_HASH, default(VertexID))
        node = NodeRef(vtx: AccLeafRef.init(segm, aristoAcc, stoID))
      node.key[0] = HashKey.fromBytes(acc.storageRoot.data).valueOr:
        return err(PartTrkLinkExpected)
      node

  ok(node)

proc convertSubtrie(
    key: Hash32,
    src: Table[Hash32, seq[byte]],
    dst: var Table[HashKey, NodeRef],
    isStorage: static bool): Result[void, AristoError] {.gcsafe, raises: [RlpError]} =
  # Precondition: trieNodes have already been validated using verifyProof
  # Does not allocate any vertex ids when creating the VertexRef types.
  if key notin src:
    # Since we are processing a subtrie some nodes are expected to be missing
    return ok()

  var
    rlpNode = rlpFromBytes(src.getOrDefault(key))
    node = NodeRef()
  case rlpNode.listLen()
  of 2:
    let
      (isLeaf, segm) = NibblesBuf.fromHexPrefix(rlpNode.listElem(0).toBytes())
      link = rlpNode.listElem(1).rlpNodeToBytes() # link or payload
    if isLeaf:
      node = ?convertLeaf(link, segm, isStorage)
      if not isStorage:
        let accLeaf = AccLeafRef(node.vtx)
        if accLeaf.stoID.isValid:
          ?convertSubtrie(node.key[0].to(Hash32), src, dst, true)
    else: # extension node
      let k = HashKey.fromBytes(link).valueOr:
        return err(PartTrkLinkExpected)
      # TODO: how to handle embedded nodes

      # Convert the child branch node which will be merged with this extension node
      ?convertSubtrie(k.to(Hash32), src, dst, isStorage)
      doAssert(dst.contains(k))

      let
        childNode = dst.getOrDefault(k)
        childBranch = BranchRef(childNode.vtx)
      node.key = childNode.key
      node.vtx = ExtBranchRef.init(segm, childBranch.startVid, childBranch.used)

      # Remove the childNode because it's branch was copied into this node
      dst.del(k)

  of 17: # branch node
    let branch = BranchRef.init(default(VertexID), 0)
    for i in 0 ..< 16:
      let
        link = rlpNode.listElem(i).rlpNodeToBytes()
        k = HashKey.fromBytes(link).valueOr:
          return err(PartTrkLinkExpected)
      if k.len() == 32:
        discard branch.setUsed(i.uint8, true)
        ?convertSubtrie(k.to(Hash32), src, dst, isStorage)
      node.key[i] = k
    node.vtx = branch
  else:
    return err(PartTrkGarbledNode)

  let hashKey = HashKey.fromBytes(key.data).valueOr:
    return err(PartTrkLinkExpected)
  dst[hashKey] = node

  ok()

proc putSubtrie(
    db: AristoTxRef,
    key: HashKey,
    nodes: Table[HashKey, NodeRef],
    rvid: RootedVertexID = (STATE_ROOT_VID, STATE_ROOT_VID)): Result[void, AristoError] =
  if key notin nodes:
    return err(PartTrkFollowUpKeyMismatch)

  let node = nodes.getOrDefault(key)

  case node.vtx.vType:
    of AccLeaf:
      let accVtx = AccLeafRef(node.vtx)
      if accVtx.stoID.isValid:
        let stoVid = db.vidFetch()
        accVtx.stoID = (true, stoVid)

        let
          k = node.key[0]
          r = (stoVid, stoVid)
        if nodes.contains(k):
          # Write the storage subtrie
          ?db.putSubtrie(k, nodes, r)
        else:
          # Write the known hash key setting the vtx to nil
          db.layersPutKey(r, BranchRef(nil), k)

    of StoLeaf:
      discard

    of Branch, ExtBranch:
      let bvtx = BranchRef(node.vtx)
      bvtx.startVid = db.vidFetch(16)

      for n, subvid in node.vtx.pairs():
        let
          k = node.key[n]
          r = (rvid.root, subvid)
        if nodes.contains(k):
          ?db.putSubtrie(k, nodes, r)
        else:
          # Write the known hash key setting the vtx to nil
          db.layersPutKey(r, BranchRef(nil), k)

  db.layersPutVtx(rvid, node.vtx)

  ok()

proc putSubTrie*(
    db: AristoTxRef,
    stateRoot: Hash32,
    nodes: Table[Hash32, seq[byte]]): Result[void, AristoError] =
  if nodes.len() == 0:
    return err(PartTrkEmptyProof)

  let key = HashKey.fromBytes(stateRoot.data).valueOr:
    return err(PartTrkLinkExpected)

  try:
    var convertedNodes: Table[HashKey, NodeRef]
    ?convertSubtrie(stateRoot, nodes, convertedNodes, isStorage = false)
    ?db.putSubtrie(key, convertedNodes)
  except RlpError:
    return err(PartTrkRlpError)

  ok()
