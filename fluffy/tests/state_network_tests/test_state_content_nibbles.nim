# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import unittest2, stew/byteutils, ../../network/state/state_content

suite "State Content Nibbles":
  test "Encode/decode empty nibbles":
    const
      expected = "00"
      nibbles: seq[byte] = @[]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles

  test "Encode/decode zero nibble":
    const
      expected = "10"
      nibbles: seq[byte] = @[0]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles

  test "Encode/decode one nibble":
    const
      expected = "11"
      nibbles: seq[byte] = @[1]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles

  test "Encode/decode even nibbles":
    const
      expected = "008679e8ed"
      nibbles: seq[byte] = @[8, 6, 7, 9, 14, 8, 14, 13]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles

  test "Encode/decode odd nibbles":
    const
      expected = "138679e8ed"
      nibbles: seq[byte] = @[3, 8, 6, 7, 9, 14, 8, 14, 13]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles

  test "Encode/decode max length nibbles":
    const
      expected = "008679e8eda65bd257638cf8cf09b8238888947cc3c0bea2aa2cc3f1c4ac7a3002"
      nibbles: seq[byte] =
        @[
          8, 6, 7, 9, 0xe, 8, 0xe, 0xd, 0xa, 6, 5, 0xb, 0xd, 2, 5, 7, 6, 3, 8, 0xc, 0xf,
          8, 0xc, 0xf, 0, 9, 0xb, 8, 2, 3, 8, 8, 8, 8, 9, 4, 7, 0xc, 0xc, 3, 0xc, 0,
          0xb, 0xe, 0xa, 2, 0xa, 0xa, 2, 0xc, 0xc, 3, 0xf, 1, 0xc, 4, 0xa, 0xc, 7, 0xa,
          3, 0, 0, 2,
        ]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let encoded = SSZ.encode(packedNibbles)

    check:
      encoded.toHex() == expected
      unpackedNibbles == nibbles
