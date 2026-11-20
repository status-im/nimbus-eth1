# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/sequtils,
  pkg/[eth/common, eth/trie/nibbles, stew/byteutils, unittest2],
  ../../execution_chain/db/aristo,
  ../../execution_chain/sync/snap/worker/[mpt_build, worker_desc]

## Check for some pathological cases
func x(s: string): seq[byte] =
  try:
    return s.hexToSeqByte
  except:
    discard

func k(s: string): HashKey = HashKey.fromBytes(s.x).value

let sample =
  # From InvalidBlocks/bc4895-withdrawals/twoIdenticalIndex.json
  [("80".x,
    "da808094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "27f166f1d7c789251299535cb176ba34116e44894476a7886fe5d73d9be5c973".k),
   ("01".x,
    "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "81eac5f476f48feb289af40ee764015f6b49036760438ea45df90d5342b6ae61".k),
   ("02".x,
    "da018094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "463769ae507fcc6d6231c8888425191c5622f330fdd4b78a7b24c4521137b573".k),
   ("03".x,
    "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36".k)]

suite "Snap Data Edge Cases":

  for n in 0 ..< sample.len:

    test "Trie with " & $(n + 1) & " leaf(s)":
      let
        root = sample[n][2].to(Hash32)
        db = NodeTrieRef.init(root, 1)
      for i in 0 .. n:
        check db.merge(sample[i][0], sample[i][1]).isOk

      check db.finalise() == 1
      check db.isComplete()

      if db.isComplete():
        let dbx = NodeTrieRef.init(root, db.knPairs().mapIt(it[1]), 1)
        check not dbx.isNil

        if not dbx.isNil:
          check dbx.finalise() == 0
          check dbx.isComplete()

suite "Snap Proof Node Edge Cases":
  let root = StateRoot(sample[0][2].to(Hash32))

  func branchNode(child: seq[byte], value = seq[byte].default): seq[byte] =
    ## A 17-item branch node with `child` at index 0 and the value slot `value`
    var w = initRlpList 17
    w.appendRawBytes child
    for _ in 1 .. 15:
      w.append ""
    w.append value
    w.finish()

  test "Proof node of one byte is rejected":
    check root.validate(low(ItemKey), seq[SnapAccount].default,
      @[ProofNode(@[0x80'u8])]).isErr

  test "Proof node shorter than 32 bytes with a wrong list prefix is rejected":
    # `c3` would announce a 3 byte list payload, there are only two bytes
    check root.validate(low(ItemKey), seq[SnapAccount].default,
      @[ProofNode(@[0xc3'u8, 0x80, 0x80])]).isErr

  test "Branch node with a 5 byte blob child is rejected":
    check root.validate(low(ItemKey), seq[SnapAccount].default,
      @[ProofNode(branchNode(@[0x85'u8, 1, 2, 3, 4, 5]))]).isErr

  test "Branch node with an embedded child list of 33 bytes is rejected":
    var child = initRlpList 1
    child.append newSeq[byte](31)                   # list payload 32 bytes
    let enc = child.finish()
    check enc.len == 33
    check root.validate(low(ItemKey), seq[SnapAccount].default,
      @[ProofNode(branchNode(enc))]).isErr

  test "Branch node with a non-empty value slot is rejected":
    let
      node = branchNode(rlp.encode(zeroHash32), @(zeroHash32.data))
      nodeRoot = StateRoot(node.keccak256)
    check NodeTrieRef.init(
      nodeRoot, low(ItemKey), @[ProofNode(node)], high(ItemKey).to(Hash32)
        ).isNil
