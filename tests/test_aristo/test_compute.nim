# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[algorithm, sets],
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_compute, aristo_delete, aristo_get, aristo_merge, aristo_desc,
    aristo_utils, aristo_serialise, aristo_init, aristo_tx/tx_stow,
  ]

func x(s: string): seq[byte] =
  s.hexToSeqByte
func k(s: string): HashKey =
  HashKey.fromBytes(s.x).value

let samples = [
  # From InvalidBlocks/bc4895-withdrawals/twoIdenticalIndex.json
  @[
    (
      "80".x,
      "da808094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      hash32"27f166f1d7c789251299535cb176ba34116e44894476a7886fe5d73d9be5c973",
      VOID_HASH_KEY,
    ),
    (
      "01".x,
      "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      hash32"81eac5f476f48feb289af40ee764015f6b49036760438ea45df90d5342b6ae61",
      VOID_HASH_KEY,
    ),
    (
      "02".x,
      "da018094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      hash32"463769ae507fcc6d6231c8888425191c5622f330fdd4b78a7b24c4521137b573",
      VOID_HASH_KEY,
    ),
    (
      "03".x,
      "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      hash32"a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36",
      VOID_HASH_KEY,
    ),
  ],

  # Somew on-the-fly provided stuff
  @[
    (
      "0000".x,
      "0000".x,
      hash32"69a4785bd4f5a1590e329138d4248b6f887fa37e41bfc510a55f21b44f98be61",
      "c783200000820000".k,
    ),
    (
      "0000".x,
      "0001".x,
      hash32"910fa1155b667666abe7b4b1cb4864c1dc91c57c9528e1c5f5f9f95e003afece",
      "c783200000820001".k,
    ),
    (
      "0001".x,
      "0001".x,
      hash32"d082d2bfe8586142d6f40df0245e56365043819e51e2c9799c660558eeea0db5",
      "dd821000d9c420820001c420820001808080808080808080808080808080".k,
    ),
    (
      "0002".x,
      "0000".x,
      hash32"d56ea5154fbad18e0ff1eaeafa2310d0879b59adf189c12ff1b2701e54db07b2",
      VOID_HASH_KEY,
    ),
    (
      "0100".x,
      "0100".x,
      hash32"d1c0699fe7928a536e0183c6400ae34eb1174ce6b21f9d117b061385034743ad",
      VOID_HASH_KEY,
    ),
    (
      "0101".x,
      "0101".x,
      hash32"74ddb98cb56e2dd7e8fa090b9ce740c3de589b72403b20136af75fb6168b1d19",
      VOID_HASH_KEY,
    ),
    (
      "0200".x,
      "0200".x,
      hash32"2e777f06ab2de1a460a8412b8691f10fdcb162077ab5cbb1865636668bcb6471",
      VOID_HASH_KEY,
    ),
  ],
]

suite "Aristo compute":
  for n, sample in samples:
    test "Add and delete entries " & $n:
      let
        db = AristoDbRef.init VoidBackendRef
        root = VertexID(2)

      for inx, (k, v, r, s) in sample:
        checkpoint("k = " & k.toHex & ", v = " & v.toHex())

        check:
          db.mergeGenericData(root, k, v) == Result[bool, AristoError].ok(true)

        # Check state against expected value
        let w = db.computeKey((root, root)).expect("no errors")
        check r == w.to(Hash32)

        # Check raw node if given, check nor ref against expected value
        if s.isValid:
          let z = db.getVtx((root, root)).toNode(root, db).value.digestTo(HashKey)
          check s == z

        let rc = db.check
        check rc == typeof(rc).ok()

      # Reverse run deleting entries
      var deletedKeys: HashSet[seq[byte]]
      for iny, (k, v, r, s) in sample.reversed:
        # Check whether key was already deleted
        if k in deletedKeys:
          continue
        deletedKeys.incl k

        # Check state against expected value
        let w = db.computeKey((root, root)).value.to(Hash32)

        check r == w

        # Check raw node if given, check nor ref against expected value
        if s.isValid:
          let z = db.getVtx((root, root)).toNode(root, db).value.digestTo(HashKey)
          check s == z

        check:
          db.deleteGenericData(root, k).isOk

        let rc = db.check
        check rc == typeof(rc).ok()

  test "Pre-computed key":
    # TODO use mainnet genesis in this test?
    let
      db = AristoDbRef.init MemBackendRef
      root = VertexID(2)

    for inx, (k, v, r, s) in samples[^1]:
      check:
        db.mergeGenericData(root, keccak256(k).data, v) == Result[bool, AristoError].ok(true)

    check db.txStow(1, true).isOk()
    check db.computeKeys(root).isOk()
