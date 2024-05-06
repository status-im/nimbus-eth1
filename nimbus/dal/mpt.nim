#[  Nimbus
    Copyright (c) 2021-2024 Status Research & Development GmbH
    Licensed and distributed under either of
      * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
      * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
    at your option. This file may not be copied, modified, or distributed except according to those terms. ]#


##[ This module provides the data structures for an implementation of Ethereum's modified Merkle
    Patricia Tree (MPT), along with enumeration, pretty printing and serialization methods.
    The other `mpt_*` modules provide methods for mutating the tree and computing merkle hashes.

    This implmentation of MPT provides the following features:

      * Diff layers / "stacked trees". Enables "stacking" a tree on top of another one, such that
        modifications made to the "top" tree do not affect the lower tree(s). This allows us to
        isolate changes made to a tree (e.g. by a transaction in a block) and to discard them
        easily. It also allows us to maintain diverging trees (e.g. the world state across
        competing block chains).
        See this writeup explaining it: https://hackmd.io/dC5gEGrzQJS9wiEhJBRIlQ

      * Partial loading. Since the tree can grow very large, we can't store it all in memory. The
        parts that weren't loaded have a place-holder in the form of a `MptNotLoaded` node. Mutating
        operations may soft-fail when a part of the tree needs to be loaded to complete the
        operation, and allow resuming once it was.

      * Lazy hashing. To compute the merkle hash of a diff layer, call `DiffLayer.rootHash`. The
        hash (or Recursive Length Prefix encoding) of each node is cached inside the node so that
        it's not computed redundantly.

      * Account node. We model an Ethereum account as a distinct node type in the tree. This
        provides stronger-typed access to the account, and more efficient access to the balance and
        nonce. The world state contains just `MptAccount`s as leaves, and account storages contain
        just `MptLeaf`s as leaves.
]##

import
  std/[options, streams, strformat],
  ../../../vendor/nim-stint/stint,
  ./[utils, mpt_nibbles]

export stint.UInt256

type

  Buffer32* = object
    ## A buffer that can hold up to 32 bytes of data. `len` denotes how many bytes are in use.
    bytes*: array[32, byte]
    len*: uint8


  MptNode* = ref object of RootObj
    ## The base class for MPT nodes
    #[ Note: We don't hold meta-data on nodes such as the tree path, tree depth, logical depth etc
             since it consumes memory and requires careful book-keeping when cloning nodes and
             shifting them higher or lower down the tree. Instead, we compute these on the flight.
       PERF TODO: check possibility of using enum types; save cost of virtual methods. ]#
    diffHeight*: uint64   ## The diff layer height that this node belongs to
    hashOrRlp*: Buffer32  ## The Merkle hash or RLP (if shorter than 32 bytes). Only available after
                          ## calling `DiffLayer.rootHash` (otherwise `len` is 0)


  MptNotLoaded* = ref object of MptNode
    ##[ A MPT node representing that a sub-tree at this location was not yet loaded.

        Note: mutating operations on the tree might move this node deeper or higher up the tree. The
              current path leading to this node should not be assumed to be the database key for
              fetching this sub-tree. The `originalTreePath` field stores the correct path.

        Note: the base `hashOrRlp` field is guaranteed to be available, and can be used by the
              parent node to compute its own hash even when the tree isn't fully loaded. ]##
    originalTreePath*: Nibbles


  MptLeaf* = ref object of MptNode
    ##[ A MPT leaf holding a value.
    
        Note: we store the full path of the leaf, not just the remainder part, since using a
              sequence wouldn't have saved space in that case, and would have hurt performance.
              The part of the path that's relevant to that leaf starts at its logical depth. For
              example, if the leaf's logical depth is 10, then its remainder path is path[10..63].
              The merkle hash of the leaf is computed as per its logical depth. If the leaf is
              moved up or down the tree, it must be recomputed.
    ]##
    path*: Nibbles64
    value*: Buffer32


  MptAccount* = ref object of MptNode
    ## TBD
    path*: Nibbles64
    balance*: UInt256
    nonce*: uint64
    code*: seq[byte]
    codeHash*: ref array[32, byte]


  MptExtension* = ref object of MptNode
    ## An MPT Extension node. Guaranteed to have a non-nil, loaded child branch.
    remainderPath*: Nibbles62
    child*: MptBranch


  MptBranch* = ref object of MptNode
    ##[ A MPT Branch node. Holds up to 16 children. In case a child wasn't loaded, a `MptNotLoaded`
        place-holder is stored instead. In case a child doesn't exist (even in the database), it's
        nil. ]##
    children*: array[16, MptNode]


  DiffLayer* = ref object
    ##[ A "stacked tree" identified by its `diffHeight`. All tree mutation operations are performed
        on this object. If the root node is left `nil` (brand-new tree), it will be populated after
        a call to `put`. If it's set to the root of some other `DiffLayer`, mutation operations will
        perform copy-on-write and the root will point to the copy henceforth. Any new node created
        or cloned will have a `diffHeight` field matching this object's `diffHeight`.

        Note: the root might not necessarily be a `MptBranch`.
        
        Note: multiple instances might have the same `diffHeight`, e.g. in case of competing blocks.
    ]##
    diffHeight*: uint64
    root*: MptNode


  MptContinuation* = ref object
    ##[ This is returned by mutating operations when they encounter a part of the tree that's not
        loaded. After loading it, the continuation enables resuming the operation where it was left
        off, without traversing the tree again. ]##

    #[  An alternative to that would be to pass a function that enables operations to load missing
        parts of the tree themselves (from the database, which resides in higher-level code not
        accessible from here). But callbacks can cause all kinds of issues (especially across
        threads) so we opt not to. ]#
    parentNode*: MptBranch
    parentLogicalDepth*: uint8
    originalTreePath*: Nibbles



func `$`*(buffer: Buffer32): string =
  buffer.bytes[0..<buffer.len].toHex


func toSeq*(buffer: Buffer32): seq[byte] =
  buffer.bytes[0..<buffer.len]


func remainderPath*(leaf: MptLeaf, logicalDepth: uint8): Nibbles =
  result.len = 64 - logicalDepth
  for i in logicalDepth ..< 64:
    result[i] = leaf.path[i]


iterator enumerateTree*(node: MptNode, justTopTree: bool):
    tuple[node: MptNode, path: Nibbles, indexInBranch: Option[uint8]] =
  ## Iterates over all the nodes in the tree, depth-first. If a branch child
  ## exists but is not loaded, a `MptNotLoaded` instance is returned. Same for the
  ## child of an extension node.

  # In order to keep this iterator an efficient second-class citizen, we can't
  # use recursion, hence we store our position in a stack. The index denotes the
  # next child offset in the branch that should be processed.
  var stack: seq[tuple[branch: MptBranch, path: Nibbles, indexInBranch: uint8]]
  var current = node
  var path: Nibbles
  let diffHeight = node.diffHeight

  while true:

    # At the start of each iteration, we have an item that we can work with
    if stack.len > 0:
      yield (current, path, some(stack[^1].indexInBranch - 1))
    else: yield (current, path, none(uint8))

    # Extension node: yield its child branch and push the child onto the stack, in case it belongs
    # to the same diff layer as the root, or `justTopTree` is false
    if current of MptExtension:
      if not justTopTree or diffHeight == current.MptExtension.child.diffHeight:
        path = path.append current.MptExtension.remainderPath
        current = current.MptExtension.child
        yield (current, path, none(uint8))
        stack.add((current.MptBranch, path, 0.uint8))

    # MptBranch: push it onto the stack
    elif current of MptBranch:
      stack.add((current.MptBranch, path, 0.uint8))

    while stack.len > 0:
      # peek at the current branch we're working on
      let last = addr stack[^1]

      # if we traversed all children, pop it from the stack; we're done with it
      if last.indexInBranch == 16:
        discard stack.pop()

      # Return the child at `indexInBranch` and increase the index in case it exists and belongs
      # to the same diff layer as the root, or `justTopTree` is false
      elif last.branch.children[last.indexInBranch] != nil and
           (not justTopTree or diffHeight == last.branch.children[last.indexInBranch].diffHeight):
        current = last.branch.children[last.indexInBranch]
        path = last.path.append last.indexInBranch
        inc last.indexInBranch
        break

      # Child doesn't exist; skip it
      else:
        inc last.indexInBranch

    # if the stack is empty, we're done
    if stack.len == 0:
      break



proc maybePrintHashOrRlp(stream: Stream, hashOrRlp: Buffer32) =
  if hashOrRlp.len == 32:
    stream.write " Hash: "
    stream.writeAsHex hashOrRlp.bytes
  elif hashOrRlp.len > 0:
    stream.write " RLP:  "
    stream.writeAsHex hashOrRlp.bytes[0..<hashOrRlp.len]
    for _ in hashOrRlp.len..<32:
      stream.write "  "



proc printTree*(node: MptNode, stream: Stream, justTopTree: bool) =
  ## Prints the tree into the given `stream`.
  ## Outputs one line for each leaf, account, extension or branch in the tree,
  ## indented by depth, along with their properties.

  for node, path, indexInBranch in node.enumerateTree(justTopTree):
    if indexInBranch.isNone:
      for _ in 0'u8 ..< path.len:
        stream.write " "
    else:
      for _ in 0'u8 ..< path.len - 1:
        stream.write " "
      stream.write indexInBranch.get.byte.bitsToHex
    if node of MptBranch:
      stream.write "|"
      for _ in path.len ..< 65:
        stream.write " "
      stream.write "Branch       "
    elif node of MptExtension:
      for nibble in node.MptExtension.remainderPath.enumerate:
        stream.write nibble.bitsToHex
      for _ in path.len.int + node.MptExtension.remainderPath.len ..< 66:
        stream.write " "
      stream.write "Extension    "
    elif node of MptLeaf:
      for i in path.len ..< 64:
        stream.write node.MptLeaf.path[i].bitsToHex
      stream.write "  Leaf         "
    elif node of MptAccount:
      for i in path.len ..< 64:
        stream.write node.MptLeaf.path[i].bitsToHex
      stream.write "  Account.     "
    elif node of MptNotLoaded:
      for _ in path.len .. 66:
        stream.write " "
      stream.write "(not loaded) "
      stream.write "  originalTreePath: "
      stream.write $node.MptNotLoaded.originalTreePath
    else: doAssert false

    stream.maybePrintHashOrRlp node.hashOrRlp
    stream.write &"  depth: {path.len:2}  diff: {node.diffHeight}  path: {$path}"

    if node of MptLeaf:
      stream.write "  Value: "
      stream.writeAsHex node.MptLeaf.value.bytes[0..<node.MptLeaf.value.len]
    elif node of MptAccount:
      stream.write "  Balance: "
      stream.write node.MptAccount.balance
      stream.write "  Nonce: "
      stream.write node.MptAccount.nonce
    elif node of MptNotLoaded:
      stream.write "  originalTreePath: "
      stream.write $node.MptNotLoaded.originalTreePath
    stream.writeLine
