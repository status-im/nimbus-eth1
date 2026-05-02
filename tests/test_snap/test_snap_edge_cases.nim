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
  pkg/[eth/common, eth/trie/nibbles, stew/byteutils],
  pkg/unittest2,
  ../../execution_chain/sync/snap/worker/[mpt, mpt/mpt_debug, worker_desc]

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
        check db.merge(sample[i][0], sample[i][1])

      check db.finalise() == 1
      check db.isComplete()

      if db.isComplete():
        let dbx = NodeTrieRef.init(root, db.kvPairs().mapIt(it[1]), 1)
        check not dbx.isNil

        if not dbx.isNil:
          check dbx.finalise() == 0
          check dbx.isComplete()

# End
