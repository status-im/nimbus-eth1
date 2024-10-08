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
  eth/common,
  results,
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_get, aristo_debug, aristo_desc, aristo_serialise,
    aristo_utils],
  ../replay/xcheck,
  ./test_helpers

func x(s: string): seq[byte] = s.hexToSeqByte
func k(s: string): HashKey = HashKey.fromBytes(s.x).value

let samples = [

  # From InvalidBlocks/bc4895-withdrawals/twoIdenticalIndex.json
  @[("80".x,
    "da808094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "27f166f1d7c789251299535cb176ba34116e44894476a7886fe5d73d9be5c973".k,
    VOID_HASH_KEY),
   ("01".x,
    "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "81eac5f476f48feb289af40ee764015f6b49036760438ea45df90d5342b6ae61".k,
    VOID_HASH_KEY),
   ("02".x,
    "da018094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "463769ae507fcc6d6231c8888425191c5622f330fdd4b78a7b24c4521137b573".k,
    VOID_HASH_KEY),
   ("03".x,
    "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
    "a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36".k,
    VOID_HASH_KEY)],

  # Somew on-the-fly provided stuff
  @[("0000".x, "0000".x,
     "69a4785bd4f5a1590e329138d4248b6f887fa37e41bfc510a55f21b44f98be61".k,
     "c783200000820000".k),
    ("0000".x, "0001".x,
     "910fa1155b667666abe7b4b1cb4864c1dc91c57c9528e1c5f5f9f95e003afece".k,
     "c783200000820001".k),
    ("0001".x, "0001".x,
     "d082d2bfe8586142d6f40df0245e56365043819e51e2c9799c660558eeea0db5".k,
     "dd821000d9c420820001c420820001808080808080808080808080808080".k),
    ("0002".x, "0000".x,
     "d56ea5154fbad18e0ff1eaeafa2310d0879b59adf189c12ff1b2701e54db07b2".k,
     VOID_HASH_KEY),
    ("0100".x, "0100".x,
     "d1c0699fe7928a536e0183c6400ae34eb1174ce6b21f9d117b061385034743ad".k,
     VOID_HASH_KEY),
    ("0101".x, "0101".x,
     "74ddb98cb56e2dd7e8fa090b9ce740c3de589b72403b20136af75fb6168b1d19".k,
     VOID_HASH_KEY),
    ("0200".x, "0200".x,
     "2e777f06ab2de1a460a8412b8691f10fdcb162077ab5cbb1865636668bcb6471".k,
     VOID_HASH_KEY)]]

let
  noisy = true
  gossip = false # or noisy

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

suite "Aristo short keys":
  test "Add and delete entries":

    # Check for some pathological cases
    for n,sample in samples:
      let
        sig = merkleSignBegin()
        root = (sig.root,sig.root)
        db = sig.db

      for inx,(k,v,r,s) in sample:

        sig.merkleSignAdd(k,v)
        gossip.say "*** testShortkeys (1)", "n=", n, " inx=", inx,
          "\n    k=", k.toHex, " v=", v.toHex,
          "\n    r=", r.pp(sig),
          "\n    ", sig.pp(),
          "\n"

        # Check state against expected value
        let w = sig.merkleSignCommit().value
        gossip.say "*** testShortkeys (2)", "n=", n, " inx=", inx,
          "\n    k=", k.toHex, " v=", v.toHex,
          "\n    r=", r.pp(sig),
          "\n    R=", w.pp(sig),
          "\n    ", sig.pp(),
          "\n    ----------------",
          "\n"
        xCheck r == w.to(HashKey):
          noisy.say "*** testShortkeys (2.1)", "n=", n, " inx=", inx,
            "\n    k=", k.toHex, " v=", v.toHex,
            "\n    r=", r.pp(sig),
            "\n    R=", w.pp(sig),
            "\n    ", sig.pp(),
            "\n"

        # Check raw node if given, check nor ref against expected value
        if s.isValid:
          let z = db.getVtx(root).toNode(root[0],db).value.digestTo(HashKey)
          xCheck s == z:
            noisy.say "*** testShortkeys (2.2)", "n=", n, " inx=", inx,
              "\n    k=", k.toHex, " v=", v.toHex,
              "\n    r=", r.pp(sig),
              "\n    R=", w.pp(sig),
              "\n    ", sig.pp(),
              "\n"

        let rc = sig.db.check
        xCheckRc rc.error == (0,0):
          noisy.say "*** testShortkeys (2.3)", "n=", n, " inx=", inx,
            "\n    k=", k.toHex, " v=", v.toHex, " rc=", rc.error,
            "\n    r=", r.pp(sig),
            "\n    R=", w.pp(sig),
            "\n    ", sig.pp(),
            "\n"

      # Reverse run deleting entries
      var deletedKeys: HashSet[seq[byte]]
      for iny,(k,v,r,s) in sample.reversed:
        let inx = sample.len - 1 - iny

        # Check whether key was already deleted
        if k in deletedKeys:
          continue
        deletedKeys.incl k

        # Check state against expected value
        let w = sig.merkleSignCommit().value
        gossip.say "*** testShortkeys, pre-del (5)", "n=", n, " inx=", inx,
          "\n    k", k.toHex, " v=", v.toHex,
          "\n    r=", r.pp(sig),
          "\n    R=", w.pp(sig),
          "\n    ", sig.pp(),
          "\n"
        xCheck r == w.to(HashKey)

        # Check raw node if given, check nor ref against expected value
        if s.isValid:
          let z = db.getVtx(root).toNode(root[0],db).value.digestTo(HashKey)
          xCheck s == z

        sig.merkleSignDelete(k)
        gossip.say "*** testShortkeys, post-del (6)", "n=", n, " inx=", inx,
          "\n    k", k.toHex, " v=", v.toHex,
          "\n    ", sig.pp(),
          "\n"

        let rc = sig.db.check
        xCheckRc rc.error == (0,0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
