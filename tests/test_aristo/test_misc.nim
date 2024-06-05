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
      "a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36".k)]]

  let gossip = false # or noisy

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
      let rc = sig.db.check
      xCheckRc rc.error == (0,0)
      xCheck r == w

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
