#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/streams,
  stint,
  utils,
  mpt_nibbles


#[
 features:
    diff layers
    accounts node
    lazy hashing
    ...
]#

# how to make certain fields visible just to mpt_* modules?
# perf: check possibility of using enum types; save cost of virtual methods

type
  MptNode* = ref object of RootObj
    diffHeight*: uint64
    logicalDepth*: uint8
    # encodedTreeSize: uint64
    # depthInBlob

  MptLeaf* = ref object of MptNode
    path*: Nibbles64
    value*: seq[byte]

  MptAccount* = ref object of MptNode
    path*: Nibbles64
    balance*: UInt256
    nonce*: uint64
    code*: seq[byte]
    codeHash*: ref array[32, byte]

  MptExtension* = ref object of MptNode
    remainderPath*: Nibbles
    child*: MptBranch
    childHashOrRlp*: seq[byte]

  MptBranch* = ref object of MptNode
    childExistFlags*: uint16 # most significant bit = child #0
    children*: array[16, MptNode]
    childHashesOrRlps*: array[16, seq[byte]]

  DiffLayer* = object
    diffHeight*: uint64
    root*: MptNode
    hash*: ref array[32, byte]

# todo: list of procs/funcs/methods that can be called, incl. from other files



func childExists*(branch: MptBranch, offset: uint8): bool =
  (branch.childExistFlags and (0x8000.uint16 shr offset.uint16)) > 0


# TODO: remove depth


iterator enumerateTree*(node: MptNode):
    tuple[node: MptNode, index: uint8, maybeHash: seq[byte]] =
  ## Iterates over all the nodes in the tree, depth-first. If a branch child
  ## exists but is not loaded, nil is returned. Same for the child of an
  ## extension node.

  # In order to keep this iterator an efficient second-class citizen, we can't
  # use recursion, hence we store our position in a stack. The index denotes the
  # next child offset in the branch that should be processed.
  var stack: seq[tuple[branch: MptBranch, index: uint8]]

  var hash: seq[byte]
  var current = node
  var index = 0.uint8 # the index of current in its parent (0 if root)

  while true:

    # At the start of each iteration, we have an item that we can work with
    yield (current, index, hash)

    # Extension node: yield its child branch and push the child onto the stack
    if current of MptExtension:
      index = current.MptExtension.remainderPath[0]
      hash = current.MptExtension.childHashOrRlp
      current = current.MptExtension.child
      yield (current, index, hash)
      stack.add((current.MptBranch, 0.uint8))

    # MptBranch: push it onto the stack
    elif current of MptBranch:
      stack.add((current.MptBranch, 0.uint8))

    while stack.len > 0:
      # peek at the current branch we're working on
      let last = addr stack[^1]

      # if we traversed all children, pop it from the stack; we're done with it
      if last.index == 16:
        discard stack.pop()

      # If the child at `offset` exists, return it and increase the offset.
      # Note that it might exist but not be loaded, in which case we return nil.
      elif last.branch.childExists(last.index):
        current = last.branch.children[last.index]
        index = last.index
        hash = last.branch.childHashesOrRlps[last.index]
        inc last.index
        break

      # Child doesn't exist; skip it
      else:
        inc last.index

    # if the stack is empty, we're done
    if stack.len == 0:
      break



proc printHash(stream: Stream, depth: uint8, hash: seq[byte], rootHash: ref array[32, byte] = nil) =
  if depth == 0 and rootHash != nil:
    stream.write " Hash: "
    stream.writeAsHex rootHash[]
  elif hash.len > 0:
    stream.write " Hash: "
    stream.writeAsHex hash



proc printTree*(node: MptNode, stream: Stream, rootHash: ref array[32, byte] = nil) =
  ## Prints the tree into the given `stream`.
  ## Outputs one line for each leaf, account, extension or branch in the tree,
  ## indented by depth, along with their properties.

  for n, parentIndex, hash in node.enumerateTree:
    for _ in 0 ..< n.logicalDepth.int:
      stream.write " "
    if n.logicalDepth != 0:
      stream.write parentIndex.bitsToHex
    if n of MptBranch:
      stream.write '|'
      for _ in n.logicalDepth.int ..< 65:
        stream.write " "
      stream.write "Branch       "
      stream.printHash n.logicalDepth, hash, rootHash
    elif n of MptExtension:
      for i in 0 ..< n.MptExtension.remainderPath.len:
        stream.write n.MptExtension.remainderPath[i].bitsToHex
      for _ in n.logicalDepth.int + n.MptExtension.remainderPath.len ..< 66:
        stream.write " "
      stream.write "Extension    "
      stream.printHash n.logicalDepth, hash, rootHash
    elif n of MptLeaf:
      for i in n.logicalDepth ..< 64:
        stream.write n.MptLeaf.path[i].bitsToHex
      stream.write "  Leaf         "
      stream.printHash n.logicalDepth, hash, rootHash
      stream.write "  Value: "
      stream.writeAsHex n.MptLeaf.value
    elif n of MptAccount:
      for i in n.logicalDepth ..< 64:
        stream.write n.MptLeaf.path[i].bitsToHex
      stream.write "  Account.     "
      stream.printHash n.logicalDepth, hash, rootHash
      stream.write "  Balance: "
      stream.write n.MptAccount.balance
      stream.write "  Nonce: "
      stream.write n.MptAccount.nonce
    elif n == nil:
      for _ in n.logicalDepth.int .. 66:
        stream.write " "
      stream.write "(not loaded) "
      stream.printHash n.logicalDepth, hash, rootHash
    else: doAssert false
    stream.writeLine

