# proof verification
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  std/[tables, sequtils],
  unittest2,
  stint,
  results,
  stew/byteutils,
  eth/common/hashes,
  eth/trie/[hexary, db, trie_defs],
  ../execution_chain/db/aristo/aristo_proof

template getBytes(i: int): seq[byte] =
  @(u256(i).toBytesBE())

func toNodesTable(proofNodes: openArray[seq[byte]]): Table[Hash32, seq[byte]] =
  var nodes: Table[Hash32, seq[byte]]
  for n in proofNodes:
    nodes[keccak256(n)] = n
  nodes

suite "Aristo proof verification":
  const numValues = 1000

  setup:
    let db = newMemoryDB()
    var trie = initHexaryTrie(db)

  test "Validate proof for existing value":
    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes
      trie.put(key.data, value)

    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes
        root = trie.rootHash()
        proof = trie.getBranch(key.data)

      block:
        let leafValue = verifyProof(proof, root, key).expect("valid proof")
        check:
          leafValue.isSome()
          leafValue.get() == value

      block:
        let leafValue = verifyProof(toNodesTable(proof), root, key).expect("valid proof")
        check:
          leafValue.isSome()
          leafValue.get() == value

  test "Validate proof for existing value using nodes table":
    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes
      trie.put(key.data, value)

    let root = trie.rootHash()

    var proofNodes: seq[seq[byte]]
    for i in 1..numValues:
      let
        key = keccak256(getBytes(i))
        proof = trie.getBranch(key.data)

      # Put all proof nodes into a shared list
      for n in proof:
        proofNodes.add(n)

    # Build the nodes table
    let nodes = toNodesTable(proofNodes)

    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes

      let leafValue = verifyProof(nodes, root, key).expect("valid proof")
      check:
        leafValue.isSome()
        leafValue.get() == value

  test "Validate proof for non-existing value":
    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes
      trie.put(key.data, value)

    let
      nonExistingKey = toSeq(toBytesBE(u256(numValues + 1))).keccak256()
      root = trie.rootHash()
      proof = trie.getBranch(nonExistingKey.data)

    block:
      let leafValue = verifyProof(proof, root, nonExistingKey).expect("valid proof")
      check:
        leafValue.isNone()

    block:
      let leafValue = verifyProof(toNodesTable(proof), root, nonExistingKey).expect("valid proof")
      check:
        leafValue.isNone()

  test "Validate proof for non-existing value using nodes table":
    for i in 1..numValues:
      let
        indexBytes = getBytes(i)
        key = keccak256(indexBytes)
        value = indexBytes
      trie.put(key.data, value)

    let root = trie.rootHash()

    var proofNodes: seq[seq[byte]]
    for i in 1..numValues:
      let
        key = keccak256(getBytes(i))
        proof = trie.getBranch(key.data)

      # Put all proof nodes into a shared list
      for n in proof:
        proofNodes.add(n)

    # Build the nodes table
    let nodes = toNodesTable(proofNodes)

    let
      nonExistingKey = toSeq(toBytesBE(u256(numValues + 1))).keccak256()
      proof = trie.getBranch(nonExistingKey.data)

    let leafValue = verifyProof(nodes, root, nonExistingKey).expect("valid proof")
    check:
      leafValue.isNone()

  # The following test cases were copied from the Rust hexary trie implementation.
  # See here: https://github.com/citahub/cita_trie/blob/master/src/tests/mod.rs#L554
  test "Validate proof for empty trie":
    let
      key = keccak256("not-exist".toBytes)
      root = trie.rootHash()
      proof = trie.getBranch(key.data)
    check:
      root == keccak256(emptyRlp)
      proof == @[emptyRlp]

    block:
      let verifyRes = verifyProof(proof, root, key)
      check verifyRes.isErr()

    block:
      let verifyRes = verifyProof(toNodesTable(proof), root, key)
      check verifyRes.isErr()

  test "Validate proof for one element trie":
    let
      key = keccak256("k".toBytes)
      value = "v".toBytes
    trie.put(key.data, value)

    let
      root = trie.rootHash
      proof = trie.getBranch(key.data)
    check proof.len() == 1

    block:
      let leafValue = verifyProof(proof, root, key).expect("valid proof")
      check:
        leafValue.isSome()
        leafValue.get() == value

    block:
      let leafValue = verifyProof(toNodesTable(proof), root, key).expect("valid proof")
      check:
        leafValue.isSome()
        leafValue.get() == value

  test "Validate proof bytes":
    let
      key1 = keccak256("doe".toBytes)
      key2 = keccak256("dog".toBytes)
      key3 = keccak256("dogglesworth".toBytes)
      value1 = "reindeer".toBytes
      value2 = "puppy".toBytes
      value3 = "cat".toBytes

    trie.put(key1.data, value1)
    trie.put(key2.data, value2)
    trie.put(key3.data, value3)

    let
      root = trie.rootHash

    block:
      let
        proof = trie.getBranch(key1.data)
        leafValue1 = verifyProof(proof, root, key1).expect("valid proof")
        leafValue2 = verifyProof(toNodesTable(proof), root, key1).expect("valid proof")
      check:
        leafValue1.isSome()
        leafValue1.get() == value1
        leafValue2.isSome()
        leafValue2.get() == value1

    block:
      let
        key = keccak256("dogg".toBytes)
        proof = trie.getBranch(key.data)
        leafValue1 = verifyProof(proof, root, key).expect("valid proof")
        leafValue2 = verifyProof(toNodesTable(proof), root, key).expect("valid proof")
      check leafValue1.isNone()
      check leafValue2.isNone()

    block:
      let
        proof = newSeq[seq[byte]]()
        verifyRes1 = verifyProof(proof, root, key1)
        verifyRes2 = verifyProof(toNodesTable(proof), root, key1)
      check:
        verifyRes1.isErr()
        verifyRes2.isErr()

    block:
      let
        proof = @["aaa".toBytes, "ccc".toBytes]
        verifyRes1 = verifyProof(proof, root, key1)
        verifyRes2 = verifyProof(toNodesTable(proof), root, key1)
      check:
        verifyRes1.isErr()
        verifyRes2.isErr()
