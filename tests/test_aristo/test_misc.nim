# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB trancoder test

import
  std/algorithm,
  eth/common,
  results,
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[aristo_check, aristo_debug, aristo_desc],
  ../replay/xcheck,
  ./test_helpers

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testShortKeys*(
    noisy = true;
      ): bool =
  ## Check for some pathological cases
  func x(s: string): Blob = s.hexToSeqByte
  func k(s: string): HashKey = HashKey.fromBytes(s.x).value

  let samples = [
    # From InvalidBlocks/bc4895-withdrawals/twoIdenticalIndex.json
    @[("80".x,
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
      "a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36".k)],
    @[("0000".x, "0000".x,
      "c783200000820000".k),
      ("0000".x, "0001".x,
      "c783200000820001".k),
      ("0001".x, "0001".x,
      "dd821000d9c420820001c420820001808080808080808080808080808080".k),
      ("0002".x, "0000".x,
      "d56ea5154fbad18e0ff1eaeafa2310d0879b59adf189c12ff1b2701e54db07b2".k),
      ("0100".x, "0100".x,
      "d1c0699fe7928a536e0183c6400ae34eb1174ce6b21f9d117b061385034743ad".k),
      ("0101".x, "0101".x,
      "74ddb98cb56e2dd7e8fa090b9ce740c3de589b72403b20136af75fb6168b1d19".k),
      ("0200".x, "0200".x,
      "2e777f06ab2de1a460a8412b8691f10fdcb162077ab5cbb1865636668bcb6471".k),
      ]]

  let gossip = true # or noisy

  for n,sample in samples:
    let sig = merkleSignBegin()
    var inx = -1
    for (k,v,r) in sample:
      inx.inc
      sig.merkleSignAdd(k,v)
      gossip.say "*** testShortkeys (1)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    ", sig.pp(),
        "\n"
      let w = sig.merkleSignCommit().value
      gossip.say "*** testShortkeys (2)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    R=", w.pp(sig),
        "\n    ", sig.pp(),
        "\n    ----------------",
        "\n"

    for (k,v,r) in sample.reversed():
      inx.inc
      let w = sig.merkleSignCommit().value
      gossip.say "*** preDel (1)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    ", sig.pp(),
        "\n"
      sig.merkleSignDelete(k)
      gossip.say "*** preDel (2)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    R=", w.pp(sig),
        "\n    ", sig.pp(),
        "\n    ----------------",
        "\n"

      #let rc = sig.db.check
      # xCheckRc rc.error == (0,0)
      xCheck r == w
      #debugEcho rc

  true
var v = testShortKeys()
echo v
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
