# Fluffy
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  std/sequtils,
  stew/byteutils,
  unittest2,
  stint,
  nimcrypto/hash,
  eth/trie/[hexary, db, trie_defs],
  ../../network/state/state_validation,
  ./state_test_helpers

proc getKeyBytes(i: int): seq[byte] =
  let hash = keccakHash(u256(i).toBytesBE())
  return toSeq(hash.data)

suite "MPT trie proof verification":
  test "Validate proof for existing value":
    let numValues = 1000
    var trie = initHexaryTrie(newMemoryDB())

    for i in 1 .. numValues:
      let bytes = getKeyBytes(i)
      trie.put(bytes, bytes)

    let rootHash = trie.rootHash()

    for i in 1 .. numValues:
      let
        kv = getKeyBytes(i)
        proof = trie.getTrieProof(kv)
        res = validateTrieProof(rootHash, kv.asNibbles(), proof)

      check:
        res.isOk()

  test "Validate proof for non-existing value":
    let numValues = 1000
    var trie = initHexaryTrie(newMemoryDB())

    for i in 1 .. numValues:
      let bytes = getKeyBytes(i)
      trie.put(bytes, bytes)

    let
      rootHash = trie.rootHash()
      key = getKeyBytes(numValues + 1)
      proof = trie.getTrieProof(key)
      res = validateTrieProof(rootHash, key.asNibbles(), proof)

    check:
      res.isErr()
      res.error() == "path contains more nibbles than expected for proof"

  test "Validate proof for empty trie":
    var trie = initHexaryTrie(newMemoryDB())

    let
      rootHash = trie.rootHash()
      key = "not-exist".toBytes
      proof = trie.getTrieProof(key)
      res = validateTrieProof(rootHash, key.asNibbles(), proof)

    check:
      res.isErr()
      res.error() == "invalid rlp node, expected 2 or 17 elements"

  test "Validate proof for one element trie":
    var trie = initHexaryTrie(newMemoryDB())

    let key = "k".toBytes
    trie.put(key, "v".toBytes)

    let
      rootHash = trie.rootHash
      proof = trie.getTrieProof(key)
      res = validateTrieProof(rootHash, key.asNibbles(), proof)

    check:
      res.isOk()

  test "Validate proof bytes":
    var trie = initHexaryTrie(newMemoryDB(), isPruning = false)

    trie.put("doe".toBytes, "reindeer".toBytes)
    trie.put("dog".toBytes, "puppy".toBytes)
    trie.put("dogglesworth".toBytes, "cat".toBytes)

    let rootHash = trie.rootHash

    block:
      let
        key = "doe".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isOk()

    block:
      let
        key = "dog".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isOk()

    block:
      let
        key = "dogglesworth".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isOk()

    block:
      let
        key = "dogg".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isErr()
        res.error() == "not enough nibbles to validate node prefix"

    block:
      let
        key = "dogz".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isErr()
        res.error() == "path contains more nibbles than expected for proof"

    block:
      let
        key = "doe".toBytes
        proof = newSeq[seq[byte]]().asTrieProof()
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isErr()
        res.error() == "proof is empty"

    block:
      let
        key = "doe".toBytes
        proof = @["aaa".toBytes, "ccc".toBytes].asTrieProof()
        res = validateTrieProof(rootHash, key.asNibbles(), proof)

      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"
