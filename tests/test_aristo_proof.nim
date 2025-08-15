# proof verification
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  std/sequtils,
  unittest2,
  stint,
  results,
  stew/byteutils,
  eth/trie/[hexary, db, trie_defs],
  ../execution_chain/db/aristo/aristo_proof

proc getKeyBytes(i: int): seq[byte] =
  @(u256(i).toBytesBE())

suite "Aristo proof verification":

  test "Validate proof for existing value":
    let numValues = 1000

    var db = newMemoryDB()
    var trie = initHexaryTrie(db)

    for i in 1..numValues:
      let
        key = getKeyBytes(i).keccak256()
        value = getKeyBytes(i)
      trie.put(key.data, value)

    for i in 1..numValues:
      let
        key = getKeyBytes(i).keccak256()
        value = getKeyBytes(i)
        proof = trie.getBranch(key.data)
        root = trie.rootHash()

      let proofRes = verifyProof(proof, root, key).expect("valid proof")
      check:
        proofRes.isSome()
        proofRes.get() == value

  test "Validate proof for non-existing value":
    let numValues = 1000
    var db = newMemoryDB()
    var trie = initHexaryTrie(db)

    for i in 1..numValues:
      let
        key = getKeyBytes(i).keccak256()
        value = getKeyBytes(i)
      trie.put(key.data, value)

    let
      nonExistingKey = toSeq(toBytesBE(u256(numValues + 1))).keccak256()
      proof = trie.getBranch(nonExistingKey.data)
      root = trie.rootHash()

    let proofRes = verifyProof(proof, root, nonExistingKey).expect("valid proof")
    check:
      proofRes.isNone()

  # The following test cases were copied from the Rust hexary trie implementation.
  # See here: https://github.com/citahub/cita_trie/blob/master/src/tests/mod.rs#L554
  test "Validate proof for empty trie":
    let db = newMemoryDB()
    var trie = initHexaryTrie(db)

    let
      proof = trie.getBranch("not-exist".toBytes.keccak256().data)
      res = verifyProof(proof, trie.rootHash, "not-exist".toBytes.keccak256())

    check:
      trie.rootHash == keccak256(emptyRlp)
      proof.len() == 1 # Note that the Rust implementation returns an empty list for this scenario
      proof == @[emptyRlp]
      res.isErr()

  test "Validate proof for one element trie":
    let db = newMemoryDB()
    var trie = initHexaryTrie(db)

    trie.put("k".toBytes.keccak256().data, "v".toBytes)

    let
      rootHash = trie.rootHash
      proof = trie.getBranch("k".toBytes.keccak256().data)
      res = verifyProof(proof, rootHash, "k".toBytes.keccak256()).expect("valid proof")

    check:
      proof.len() == 1
      res.isSome()
      res.get() == "v".toBytes

  test "Validate proof bytes":
    let db = newMemoryDB()
    var trie = initHexaryTrie(db)

    trie.put("doe".toBytes.keccak256().data, "reindeer".toBytes)
    trie.put("dog".toBytes.keccak256().data, "puppy".toBytes)
    trie.put("dogglesworth".toBytes.keccak256().data, "cat".toBytes)

    block:
      let
        rootHash = trie.rootHash
        proof = trie.getBranch("doe".toBytes.keccak256().data)
        res = verifyProof(proof, rootHash, "doe".toBytes.keccak256()).expect("valid proof")

      check:
        res.isSome()
        res.get() == "reindeer".toBytes

    block:
      let
        rootHash = trie.rootHash
        proof = trie.getBranch("dogg".toBytes.keccak256().data)
        res = verifyProof(proof, rootHash, "dogg".toBytes.keccak256()).expect("valid proof")

      check res.isNone()

    block:
      let
        proof = newSeq[seq[byte]]()
        res = verifyProof(proof, trie.rootHash, "doe".toBytes.keccak256())

      check res.isErr()

    block:
      let
        proof = @["aaa".toBytes, "ccc".toBytes]
        res = verifyProof(proof, trie.rootHash, "doe".toBytes.keccak256())

      check res.isErr()
