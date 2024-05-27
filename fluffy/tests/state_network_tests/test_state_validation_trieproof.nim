# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
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
  ../../network/state/[state_content, state_validation],
  ./state_test_helpers

proc getKeyBytes(i: int): seq[byte] =
  let hash = keccakHash(u256(i).toBytesBE())
  return toSeq(hash.data)

suite "State Validation - validateTrieProof":
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
        res = validateTrieProof(rootHash, kv.asNibbles(), proof, true)

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
      res = validateTrieProof(rootHash, key.asNibbles(), proof, true)

    check:
      res.isErr()
      res.error() == "path contains more nibbles than expected for proof"

  test "Validate proof for empty trie":
    var trie = initHexaryTrie(newMemoryDB())

    let
      rootHash = trie.rootHash()
      key = "not-exist".toBytes
      proof = trie.getTrieProof(key)
      res = validateTrieProof(rootHash, key.asNibbles(), proof, true)

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
      res = validateTrieProof(rootHash, key.asNibbles(), proof, true)

    check:
      res.isOk()

  test "Validate proof bytes - 3 keys":
    var trie = initHexaryTrie(newMemoryDB())

    trie.put("doe".toBytes, "reindeer".toBytes)
    trie.put("dog".toBytes, "puppy".toBytes)
    trie.put("dogglesworth".toBytes, "cat".toBytes)

    let rootHash = trie.rootHash

    block:
      let
        key = "doe".toBytes
        proof = trie.getTrieProof(key)
      check validateTrieProof(rootHash, key.asNibbles(), proof, true).isOk()

    block:
      let
        key = "dog".toBytes
        proof = trie.getTrieProof(key)
      check validateTrieProof(rootHash, key.asNibbles(), proof, true).isOk()

    block:
      let
        key = "dogglesworth".toBytes
        proof = trie.getTrieProof(key)
      check validateTrieProof(rootHash, key.asNibbles(), proof, true).isOk()

    block:
      let
        key = "dogg".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof, true)
      check:
        res.isErr()
        res.error() == "not enough nibbles to validate node prefix"

    block:
      let
        key = "dogz".toBytes
        proof = trie.getTrieProof(key)
        res = validateTrieProof(rootHash, key.asNibbles(), proof, true)
      check:
        res.isErr()
        res.error() == "path contains more nibbles than expected for proof"

    block:
      let
        key = "doe".toBytes
        proof = newSeq[seq[byte]]().asTrieProof()
        res = validateTrieProof(rootHash, key.asNibbles(), proof, true)
      check:
        res.isErr()
        res.error() == "proof is empty"

    block:
      let
        key = "doe".toBytes
        proof = @["aaa".toBytes, "ccc".toBytes].asTrieProof()
        res = validateTrieProof(rootHash, key.asNibbles(), proof, true)
      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"

  test "Validate proof bytes - 4 keys":
    var trie = initHexaryTrie(newMemoryDB())

    let
      # leaf nodes
      kv1 = "0xa7113550".hexToSeqByte()
      kv2 = "0xa77d33".hexToSeqByte() # without key end
      kv3 = "0xa7f93650".hexToSeqByte()
      kv4 = "0xa77d39".hexToSeqByte() # without key end

      kv5 = "".hexToSeqByte() # root/first extension node
      kv6 = "0xa7".hexToSeqByte() # first branch node

      # leaf nodes without key ending
      kv7 = "0xa77d33".hexToSeqByte()
      kv8 = "0xa77d39".hexToSeqByte()

      # failure cases
      kv9 = "0xa0".hexToSeqByte()
      kv10 = "0xa77d".hexToSeqByte()
      kv11 = "0xa71135".hexToSeqByte()
      kv12 = "0xa711355000".hexToSeqByte()
      kv13 = "0xa711".hexToSeqByte()
      kv14 = "0xa77d3370".hexToSeqByte()
      kv15 = "0xa77d3970".hexToSeqByte()

    trie.put(kv1, kv1)
    trie.put(kv2, kv2)
    trie.put(kv3, kv3)
    trie.put(kv4, kv4)

    let rootHash = trie.rootHash

    check:
      validateTrieProof(rootHash, kv1.asNibbles(), trie.getTrieProof(kv1), true).isOk()
      validateTrieProof(rootHash, kv2.asNibbles(), trie.getTrieProof(kv2), false).isOk()
      validateTrieProof(rootHash, kv3.asNibbles(), trie.getTrieProof(kv3), true).isOk()
      validateTrieProof(rootHash, kv4.asNibbles(), trie.getTrieProof(kv4), false).isOk()
      validateTrieProof(rootHash, kv5.asNibbles(), trie.getTrieProof(kv5)).isOk()
      validateTrieProof(rootHash, kv6.asNibbles(), trie.getTrieProof(kv6)).isOk()
      validateTrieProof(rootHash, kv7.asNibbles(), trie.getTrieProof(kv7)).isOk()
      validateTrieProof(rootHash, kv8.asNibbles(), trie.getTrieProof(kv8)).isOk()

      validateTrieProof(rootHash, kv9.asNibbles(), trie.getTrieProof(kv9)).isErr()
      validateTrieProof(rootHash, kv10.asNibbles(), trie.getTrieProof(kv10)).isErr()
      validateTrieProof(rootHash, kv11.asNibbles(), trie.getTrieProof(kv11)).isErr()
      validateTrieProof(rootHash, kv12.asNibbles(), trie.getTrieProof(kv12)).isErr()
      validateTrieProof(rootHash, kv13.asNibbles(), trie.getTrieProof(kv13)).isErr()

      validateTrieProof(rootHash, kv14.asNibbles(), trie.getTrieProof(kv14), false)
      .isErr()

      validateTrieProof(rootHash, kv15.asNibbles(), trie.getTrieProof(kv15), false)
      .isErr()
