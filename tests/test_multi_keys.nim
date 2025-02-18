# Nimbus
# Copyright (c) 2020-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  random, unittest2, stew/byteutils,
  eth/trie/nibbles,
  ../execution_chain/stateless/multi_keys

proc initMultiKeys(keys: openArray[string], storageMode: bool = false): MultiKeysRef =
  result.new
  if storageMode:
    for i, x in keys:
      result.keys.add KeyData(
        storageMode: true,
        hash: hexToByteArray[32](x)
      )
  else:
    for x in keys:
      result.keys.add KeyData(
        storageMode: false,
        hash: hexToByteArray[32](x)
      )

proc multiKeysMain*() =
  suite "random keys block witness roundtrip test":
    randomize()

    test "case 1: all keys is a match":
      let keys = [
        "0abc7124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0abccc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abca163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6bb"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 0
        mg.group.last == 2

    test "case 2: all keys is not a match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0456a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6bb"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == false

    test "case 3: not match and match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 2
        mg.group.last == 3

    test "case 4: match and not match":
      let keys = [
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 0
        mg.group.last == 1

    test "case 5: not match, match and not match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 2
        mg.group.last == 3

multiKeysMain()
