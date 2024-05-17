#[  Nimbus
    Copyright (c) 2021-2024 Status Research & Development GmbH
    Licensed and distributed under either of
      * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
      * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
    at your option. This file may not be copied, modified, or distributed except according to those terms. ]#


import
  std/[streams, strformat, os, random, times, tables],
  stint,
  unittest2,
  nimcrypto/hash,
  ../../../vendor/nim-eth/eth/trie/hexary,
  ../../../vendor/nim-eth/eth/trie/db,
  ../../../vendor/nim-eth/eth/common/eth_hash,
  ../[mpt, mpt_rlp_hash, mpt_nibbles, mpt_operations, utils, config]

import ../mpt {.all.}

from ../../../vendor/nimcrypto/nimcrypto/utils import fromHex

randomize()
let randomSeed = rand(1_000_000_000) # In case a test fails, manually override the seed here to reproduce it
echo "Random seed: " & $randomSeed
var randomGenerator = initRand(randomSeed)

proc makeRandomBytes32(): array[32, byte] =
  result[ 0 ..<  8] = cast[array[8, byte]](randomGenerator.next())
  result[ 8 ..< 16] = cast[array[8, byte]](randomGenerator.next())
  result[16 ..< 24] = cast[array[8, byte]](randomGenerator.next())
  result[24 ..< 32] = cast[array[8, byte]](randomGenerator.next())

iterator hexKvpsToBytes32(kvps: openArray[tuple[key: string, value: string]]):
    tuple[key: array[32, byte], value: seq[byte]] =
  for (hexKey, hexValue) in kvps:
    yield (hexToBytesArray[32](hexKey), hexValue.fromHex)


suite "Legacy compatibility":

  let emptyValue = hexToBytesArray[32]("0000000000000000000000000000000000000000000000000000000000000000").toBuffer32

  func makeKey(hex: string): Nibbles64 =
    Nibbles64(bytes: hexToBytesArray[32](hex))

  echo ""

  test "Extension node":

    # case #1
    var tree = DiffLayer(root: nil)
    discard tree.put(makeKey("9100000000000000000000000000000000000000000000000000000000000000"), emptyValue)
    discard tree.put(makeKey("9200000000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)
    discard tree.put(makeKey("b000000000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)

    # case #2
    tree = DiffLayer(root: nil)
    discard tree.put(makeKey("56789a1000000000000000000000000000000000000000000000000000000000"), emptyValue)
    discard tree.put(makeKey("56789a2000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)
    discard tree.put(makeKey("01bc000000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)

    # case #3
    tree = DiffLayer(root: nil)
    discard tree.put(makeKey("56789a1000000000000000000000000000000000000000000000000000000000"), emptyValue)
    discard tree.put(makeKey("56789a2000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)
    discard tree.put(makeKey("56789b0000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)

    # case #4
    tree = DiffLayer(root: nil)
    discard tree.put(makeKey("56789a1000000000000000000000000000000000000000000000000000000000"), emptyValue)
    discard tree.put(makeKey("56789a2000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)
    discard tree.put(makeKey("56bc000000000000000000000000000000000000000000000000000000000000"), emptyValue)
    #tree.root.printTree(newFileStream(stdout), justTopTree=false)


  test "Populate trees and compare":

    const sampleKvps = @[
      ("20001ab975821a408aa3fabe8132f5915cd05054652f879f0aedf0c573dfb336", "2d9e782d37eec375ab9950fbdd1e9a9b983bbfe71ceb4b073411a3c821927f07"),
      ("ed812738fb4aec6f6b8db0b372e5f8039aa85d47fe2845edb219301acec34ada", "74e931d10d7e1b1ca9f0811cdf80999254971c029981ceaebde2924a6f97a17c"),
    ]

    var db = newMemoryDB()
    var trie = initHexaryTrie(db)
    var tree = DiffLayer(root: nil)

    for (key, value) in sampleKvps.hexKvpsToBytes32():
      when TraceLogs: echo &"Adding {key.toHex} --> {value.toHex}"
      trie.put(key, value)
      discard tree.put(Nibbles64(bytes: key), value.toBuffer32)
    discard tree.rootHash

    when TraceLogs:

      echo "\nDumping kvps in Legacy DB"
      for kvp in db.pairsInMemoryDB():
        if kvp[0][0..^1] != emptyRlpHash[0..^1]:
          echo &"{kvp[0].toHex} => {kvp[1].toHex}"

      echo ""
      echo "\nDumping tree:\n"
      tree.root.printTree(newFileStream(stdout), justTopTree=false)

      echo ""
      echo &"Legacy root hash: {trie.rootHash.data.toHex}"
      echo &"BART   root hash: {$tree.rootHash}"

    check trie.rootHash.data == tree.rootHash


  test "Fuzzing":
    const numRuns = 5
    const maxBlocksPerRun = 200
    const maxNewKeysPerBlock = 2000
    const maxModifiedOldKeysPerBlock = 500
    const oldChainsRatio  = 0.1 # 0.1  The probability to base a block on top of another block that's earlier than the last one (0.0 - 1.0)


    type BlockState = ref object
      legacyTrie: ref HexaryTrie
      legacyTrieHash: KeccakHash
      tree: DiffLayer
      treeHash: Buffer32
      newKeys: seq[array[32, byte]]
      newKvps: Table[array[32, byte], seq[byte]]
      modifiedKvps: Table[array[32, byte], seq[byte]]

    # number of times to run whole test
    for runIteration in 0 ..< numRuns:

      let db = newMemoryDB()
      var lastTrie: ref HexaryTrie
      new lastTrie
      lastTrie[] = initHexaryTrie(db, isPruning = false)
      var lastTree = DiffLayer(root: nil)
      var blocks: seq[BlockState]

      # Number of "blocks" in that run
      for blockNumber in 0 ..< randomGenerator.rand(maxBlocksPerRun):
        var state = BlockState()

        # Base the "block" on top of the previous one 90% of the time; 10% of the time on top of some other random block
        if randomGenerator.rand(1f) > oldChainsRatio or blocks.len < 2:
          new state.legacyTrie
          state.legacyTrie[] = initHexaryTrie(db, lastTrie[].rootHash, isPruning = false)
          state.tree = stackDiffLayer(lastTree)
        else:
          let randomBlock = blocks[randomGenerator.rand(blocks.len-2)]
          new state.legacyTrie
          state.legacyTrie[] = initHexaryTrie(db, randomBlock.legacyTrieHash, isPruning = false)
          state.tree = stackDiffLayer(randomBlock.tree)
        lastTrie = state.legacyTrie
        lastTree = state.tree

        # Add some random number of random key-values to that "block"
        for _ in 0 ..< 1 + randomGenerator.rand(maxNewKeysPerBlock-1):
          let key = makeRandomBytes32()
          let randomLength = 1 + randomGenerator.rand(31)
          let value = makeRandomBytes32()[0..<randomLength]
          state.newKvps[key] = value
          state.newKeys.add key
          state.legacyTrie[].put(key, value)
          discard state.tree.put(Nibbles64(bytes: key), value.toBuffer32)

        # Modify some random number of keys from previous blocks (override in current block)
        if blocks.len > 0:
          for _ in 0 ..< randomGenerator.rand(maxModifiedOldKeysPerBlock):
            let randomBlock = blocks[randomGenerator.rand(blocks.len-1)]
            let oldKey = randomBlock.newKeys[randomGenerator.rand(randomBlock.newKeys.len-1)]
            let randomLength = 1 + randomGenerator.rand(31)
            let value = makeRandomBytes32()[0..<randomLength]
            state.modifiedKvps[oldKey] = value
            state.legacyTrie[].put(oldKey, value)
            discard state.tree.put(Nibbles64(bytes: oldKey), value.toBuffer32)

        # Compare the hashes of legacy and DiffLayer
        if state.legacyTrie[].rootHash.data != state.tree.rootHash:
          var hashes: Table[string, bool]
          echo &"Error at run iteration #{runIteration}, block #{blockNumber}"
          echo &"Legacy root hash: {state.legacyTrie[].rootHash.data.toHex}"
          echo "\nDumping kvps in Legacy DB"
          for kvp in db.pairsInMemoryDB():
            if kvp[0][0..^1] != emptyRlpHash[0..^1]:
              echo &"{kvp[0].toHex} => {kvp[1].toHex}"
              hashes[kvp[0].toHex] = true
          echo "\nDumping tree:\n"
          state.tree.root.printTree(newFileStream(stdout), false)
          for node, _, _ in state.tree.root.enumerateTree(false):
            let hash = node.hashOrRlp.bytes[0..<node.hashOrRlp.len].toHex
            if not hashes.hasKey(hash):
              echo "Hash in tree not found in Legacy: " & hash
          doAssert false

        state.legacyTrieHash = state.legacyTrie[].rootHash
        blocks.add state

        # Print state
        when false:
          echo &"\n\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Tree:\n"
          state.tree.root.printTree(newFileStream(stdout), justTopTree=false)

          echo &"\n\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Top tree:\n"
          state.tree.root.printTree(newFileStream(stdout), justTopTree=true)

          echo &"\n\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Expected new key-values:\n"
          for key, value in state.newKvps:
            echo &"{key.toHex}  -->  {value.toHex}"

          echo &"\n\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Found key-values in top tree:\n"
          for node, path, _ in state.tree.root.enumerateTree(justTopTree = true):
            if node of MptLeaf:
              echo &"{node.MptLeaf.path.bytes.toHex}  -->  {$node.MptLeaf.value}"

      # Verify the new key-values in all blocks in that run
      for blockNumber, state in blocks.pairs:
        for key, value in state.newKvps:
          let (leaf, _) = state.tree.tryGet Nibbles64(bytes: key)
          if leaf == nil:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. New key not found: {key.toHex}"
            check leaf != nil
          elif leaf.value.toSeq != value:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Unexpeced new key-value: {key.toHex}  -->  {value.toHex}"
            check leaf.value.toSeq == value
          elif leaf.diffHeight != state.tree.diffHeight:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. New key has wrong diff height: {key.toHex}. Got: {leaf.diffHeight}, expected: {state.tree.diffHeight}"
            check leaf.diffHeight == state.tree.diffHeight
          check leaf != nil and leaf.value.toSeq == value

      # Verify the modified key-values in all blocks in that run
      for blockNumber, state in blocks.pairs:
        for key, value in state.modifiedKvps:
          let (leaf, _) = state.tree.tryGet Nibbles64(bytes: key)
          if leaf == nil:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Modified key not found: {key.toHex}"
            check leaf != nil
          elif leaf.value.toSeq != value:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Unexpeced modified key-value: {key.toHex}  -->  {value.toHex}"
            check leaf.value.toSeq == value
          elif leaf.diffHeight != state.tree.diffHeight:
            echo &"\nRun iteration #{runIteration}, block #{blockNumber}, height {state.tree.diffHeight}. Modified key has wrong diff height: {key.toHex}. Got: {leaf.diffHeight}, expected: {state.tree.diffHeight}"
            check leaf.diffHeight == state.tree.diffHeight
          check leaf != nil and leaf.value.toSeq == value

      # Nullify the hashes of all nodes, recompute them in random blocks order and compare them again with legacy hashes
      for state in blocks:
        for node, _, _ in state.tree.root.enumerateTree(justTopTree=true):
          node.hashOrRlp.len = 0
      randomGenerator.shuffle(blocks)
      for state in blocks:
        check state.tree.rootHash == state.legacyTrie[].rootHash.data



  test "randomValues_1000":

    ## Writes a larger-ish tree with random nodes to a file
    createDir "testResults"
    var startTime = cpuTime()

    var tree = DiffLayer(root: nil)
    for i in 0..<1000:
      discard tree.put(key = Nibbles64(bytes: makeRandomBytes32()), value = makeRandomBytes32().toBuffer32)

    var hashTime = cpuTime()
    tree.root.computeHashOrRlpIfNeeded 0
    var endTime = cpuTime()

    var file = open("testResults/randomValues_1000", fmWrite)
    defer: close(file)
    tree.root.printTree(newFileStream(file), justTopTree=false)
    echo "Tree dumped to 'testResults/mpt_randomValues_1000'"
    echo &"Time to populate tree: {hashTime - startTime:.3f} secs"
    echo &"Time to compute root hash: {endTime - hashTime:.3f} secs"


# getOccupiedMem

# todo: comparative performance test of small tree and big tree
