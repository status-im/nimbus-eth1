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
  std/times,
  std/sequtils,
  std/strformat,
  #unittest2,
  stint,
  nimcrypto/hash,
  #stew/byteutils,
  ../../vendor/nim-stint/stint,
  ../../vendor/nim-eth/eth/trie/hexary,
  ../../vendor/nim-eth/eth/trie/db,
  ../../vendor/nim-eth/eth/trie/trie_defs,
  ../../vendor/nim-eth/eth/trie/hexary_proof_verification,
  ../../vendor/nim-eth/eth/common/eth_hash,
  mpt,
  mpt_rlp_hash,
  mpt_nibbles,
  utils

from ../../vendor/nimcrypto/nimcrypto/utils import fromHex

# import std/atomics
# proc atomicInc[T: SomeInteger](location: var Atomic[T]; value: T = 1)


func shallowCloneMptNode(node: MptNode): MptNode =
  if node of MptLeaf:
    result = MptLeaf()
    result.MptLeaf[] = node.MptLeaf[]

  elif node of MptAccount:
    result = MptAccount()
    result.MptAccount[] = node.MptAccount[]

  elif node of MptExtension:
    result = MptExtension()
    result.MptExtension[] = node.MptExtension[]

  else:
    result = MptBranch()
    result.MptBranch[] = node.MptBranch[]


func stackDiffLayer*(base: DiffLayer): DiffLayer =
  ## Create a new diff layer, using a shallow clone of the base layer's root and
  ## an incremented diffHeight. Descendants will be cloned when they're on the
  ## path of a node being updated.
  if base.root != nil:
    result.root = base.root.shallowCloneMptNode
  result.diffHeight = base.diffHeight + 1


proc put*(diff: var DiffLayer, key: Nibbles64, value: seq[byte]) =
  
  # No root? Store a leaf
  if diff.root == nil:
    diff.root = MptLeaf(diffHeight: diff.diffHeight, path: key, value: value)

  # Root is a leaf? (cloned)
  elif diff.root of MptLeaf:

    # Same path? Update value
    if diff.root.MptLeaf.path == key:
      diff.root.MptLeaf.value = value

    # Different? Find the point at which they diverge
    else:
      var divergeDepth = 0
      while diff.root.MptLeaf.path[divergeDepth] == key[divergeDepth]:
        inc divergeDepth

      # Create a branch to hold the current leaf, and add a new leaf
      let rootNibble = diff.root.MptLeaf.path[divergeDepth]
      let keyNibble = key[divergeDepth]
      let bits = (0x8000.uint16 shr rootNibble) or (0x8000.uint16 shr keyNibble)
      let branch = MptBranch(diffHeight: diff.diffHeight, childExistFlags: bits)
      branch.children[rootNibble] = diff.root
      branch.children[keyNibble] = MptLeaf(diffHeight: diff.diffHeight, path: key, value: value)

      # Diverging right from the start? Replace the root node with the branch
      if divergeDepth == 0:
        diff.root = branch

      # Oterwise, replace the root node with an extension node that holds the
      # branch. The extension node's remainder path extends till the point of
      # divergence.
      else:
        diff.root = MptExtension(diffHeight: diff.diffHeight, child: branch,
          remainderPath: key.slice(0, divergeDepth))

  # Root is an extension?
  elif diff.root of MptExtension:
    let extPath = diff.root.MptExtension.remainderPath

    # The key path starts with a different nibble? Replace the root by a branch,
    # put the current extension in it (minus the leading nibble) and add a new
    # leaf
    if extPath[0] != key[0]:
      let bits = (0x8000.uint16 shr extPath[0]) or (0x8000.uint16 shr key[0])
      let branch = MptBranch(diffHeight: diff.diffHeight, childExistFlags: bits)
      branch.children[extPath[0]] = MptExtension(diffHeight: diff.diffHeight,
        child: diff.root.MptExtension.child, remainderPath: extPath.slice(1, extPath.len-1))
      branch.children[key[0]] = MptLeaf(diffHeight: diff.diffHeight, path: key, value: value)
      diff.root = branch

  else: doAssert false

const sampleKvps = @[
   ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "1234"),
   ("0123456789abcdef0123456789abcdef88888888888888888888888888888888", "1234"),
  #("0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000123456789abcdef0123456789abcdef"),
  #("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0000000000000000000000000000000000000000000000000000000000000002"),
  # ("1100000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000003"),
  # ("2200000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000004"),
  # ("2211000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000005"),
  # ("3300000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000006"),
  # ("3300000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000007"),
  # ("33000000000000000000000000000000000000000000000000000000000000ff", "0000000000000000000000000000000000000000000000000000000000000008"),
  # ("4400000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000009"),
  # ("4400000011000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000000000000a"),
  # ("5500000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000000000000b"),
  # ("5500000000000000000000000000000000000000000000000000000000001100", "000000000000000000000000000000000000000000000000000000000000000c"),
]

iterator hexKvpsToBytes32(kvps: openArray[tuple[key: string, value: string]]):
    tuple[key: array[32, byte], value: seq[byte]] =
  for (hexKey, hexValue) in kvps:
    yield (hexToBytesArray[32](hexKey), hexValue.fromHex)

let emptyRlpHash = "56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421".fromHex
var db2 = newMemoryDB()
var trie = initHexaryTrie(db2)
var container: DiffLayer

for (key, value) in sampleKvps.hexKvpsToBytes32():
  echo &"Adding {key.toHex} --> {value.toHex}"
  #let key = "A".keccakHash.data
  trie.put(key, value)
  container.put(Nibbles64(bytes: key), value)

echo "\nDumping kvps in DB"
for kvp in db2.pairsInMemoryDB():
  if kvp[0][0..^1] != emptyRlpHash[0..^1]:
    echo &"{kvp[0].toHex} => {kvp[1].toHex}"

echo "\nDumping tree:\n"
container.root.printTree(newFileStream(stdout))

echo ""
echo &"Legacy root hash: {trie.rootHash.data.toHex}" #"0xe9e2935138352776cad724d31c9fa5266a5c593bb97726dd2a908fe6d53284df"
echo &"BART   root hash: {container.root.getOrComputeHash.data.toHex}"
