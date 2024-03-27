# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/streams,
  stint,
  ../../vendor/nim-eth/eth/common/eth_hash,
  utils,
  mpt_nibbles

type
  MptNode* = ref object of RootObj
    diffHeight*: uint64
    hash*: ref KeccakHash
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
    childHash*: ref array[32, byte]

  MptBranch* = ref object of MptNode
    childExistFlags*: uint16 # most significant bit = child #0
    children*: array[16, MptNode]
    childHashes*: array[16, ref array[32, byte]]

  DiffLayer* = object
    diffHeight*: uint64
    root*: MptNode


func childExists*(branch: MptBranch, offset: uint8): bool =
  (branch.childExistFlags and (0x8000.uint16 shr offset.uint16)) > 0


iterator enumerateTree*(node: MptNode):
    tuple[node: MptNode, depth: uint8, index: uint8] =
  ## Iterates over all the nodes in the tree, depth-first. If a branch child
  ## exists but is not loaded, nil is returned. Same for the child of an
  ## extension node.

  # In order to keep this iterator an efficient second-class citizen, we can't
  # use recursion, hence we store our position in a stack. The depth denotes
  # the logical depth of the branch (not tree depth), and the index denotes the
  # next child offset in the branch that should be processed.
  var stack: seq[tuple[branch: MptBranch, index: uint8, depth: uint8]]

  var current = node
  var index = 0.uint8 # the index of current in its parent (0 if root)
  var depth = 0.uint8 # the logical depth of current (not the tree depth)

  while true:

    # At the start of each iteration, we have an item that we can work with
    yield (current, index, depth)

    # Extension node: yield its child branch and push the child onto the stack
    if current of MptExtension:
      index = current.MptExtension.remainderPath[0]
      depth += current.MptExtension.remainderPath.len.uint8
      current = current.MptExtension.child
      yield (current, index, depth)
      stack.add((current.MptBranch, 0.uint8, depth))

    # MptBranch: push it onto the stack
    elif current of MptBranch:
      stack.add((current.MptBranch, 0.uint8, depth))

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
        depth = last.depth
        inc last.index
        break

      # Child doesn't exist; skip it
      else:
        inc last.index

    # if the stack is empty, we're done
    if stack.len == 0:
      break


proc printTree*(node: MptNode, stream: Stream) =
  ## Prints the tree into the given `stream`.
  ## Outputs one line for each leaf, account, extension or branch in the tree,
  ## indented by depth, along with their properties.
  #stream.write("<Tree root>                                                           Branch. Commitment: ")
  #stream.writeAsHex(node.commitment.serializePoint)
  #stream.writeLine()
  for n, parentIndex, depth in node.enumerateTree():
    for _ in 0 ..< depth.int:
      stream.write(" ")
    #if depth > 0: # if non-root
    #  stream.writeAsHex(parentIndex.byte)
    if n of MptBranch:
      stream.write('|')
      for _ in depth.int ..< 65:
        stream.write(" ")
      stream.write("Branch.")
      #stream.writeAsHex(n.commitment.serializePoint)
      stream.writeLine()
    elif n of MptExtension:
      for i in 0 ..< n.MptExtension.remainderPath.len:
        stream.write(n.MptExtension.remainderPath[i].bitsToHex)
      for _ in depth.int + n.MptExtension.remainderPath.len ..< 66:
        stream.write(" ")
      stream.write("Extension.")
      #stream.writeAsHex(n.commitment.serializePoint)
      stream.writeLine()
    elif n of MptLeaf:
      #stream.write(parentIndex.bitsToHex)
      for i in depth ..< 64:
        stream.write(n.MptLeaf.path[i].bitsToHex)
      stream.write("  Leaf.      Value: ")
      stream.writeAsHex(n.MptLeaf.value)
      stream.writeLine()
    elif n of MptAccount:
      #stream.write(parentIndex.bitsToHex)
      for i in depth ..< 64:
        stream.write(n.MptLeaf.path[i].bitsToHex)
      stream.write("  Account.   Balance: ")
      stream.write(n.MptAccount.balance)
      stream.write(", Nonce: ")
      stream.write(n.MptAccount.nonce)
      stream.writeLine()
    elif n == nil:
      for _ in depth.int .. 66:
        stream.write(" ")
      stream.write("(node not loaded). Hash: ")
      #stream.writeAsHex(n.commitment.serializePoint)
      stream.writeLine()
    else: doAssert false

