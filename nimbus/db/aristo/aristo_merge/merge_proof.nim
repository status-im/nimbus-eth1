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
  std/[algorithm, sets, tables],
  eth/common,
  results,
  stew/keyed_queue,
  ../../../sync/protocol/snap/snap_types,
  ".."/[aristo_desc, aristo_get, aristo_layers, aristo_serialise, aristo_vid]

# ------------------------------------------------------------------------------
# Private functions: add Merkle proof node
# ------------------------------------------------------------------------------

proc mergeNodeImpl(
    db: AristoDbRef;                   # Database, top layer
    hashKey: HashKey;                  # Merkel hash of node (or so)
    node: NodeRef;                     # Node derived from RLP representation
    rootVid: VertexID;                 # Current sub-trie
      ): Result[void,AristoError]  =
  ## The function merges the argument hash key `lid` as expanded from the
  ## node RLP representation into the `Aristo Trie` database. The vertex is
  ## split off from the node and stored separately. So are the Merkle hashes.
  ## The vertex is labelled `locked`.
  ##
  ## The `node` argument is *not* checked, whether the vertex IDs have been
  ## allocated, already. If the node comes straight from the `decode()` RLP
  ## decoder as expected, these vertex IDs will be all zero.
  ##
  ## This function expects that the parent for the argument `node` has already
  ## been installed.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  # Check for error after RLP decoding
  doAssert node.error == AristoError(0)

  # Verify arguments
  if not rootVid.isValid:
    return err(MergeRootKeyInvalid)
  if not hashKey.isValid:
    return err(MergeHashKeyInvalid)

  # Make sure that the `vid<->key` reverse mapping is updated.
  let vid = db.layerGetProofVidOrVoid hashKey
  if not vid.isValid:
    return err(MergeRevVidMustHaveBeenCached)

  # Use the vertex ID `vid` to be populated by the argument root node
  let key = db.layersGetKeyOrVoid vid
  if key.isValid and key != hashKey:
    return err(MergeHashKeyDiffersFromCached)

  # Set up vertex.
  let (vtx, newVtxFromNode) = block:
    let vty = db.getVtx vid
    if vty.isValid:
      (vty, false)
    else:
      (node.to(VertexRef), true)

  # The `vertexID <-> hashKey` mappings need to be set up now (if any)
  case node.vType:
  of Leaf:
    # Check whether there is need to convert the payload to `Account` payload
    if rootVid == VertexID(1) and newVtxFromNode:
      try:
        let
          # `aristo_serialise.read()` always decodes raw data payloaf
          acc = rlp.decode(node.lData.rawBlob, Account)
          pyl = PayloadRef(
            pType: AccountData,
            account: AristoAccount(
              nonce:    acc.nonce,
              balance:  acc.balance,
              codeHash: acc.codeHash))
        if acc.storageRoot.isValid:
          var sid = db.layerGetProofVidOrVoid acc.storageRoot.to(HashKey)
          if not sid.isValid:
            sid = db.vidFetch
            db.layersPutProof(sid, acc.storageRoot.to(HashKey))
          pyl.stoID = sid
        vtx.lData = pyl
      except RlpError:
        return err(MergeNodeAccountPayloadError)

  of Extension:
    if node.key[0].isValid:
      let eKey = node.key[0]
      if newVtxFromNode:
        vtx.eVid = db.layerGetProofVidOrVoid eKey
        if not vtx.eVid.isValid:
          # Brand new reverse lookup link for this vertex
          vtx.eVid = db.vidFetch
      elif not vtx.eVid.isValid:
        return err(MergeNodeVidMissing)
      else:
        let yEke = db.getKey vtx.eVid
        if yEke.isValid and eKey != yEke:
          return err(MergeNodeVtxDiffersFromExisting)
      db.layersPutProof(vtx.eVid, eKey)

  of Branch:
    for n in 0..15:
      if node.key[n].isValid:
        let bKey = node.key[n]
        if newVtxFromNode:
          vtx.bVid[n] = db.layerGetProofVidOrVoid bKey
          if not vtx.bVid[n].isValid:
            # Brand new reverse lookup link for this vertex
            vtx.bVid[n] = db.vidFetch
        elif not vtx.bVid[n].isValid:
          return err(MergeNodeVidMissing)
        else:
          let yEkb = db.getKey vtx.bVid[n]
          if yEkb.isValid and yEkb != bKey:
            return err(MergeNodeVtxDiffersFromExisting)
        db.layersPutProof(vtx.bVid[n], bKey)

  # Store and lock vertex
  db.layersPutProof(vid, key, vtx)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeProof*(
    db: AristoDbRef;                   # Database, top layer
    proof: openArray[SnapProof];       # RLP encoded node records
    rootVid = VertexID(0);             # Current sub-trie
      ): Result[int, AristoError]
      {.gcsafe, raises: [RlpError].} =
  ## The function merges the argument `proof` list of RLP encoded node records
  ## into the `Aristo Trie` database. This function is intended to be used with
  ## the proof nodes as returened by `snap/1` messages.
  ##
  ## If there is no root vertex ID passed, the function tries to find out what
  ## the root hashes are and allocates new vertices with static IDs `$2`, `$3`,
  ## etc.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  proc update(
      seen: var Table[HashKey,NodeRef];
      todo: var KeyedQueueNV[NodeRef];
      key: HashKey;
        ) {.gcsafe, raises: [RlpError].} =
    ## Check for embedded nodes, i.e. fully encoded node instead of a hash.
    ## They need to be treated as full nodes, here.
    if key.isValid and key.len < 32:
      let lid = key.data.digestTo(HashKey)
      if not seen.hasKey lid:
        let node = key.data.decode(NodeRef)
        discard todo.append node
        seen[lid] = node

  let rootKey = block:
    if rootVid.isValid:
      let vidKey = db.getKey rootVid
      if not vidKey.isValid:
        return err(MergeRootKeyInvalid)
      # Make sure that the reverse lookup for the root vertex key is available.
      if not db.layerGetProofVidOrVoid(vidKey).isValid:
        return err(MergeProofInitMissing)
      vidKey
    else:
      VOID_HASH_KEY

  # Expand and collect hash keys and nodes and parent indicator
  var
    nodeTab: Table[HashKey,NodeRef]
    rootKeys: HashSet[HashKey] # Potential root node hashes
  for w in proof:
    let
      key = w.Blob.digestTo(HashKey)
      node = rlp.decode(w.Blob,NodeRef)
    if node.error != AristoError(0):
      return err(node.error)
    nodeTab[key] = node
    rootKeys.incl key

    # Check for embedded nodes, i.e. fully encoded node instead of a hash.
    # They will be added as full nodes to the `nodeTab[]`.
    var embNodes: KeyedQueueNV[NodeRef]
    discard embNodes.append node
    while true:
      let node = embNodes.shift.valueOr: break
      case node.vType:
      of Leaf:
        discard
      of Branch:
        for n in 0 .. 15:
          nodeTab.update(embNodes, node.key[n])
      of Extension:
        nodeTab.update(embNodes, node.key[0])

  # Create a table with back links
  var
    backLink: Table[HashKey,HashKey]
    blindNodes: HashSet[HashKey]
  for (key,node) in nodeTab.pairs:
    case node.vType:
    of Leaf:
      blindNodes.incl key
    of Extension:
      if nodeTab.hasKey node.key[0]:
        backLink[node.key[0]] = key
        rootKeys.excl node.key[0] # predecessor => not root
      else:
        blindNodes.incl key
    of Branch:
      var isBlind = true
      for n in 0 .. 15:
        if nodeTab.hasKey node.key[n]:
          isBlind = false
          backLink[node.key[n]] = key
          rootKeys.excl node.key[n] # predecessor => not root
      if isBlind:
        blindNodes.incl key

  # If it exists, the root key must be in the set `mayBeRoot` in order
  # to work.
  var roots: Table[HashKey,VertexID]
  if rootVid.isValid:
    if rootKey notin rootKeys:
      return err(MergeRootKeyNotInProof)
    roots[rootKey] = rootVid
  elif rootKeys.len == 0:
    return err(MergeRootKeysMissing)
  else:
    # Add static root keys different from VertexID(1)
    var count = 2
    for key in rootKeys.items:
      while true:
        # Check for already allocated nodes
        let vid1 = db.layerGetProofVidOrVoid key
        if vid1.isValid:
          roots[key] = vid1
          break
        # Use the next free static free vertex ID
        let vid2 = VertexID(count)
        count.inc
        if not db.getKey(vid2).isValid:
          doAssert not db.layerGetProofVidOrVoid(key).isValid
          db.layersPutProof(vid2, key)
          roots[key] = vid2
          break
        if LEAST_FREE_VID <= count:
          return err(MergeRootKeysOverflow)

  # Run over blind nodes and build chains from a blind/bottom level node up
  # to the root node. Select only chains that end up at the pre-defined root
  # node.
  var
    accounts: seq[seq[HashKey]] # This one separated, to be processed last
    chains: seq[seq[HashKey]]
  for w in blindNodes:
    # Build a chain of nodes up to the root node
    var
      chain: seq[HashKey]
      nodeKey = w
    while nodeKey.isValid and nodeTab.hasKey nodeKey:
      chain.add nodeKey
      nodeKey = backLink.getOrVoid nodeKey
    if 0 < chain.len and chain[^1] in roots:
      if roots.getOrVoid(chain[0]) == VertexID(1):
        accounts.add chain
      else:
        chains.add chain

  # Process over chains in reverse mode starting with the root node. This
  # allows the algorithm to find existing nodes on the backend.
  var
    seen: HashSet[HashKey]
    merged = 0
  # Process the root ID which is common to all chains
  for chain in chains & accounts:
    let chainRootVid = roots.getOrVoid chain[^1]
    for key in chain.reversed:
      if key notin seen:
        seen.incl key
        let node = nodeTab.getOrVoid key
        db.mergeNodeImpl(key, node, chainRootVid).isOkOr:
          return err(error)
        merged.inc

  ok merged


proc mergeProof*(
    db: AristoDbRef;                   # Database, top layer
    rootHash: Hash256;                 # Merkle hash for root
    rootVid = VertexID(0);             # Optionally, force root vertex ID
      ): Result[VertexID,AristoError] =
  ## Set up a `rootKey` associated with a vertex ID for use with proof nodes.
  ##
  ## If argument `rootVid` is unset then a new dybamic root vertex (i.e.
  ## the ID will be at least `LEAST_FREE_VID`) will be installed.
  ##
  ## Otherwise, if the argument `rootVid` is set then a sub-trie with root
  ## `rootVid` is checked for. An error is returned if it is set up already
  ## with a different `rootHash`.
  ##
  ## Upon successful return, the vertex ID assigned to the root key is returned.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  let rootKey = rootHash.to(HashKey)

  if rootVid.isValid:
    let key = db.getKey rootVid
    if key.isValid:
      if rootKey.isValid and key != rootKey:
        # Cannot use installed root key differing from hash argument
        return err(MergeRootKeyDiffersForVid)
      # Confirm root ID and key for proof nodes processing
      db.layersPutProof(rootVid, key) # note that `rootKey` might be void
      return ok rootVid

    if not rootHash.isValid:
      return err(MergeRootArgsIncomplete)
    if db.getVtx(rootVid).isValid:
      # Cannot use verify root key for existing root vertex
      return err(MergeRootKeyMissing)

    # Confirm root ID and hash key for proof nodes processing
    db.layersPutProof(rootVid, rootKey)
    return ok rootVid

  if not rootHash.isValid:
    return err(MergeRootArgsIncomplete)

  # Now there is no root vertex ID, only the hash argument.
  # So Create and assign a new root key.
  let vid = db.vidFetch
  db.layersPutProof(vid, rootKey)
  return ok vid


proc mergeProof*(
    db: AristoDbRef;                   # Database, top layer
    rootVid: VertexID;                 # Root ID
      ): Result[VertexID,AristoError] =
  ## Variant of `mergeProof()` for missing `rootHash`
  db.mergeProof(EMPTY_ROOT_HASH, rootVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
