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

from ../../../vendor/nimcrypto/nimcrypto/utils import fromHex


proc compareWithLegacy(kvps: varargs[tuple[key:string, value:string]]) =
  var diff = DiffLayer()
  var db = newMemoryDB()
  var trie = initHexaryTrie(db)
  for kvp in kvps:
    when TraceLogs:
      echo &"Adding {kvp.key} => '{kvp.value}'"
    let key = hexToBytesArray[32](kvp.key)
    if kvp.value.len mod 2 == 1:
      raise newException(ValueError, "odd length hex string")
    let value = kvp.value.fromHex
    discard diff.put(Nibbles64(bytes: key), value.toBuffer32)
    trie.put(key, value)
  when TraceLogs:
    for kvp in db.pairsInMemoryDB():
      if kvp[0][0..^1] != emptyRlpHash[0..^1]:
        echo &"Legacy          {kvp[0].toHex}    => {kvp[1].toHex}"
    discard diff.rootHash
    echo "Tree:"
    diff.root.printTree(newFileStream(stdout), justTopTree=false)
  check diff.rootHash == trie.rootHash.data


suite "Merkle hashes":

  let emptyValue = hexToBytesArray[32]("0000000000000000000000000000000000000000000000000000000000000000").toBuffer32

  func makeKey(hex: string): Nibbles64 =
    Nibbles64(bytes: hexToBytesArray[32](hex))

  echo ""


  test "Leaf":
    when TraceLogs: echo "\nLeaf with empty value:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nLeaf with 1-byte ASCII value:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", "12"))

    when TraceLogs: echo "\nLeaf with 1-byte non-ASCII value:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", "ff"))

    when TraceLogs: echo "\nLeaf with 2-bytes value:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", "1234"))

    when TraceLogs: echo "\nLeaf with 32-bytes value:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", "0123456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221100"))

    when TraceLogs: echo "\nLeaves with path length 63:"
    compareWithLegacy(("1000000000000000000000000000000000000000000000000000000000000000", "11"),
                      ("2000000000000000000000000000000000000000000000000000000000000000", "22"))

    when TraceLogs: echo "\nLeaves with path length 62:"
    compareWithLegacy(("0100000000000000000000000000000000000000000000000000000000000000", "11"),
                      ("0200000000000000000000000000000000000000000000000000000000000000", "22"))

    when TraceLogs: echo "\nLeaves with path length 2:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000000", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000100", "12"))

    when TraceLogs: echo "\nLeaves with path length 1:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000001", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000023", "12"))

    when TraceLogs: echo "\nLeaves with empty path:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000001", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000002", "12"))

  test "Extension":
    when TraceLogs: echo "\nExtension with length 63, ascii prefix:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000001", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000002", ""))

    when TraceLogs: echo "\nExtension with length 63, non-ascii prefix:"
    compareWithLegacy(("f000000000000000000000000000000000000000000000000000000000000001", ""),
                      ("f000000000000000000000000000000000000000000000000000000000000002", ""))

    when TraceLogs: echo "\nExtension with length 62, ascii prefix:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000010", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000020", ""))

    when TraceLogs: echo "\nExtension with length 62, non-ascii prefix:"
    compareWithLegacy(("f000000000000000000000000000000000000000000000000000000000000010", ""),
                      ("f000000000000000000000000000000000000000000000000000000000000020", ""))

    when TraceLogs: echo "\nExtension with length 61, ascii prefix:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000000100", ""),
                      ("0000000000000000000000000000000000000000000000000000000000000200", ""))

    when TraceLogs: echo "\nExtension with length 61, non-ascii prefix:"
    compareWithLegacy(("f000000000000000000000000000000000000000000000000000000000000100", ""),
                      ("f000000000000000000000000000000000000000000000000000000000000200", ""))

    when TraceLogs: echo "\nExtension with length 60, ascii prefix:"
    compareWithLegacy(("0000000000000000000000000000000000000000000000000000000000001000", ""),
                      ("0000000000000000000000000000000000000000000000000000000000002000", ""))

    when TraceLogs: echo "\nExtension with length 60, non-ascii prefix:"
    compareWithLegacy(("f000000000000000000000000000000000000000000000000000000000001000", ""),
                      ("f000000000000000000000000000000000000000000000000000000000002000", ""))

    when TraceLogs: echo "\nExtension with length 4, ascii prefix:"
    compareWithLegacy(("0000100000000000000000000000000000000000000000000000000000000000", ""),
                      ("0000200000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 4, non-ascii prefix:"
    compareWithLegacy(("f000100000000000000000000000000000000000000000000000000000000000", ""),
                      ("f000200000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 3, ascii prefix:"
    compareWithLegacy(("0001000000000000000000000000000000000000000000000000000000000000", ""),
                      ("0002000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 3, non-ascii prefix:"
    compareWithLegacy(("f001000000000000000000000000000000000000000000000000000000000000", ""),
                      ("f002000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 2, ascii prefix:"
    compareWithLegacy(("0010000000000000000000000000000000000000000000000000000000000000", ""),
                      ("0020000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 2, non-ascii prefix:"
    compareWithLegacy(("f010000000000000000000000000000000000000000000000000000000000000", ""),
                      ("f020000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 1, ascii prefix:"
    compareWithLegacy(("0100000000000000000000000000000000000000000000000000000000000000", ""),
                      ("0200000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension with length 1, non-ascii prefix:"
    compareWithLegacy(("f100000000000000000000000000000000000000000000000000000000000000", ""),
                      ("f200000000000000000000000000000000000000000000000000000000000000", ""))

    when TraceLogs: echo "\nExtension 810:"
    compareWithLegacy(("810a000000000000000000000000000000000000000000000000000000000000", ""),
                      ("810b000000000000000000000000000000000000000000000000000000000000", ""))
