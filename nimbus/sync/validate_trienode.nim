# Nimbus - Robustly parse trie nodes from network untrusted data
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module parses Ethereum hexary trie nodes from bytes received over the
## network.  The data is untrusted, and a non-canonical RLP encoding of the
## node must be rejected, so this code parses carefully.
##
## The caller provides bytes and context.  Context includes node hash, trie
## path, and a boolean saying if this trie node is child of an extension node.
##
## The result of parsing is up to 16 child nodes to visit (paths with hashes),
## or up to 7 leaf nodes to decode.
##
## This doesn't verify the node hash.  The caller should ensure the bytes are
## verified against the hash separately from calling this parser.  Even
## with the hash verified, the bytes are still untrusted and must be parsed
## carefully, because the hash itself is from an untrusted source.
##
## `RlpError` exceptions may occur on some well-crafted adversarial input due
## to the RLP reader implementation.  They could be trapped and treated like
## other parse errors, but that's not done.  Instead, the caller should put
## `try..except RlpError as e` outside its trie node parsing loop, and pass the
## exception to `parseTrieNodeError` if it occurs.

{.push raises: [Defect].}

import
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types]

type
  TrieNodeParseContext* = object
    childQueue*:            seq[(InteriorPath, NodeHash, bool)]
    leafQueue*:             seq[(LeafPath, NodeHash, Blob)]
    errors*:                int

template maybeHash(nodeHash: NodeHash, nodeBytes: Blob): string =
  if nodeBytes.len >= 32: $nodeHash else: "selfEncoded"

proc combinePaths(nodePath, childPath: InteriorPath): string =
  let nodeHex = nodePath.toHex(false)
  let childHex = childPath.toHex(true)
  nodeHex & "::" & childHex[nodeHex.len..^1]

template leafError(msg: string{lit}, more: varargs[untyped]) =
  mixin sp, leafPath, nodePath, nodeHash, nodeBytes, context
  debug "Trie leaf data error: " & msg,
    depth=nodePath.depth, leafDepth=leafPath.depth, `more`,
    path=combinePaths(nodePath, leafPath),
    hash=maybeHash(nodeHash, nodeBytes),
    nodeLen=nodeBytes.len, nodeBytes=nodeBytes.toHex, peer=sp
  echo inspect(rlpFromBytes(nodeBytes))
  inc context.errors

template childError(msg: string{lit}, more: varargs[untyped]) =
  mixin sp, childPath, nodePath, nodeHash, nodeBytes, context
  debug "Trie data error: " & msg,
    depth=nodePath.depth, childDepth=childPath.depth, `more`,
    path=combinePaths(nodePath, childPath),
    hash=maybeHash(nodeHash, nodeBytes),
    nodeLen=nodeBytes.len, nodeBytes=nodeBytes.toHex, peer=sp
  echo inspect(rlpFromBytes(nodeBytes))
  inc context.errors

template nodeError(msg: string{lit}, more: varargs[untyped]) =
  mixin sp, nodePath, nodeHash, nodeBytes, context
  debug "Trie data error: " & msg,
    depth=nodePath.depth, `more`,
    path=nodePath.toHex(true), hash=maybeHash(nodeHash, nodeBytes),
    nodeLen=nodeBytes.len, nodeBytes=nodeBytes.toHex, peer=sp
  echo inspect(rlpFromBytes(nodeBytes))
  inc context.errors

proc parseLeafValue(sp: SyncPeer,
                    nodePath: InteriorPath, nodeHash: NodeHash, nodeBytes: Blob,
                    nodeRlp: var Rlp, leafPath: InteriorPath,
                    context: var TrieNodeParseContext
                   ) {.inline, raises: [Defect, RlpError].} =
  ## Parse the leaf value of a trie leaf node.  The caller has already updated
  ## `leafPath`, which means the path length can't be above the maximum.
  ## But it hasn't checked other path length constraints.

  # Check the leaf depth.  Leaves are only allowed at the maximum depth.
  if leafPath.depth != InteriorPath.maxDepth:
    leafError "Leaf node at interior node depth",
      requiredLeafDepth=InteriorPath.maxDepth
    return

  # Check and parse leaf RLP.
  # List elements were already counted before calling here, so we don't
  # need a `nodeRlp.hasData` "has no bytes" check.
  if not nodeRlp.isBlob:
    leafError "Leaf value (RLP element 1) is not a blob"
    return
  # TODO: `blobLen` can throw if there's an encoded number larger than our
  # types can represent.  This is untrusted data, so we must handle that case.
  let leafLen = nodeRlp.blobLen

  # A leaf cannot be zero-length.
  if leafLen == 0:
    leafError "Leaf value (RLP element 1) is zero length"
    return

  context.leafQueue.add((leafPath.toLeafPath, nodeHash, nodeRlp.toBytes))

  if traceIndividualNodes:
    let leafBytes = context.leafQueue[^1][2]
    trace "Trie: Account leaf found",
      path=combinePaths(nodePath, leafPath),
      nodeHash=maybeHash(nodeHash, nodeBytes),
      leafLen, leafBytes=leafBytes.toHex, peer=sp
#    echo inspect(rlpFromBytes(leafBytes))

# Forward declaration, used for bounded, rare recursion.
proc parseTrieNode*(sp: SyncPeer,
                    nodePath: InteriorPath, nodeHash: NodeHash, nodeBytes: Blob,
                    fromExtension: bool,
                    context: var TrieNodeParseContext
                   ) {.gcsafe, raises: [Defect, RlpError].}

proc parseExtensionChild(sp: SyncPeer,
                         nodePath: InteriorPath, nodeHash: NodeHash,
                         nodeBytes: Blob, nodeRlp: var Rlp,
                         childPath: InteriorPath,
                         context: var TrieNodeParseContext
                        ) {.inline, raises: [Defect, RlpError].} =
  ## Parse the child branch of a trie extension node.  The caller has already
  ## updated `childPath`, which means the path length can't be above the
  ## maximum.  But it hasn't checked other path length constraints.

  # In the canonical trie encoding, extension nodes must have non-zero
  # length prefix.  Only leaf nodes can have zero length prefix.
  #
  # TODO: File a correction to the Yellow Paper, Ethereum formal specification.
  # The Yellow Paper says (on 2021-11-01) "Extension: [...]  a series of
  # nibbles of size _greater_ than one".  In the real world, Mainnet and
  # Goerli, there are extension nodes with prefix length one.
  if childPath.depth == nodePath.depth:
    childError "Extension node prefix does not increase depth",
      prefixLen=(childPath.depth - nodePath.depth), minPrefixLen=1
    return

  # Check and parse child RLP.
  # List elements were already counted before calling here, so we don't
  # need a `nodeRlp.hasData` "has no bytes" check.
  if not nodeRlp.isBlob:
    childError "Extension node child (RLP element 1) is not a blob"
    return
  # TODO: `blobLen` can throw if there's an encoded number larger than our
  # types can represent.  This is untrusted data, so we must handle that case.
  let childLen = nodeRlp.blobLen

  if childLen == 32:
    doAssert(sizeof(NodeHash) == 32)
    context.childQueue.add((childPath, nodeRlp.read(NodeHash), true))
  elif childLen == 0:
    # The child of an extension node cannot be empty, unlike the children of a
    # branch node.  The child must be present.
    childError "Extension node child (RLP element 1) is zero length"
  elif childLen < 32:
    # TODO: In rare cases, which are cryptographically unlikely, the child
    # RLP can be < 32 bytes.  Because this is hard to test, let's make < 32
    # exit the program for now to see if any appear on Mainnet.
    doAssert childLen == 32
    sp.parseTrieNode(childPath, NodeHash(), nodeRlp.toBytes, true, context)
  else:
    childError "Extension node child (RLP element 1) has length > 32 bytes"

proc parseExtensionOrLeaf(sp: SyncPeer,
                          nodePath: InteriorPath, nodeHash: NodeHash,
                          nodeBytes: Blob, nodeRlp: var Rlp,
                          fromExtension: bool,
                          context: var TrieNodeParseContext
                         ) {.inline, raises: [Defect, RlpError].} =
  ## Parse a trie extension node or leaf node.  The caller has already checked
  ## it is a list of 2 elements, but nothing else.

  # Check and parse prefix digits RLP.
  # List elements were already counted before calling here, so we don't
  # need a `nodeRlp.hasData` "has no bytes" check.
  if not nodeRlp.isBlob:
    nodeError "Extension prefix or leaf node path suffix (RLP element 0) is not a blob"
    return

  # TODO: Prefix can be empty according to `hexPrefixDecode`.  Check that.
  # TODO: `blobLen` can throw if there's an encoded number larger than our
  # types can represent.  This is untrusted data, so we must handle that case.
  let prefixBytesLen = nodeRlp.blobLen
  if prefixBytesLen == 0:
    nodeError "Extension or leaf node prefix (RLP element 0) is zero length"
    return

  let prefixBytes = nodeRlp.toBytes
  let firstByte = prefixBytes[0]
  let oddLen = (firstByte.int and 0x10) shr 4
  let isLeaf = (firstByte and 0x20)

  # Check no bits are set that shouldn't be, to verify canonical encoding.
  # Upper 2 bits are never set.  If the prefix is even length, the extra
  # nibble in the first byte must be zero.
  if (firstByte and (if oddLen == 0: 0xcf else: 0xc0)) != 0:
    if isLeaf != 0:
      nodeError "Leaf node path suffix (RLP element 0) starts with invalid byte",
        invalidByte=[firstByte].toHex
    else:
      nodeError "Extension node prefix (RLP element 0) starts with invalid byte",
        invalidByte=[firstByte].toHex
    return

  # In the canonical trie encoding, an extension node's child is not allowed to
  # be a leaf or another extension node.  This check is done here, instead of
  # earlier, to give a more informative message about leaf versus extension.
  if fromExtension:
    if isLeaf != 0:
      nodeError "Leaf node is child of an extension node"
    else:
      nodeError "Extension node is child of another extension node"
    return

  # Check child depth before making `childPath`, as the type has limited length.
  # The strange arithmetic where we don't just add `prefixLen + depth` is to
  # rule out numeric overflow.  This is also why we don't include `childDepth
  # = prefixLen + depth` in the error messages.
  let prefixLen = (prefixBytesLen * 2) - 2 + oddLen
  if prefixLen > InteriorPath.maxDepth - nodePath.depth:
    if isLeaf != 0:
      nodeError "Leaf node path suffix takes depth past maximum",
        suffixLen=prefixLen, maxDepth=InteriorPath.maxDepth
    elif nodePath.depth >= InteriorPath.maxDepth:
      nodeError "Extension node at maximum depth",
        maxDepth=InteriorPath.maxDepth
    else:
      # In the canonical trie encoding, an extension node prefix is not allowed
      # to take depth up to exactly the maximum either.  That would mean the
      # child would have to be a leaf, and a leaf cannot be the child of an
      # extension node.  So we could error on `>= max` here.  But we choose `>`
      # to allow the traversal to continue and get a more detailed error from
      # the child node.
      nodeError "Extension node prefix takes depth past maximum",
        prefixLen, maxDepth=InteriorPath.maxDepth
    return

  var childPath = nodePath
  if oddLen != 0:
    childPath.add(firstByte and 0x0f)
  for i in 1 ..< prefixBytesLen:
    childPath.addPair(prefixBytes[i])

  nodeRlp.skipElem()
  if isLeaf != 0:
    sp.parseLeafValue(nodePath, nodeHash, nodeBytes, nodeRlp,
                      childPath, context)
  else:
    sp.parseExtensionChild(nodePath, nodeHash, nodeBytes, nodeRlp,
                           childPath, context)

proc parseBranchNode(sp: SyncPeer,
                     nodePath: InteriorPath, nodeHash: NodeHash,
                     nodeBytes: Blob, nodeRlp: var Rlp,
                     context: var TrieNodeParseContext
                    ) {.inline, raises: [Defect, RlpError].} =
  ## Parse a trie branch node.  The caller has already checked it is a list
  ## of 17 elements, but nothing else.

  # Check the length before making `childPath`, as that has a maximum length.
  if nodePath.depth >= InteriorPath.maxDepth:
    nodeError "Branch node at maximum depth",
      childDepth=(nodePath.depth + 1), maxDepth=InteriorPath.maxDepth
    return

  let queueLenBefore = context.childQueue.len
  var childPath = nodePath
  for i in 0 .. 15:

    # List elements were already counted before this loop, so we don't
    # need a `nodeRlp.hasData` "has no bytes" check.
    if not nodeRlp.isBlob:
      childPath.add(i.byte)
      childError "Branch node child (RLP element i in 0..15) is not a blob", i
      return
    # TODO: `blobLen` can throw if there's an encoded number larger than our
    # types can represent.  This is untrusted data, so we must handle that case.
    let childLen = nodeRlp.blobLen
    if childLen == 0:
      # Quick version of `nodeRlp.skipElem()` for zero-length blob.
      inc nodeRlp.position
      continue

    childPath.add(i.byte)
    if childLen == 32:
      doAssert(sizeof(NodeHash) == 32)
      context.childQueue.add((childPath, nodeRlp.read(NodeHash), false))
    elif childLen < 32:
      # TODO: In rare cases, which are cryptographically unlikely, the child
      # RLP can be < 32 bytes.  Because this is hard to test, let's make < 32
      # exit the program for now to see if any appear on Mainnet.
      doAssert childLen == 32
      sp.parseTrieNode(childPath, NodeHash(), nodeRlp.toBytes, false, context)
      nodeRlp.skipElem()
    else:
      childError "Branch node child (RLP element i in 0..15) has length > 32 bytes", i
      return
    childPath.pop()

  # List elements were already counted before this loop, so we don't
  # need a `nodeRlp.hasData` "has no bytes" check for the value item.
  if not nodeRlp.isBlob:
    nodeError "Branch node value (RLP element 16) is not a blob"
    return
  # TODO: `blobLen` can throw if there's an encoded number larger than our
  # types can represent.  This is untrusted data, so we must handle that case.
  let valueLen = nodeRlp.blobLen
  if valueLen != 0:
    nodeError "Branch node value (RLP element 16) has non-zero length",
      valueLen, valueMaxLen=0
    return

  # In the canonical trie encoding, there must be at least 2 child branches.
  let branchCount = context.childQueue.len - queueLenBefore
  if branchCount < 2:
    # Undo what we queued, as this node has an error.
    context.childQueue.setLen(queueLenBefore)
    if branchCount == 0:
      nodeError "Branch node has no child branches",
        branches=branchCount, minBranches=2
    else:
      nodeError "Branch node has insufficient child branches",
        branches=branchCount, minBranches=2
    return

proc parseTrieNode*(sp: SyncPeer,
                    nodePath: InteriorPath, nodeHash: NodeHash, nodeBytes: Blob,
                    fromExtension: bool, context: var TrieNodeParseContext
                   ) {.raises: [Defect, RlpError].} =
  ## Parse an Ethereum trie node of any kind.  The caller provides bytes and
  ## context.  Context includes trie path, node hash, and whether the parent
  ## node is an extension node.
  ##
  ## - Any child nodes to visit are added to `context.childQueue`, up to 16.
  ##
  ## - Any leaf nodes to decode are added to `context.leafQueue`, up to 7.
  ##
  ## - When multiple children or leaves are returned, they are guaranteed to
  ##   be in increasing path order.
  ##
  ## - If there are any errors parsing or with basic trie structure, debug
  ##   messages are logged and `context.errors` is incremented.
  ##
  ## - `nodePath` is used.  Using the path, the correct depth of branch,
  ##   extension and leaf nodes are checked by this parser.  Child and leaf
  ##   paths are calculated and stored in `childQueue` and `leafQueue`.
  ##
  ## - `nodeHash` is _not_ used to verify the bytes.
  ##
  ##   The hash is only used for diagnostics.  The caller should ensure the
  ##   bytes are verified against the hash separately from calling this
  ##   function, so there's no need to calculate the hash again here.  Even
  ##   with the hash verified, the bytes are still untrusted and must be parsed
  ##   carefully, because the hash itself is from an untrusted source.
  ##
  ## - `fromExtension` is used.  It is used to check that an extension node is
  ##   not the parent of another extension node or a leaf, as this is not
  ##   allowed in the canonical trie encoding.  This value is `false` for the
  ##   root node of a trie, otherwise it is the value stored in `childQueue`
  ##   from parsing the parent node.
  ##
  ## - The `sp: SyncPeer` is like the hash, only used for diagnostics.  When
  ##   there is invalid data, it's useful to show where we got it from.
  ##
  ## - Some limited recursion is possible while parsing, because of how < 32
  ##   byte nodes are encoded inside others.  When recursion occurs, the number
  ##   of child nodes will be 0, and the theoretical maximum number of leaf
  ##   nodes is 7, although this is only possible in contrived test cases that
  ##   disable path hashing.  This is why `leafQueue` is a list.
  ##
  ##   Recursion like this cannot occur with account nodes, because account
  ##   leaves are too large for it in the canonical Ethereum encoding.  It can
  ##   occur with storage slots.
  ##
  ## - `RlpError` exceptions may occur on some well-crafted adversarial input
  ##   due to the RLP reader implementation.  They could be caught and treated
  ##   like other parse errors, but they are not caught here, to avoid the
  ##   overhead of `try..except` in the parser (which uses C `setjmp`).  The
  ##   caller should put `try..except RlpError` outside its trie node parsing
  ##   loop, and call `parseTrieNodeError` when `RlpError` is caught.
  ##
  ## As a special case only used internally during recursion, if `nodeBytes` is
  ## shorter than 32, `nodeHash` is ignored, even for diagnostics.  These
  ## internal nodes don't have a hash and can't be fetched over the network.

  var nodeRlp = rlpFromBytes(nodeBytes)
  if not nodeRlp.hasData:
    nodeError "Trie node RLP has no bytes"
    return

  # This section is like calling `isList` and `listLen`, but it has more
  # robust checks: It checks there are no extra bytes after the list, and
  # the list header exactly matches the byte length of list contents.
  # By using `enterList` it also sets up the sub-parsers to read `nodeRlp`.
  var savePosition = nodeRlp.position
  nodeRlp.skipElem()
  let afterListPosition = nodeRlp.position
  let hasExtraTrailingBytes = nodeRlp.hasData()
  nodeRlp.position = savePosition
  if not nodeRlp.enterList():
    nodeError "Trie node RLP is not a list"
    return
  savePosition = nodeRlp.position
  if hasExtraTrailingBytes:
    nodeError "Trie node RLP has extra bytes after the list"
    return
  var nodeListLen = 0
  while nodeRlp.position < afterListPosition:
    inc nodeListLen
    nodeRlp.skipElem()
  if nodeRlp.position != afterListPosition:
    nodeError "Trie node RLP list container has incorrect length for contents"
    return
  nodeRlp.position = savePosition

  if nodeListLen == 2:
    sp.parseExtensionOrLeaf(nodePath, nodeHash, nodeBytes, nodeRlp,
                            fromExtension, context)
  elif nodeListLen == 17:
    sp.parseBranchNode(nodePath, nodeHash, nodeBytes, nodeRlp, context)
  else:
    nodeError "Trie node RLP is not a list with 2 or 17 items",
      listLen=nodeListLen
    return

proc parseTrieNodeError*(sp: SyncPeer, nodePath: InteriorPath,
                         nodeHash: NodeHash, nodeBytes: Blob,
                         context: var TrieNodeParseContext,
                         exception: ref RlpError) =
  ## Handle an `RlpError` exception and update `context.errors`.  This should
  ## be called if `parseTrieNode` raises any exception derived from `RlpError`.
  ## This is a separate function is so that many `parseTrieNode` calls can be
  ## made in a loop, with the `try..except` lifted outside the loop.
  try:
    nodeError "Exception from RLP parser", exception=exception.msg
  except RlpError as e:
    # If we get `RlpError` from `nodeError` it means `inspect` failed.
    # That should never happen, so raise `Defect` to terminate the program.
    raise newException(Defect, "Exception from RLP inspector", e)
