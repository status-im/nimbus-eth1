# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[sequtils, strutils],
  stew/byteutils,
  unittest2,
  ../../execution_chain/db/aristo/aristo_desc/desc_nibbles

suite "Nibbles":
  test "trivial cases":
    block:
      let n = NibblesBuf.fromBytes([])
      check:
        n.len == 0
    block:
      let n = NibblesBuf.fromBytes([byte 0x10])
      check:
        n.len == 2
        n[0] == 1
        n[1] == 0
        $n.slice(1) == "0"
        $n.slice(2) == ""
        $n.slice(0, 0) == ""
        $n.slice(1, 1) == ""
        $n.slice(0, 1) == "1"

        $(n & n) == "1010"

        NibblesBuf.nibble(0) != NibblesBuf.nibble(1)
    block:
      let n = NibblesBuf.fromBytes(repeat(byte 0x12, 32))
      check:
        n.len == 64
        n[0] == 1
        n[63] == 2

    block:
      let n = NibblesBuf.fromBytes(repeat(byte 0x12, 33))
      check:
        n.len == 64
        n[0] == 1
        n[63] == 2

  test "to/from hex encoding":
    block:
      let n = NibblesBuf.fromBytes([byte 0x12, 0x34, 0x56])

      let
        he = n.toHexPrefix(true)
        ho = n.slice(1).toHexPrefix(true)
      check:
        NibblesBuf.fromHexPrefix(he.data()) == (true, n)
        NibblesBuf.fromHexPrefix(ho.data()) == (true, n.slice(1))
    block:
      let n = NibblesBuf.fromBytes(repeat(byte 0x12, 32))

      let
        he = n.toHexPrefix(true)
        ho = n.slice(1).toHexPrefix(true)

      check:
        NibblesBuf.fromHexPrefix(he.data()) == (true, n)
        NibblesBuf.fromHexPrefix(ho.data()) == (true, n.slice(1))

        NibblesBuf.fromHexPrefix(@(he.data()) & @[byte 1]) == (true, n)
        NibblesBuf.fromHexPrefix(@(ho.data()) & @[byte 1]) == (true, n.slice(1))

  test "long":
    let n = NibblesBuf.fromBytes(
      hexToSeqByte("0100000000000000000000000000000000000000000000000000000000000012")
    )
    check:
      n.getBytes() ==
        hexToSeqByte("0100000000000000000000000000000000000000000000000000000000000012")

      $n == "0100000000000000000000000000000000000000000000000000000000000012"
      $(n & default(NibblesBuf)) ==
        "0100000000000000000000000000000000000000000000000000000000000012"

      $n.slice(1) == "100000000000000000000000000000000000000000000000000000000000012"
      $n.slice(1, 2) == "1"
      $(n.slice(1) & NibblesBuf.nibble(1)) ==
        "1000000000000000000000000000000000000000000000000000000000000121"

      $n.replaceSuffix(n.slice(1, 2)) ==
        "0100000000000000000000000000000000000000000000000000000000000011"

    for i in 0 ..< 64:
      check:
        $n.slice(0, i) ==
          "0100000000000000000000000000000000000000000000000000000000000012"[0 ..< i]

    for i in 0 ..< 64:
      check:
        $n.slice(i) ==
          "0100000000000000000000000000000000000000000000000000000000000012"[i ..< 64]

    let
      he = n.toHexPrefix(true)
      ho = n.slice(1).toHexPrefix(true)
    check:
      NibblesBuf.fromHexPrefix(he.data()) == (true, n)
      NibblesBuf.fromHexPrefix(ho.data()) == (true, n.slice(1))

  test "sharedPrefixLen":
    let n0 = NibblesBuf.fromBytes(hexToSeqByte("01000000"))
    let n2 = NibblesBuf.fromBytes(hexToSeqByte("10"))
    let n = NibblesBuf.fromBytes(
      hexToSeqByte("0100000000000000000000000000000000000000000000000000000000000012")
    )
    let nn = NibblesBuf.fromBytes(
      hexToSeqByte("0100000000000000000000000000000000000000000000000000000000000013")
    )

    check:
      n0.sharedPrefixLen(n0) == 8
      n0.sharedPrefixLen(n2) == 0
      n0.slice(1).sharedPrefixLen(n0.slice(1)) == 7
      n0.slice(7).sharedPrefixLen(n0.slice(7)) == 1
      n0.slice(1).sharedPrefixLen(n2) == 2

    for i in 0 .. 64:
      check:
        n.slice(0, i).sharedPrefixLen(n) == i

    for i in 0 .. 63:
      check:
        n.slice(0, i).sharedPrefixLen(nn.slice(0, i)) == i
    check:
      n.sharedPrefixLen(nn) == 63

  test "join":
    block:
      let
        n0 = NibblesBuf.fromBytes(repeat(0x00'u8, 32))
        n1 = NibblesBuf.fromBytes(repeat(0x11'u8, 32))

      for i in 0 ..< 64:
        check:
          $(n0.slice(0, 64 - i) & n1.slice(0, i)) ==
            (strutils.repeat('0', 64 - i) & strutils.repeat('1', i))

          $(n0.slice(0, 1) & n1.slice(0, i)) ==
            (strutils.repeat('0', 1) & strutils.repeat('1', i))

      for i in 0 ..< 63:
        check:
          $(n0.slice(1, 64 - i) & n1.slice(0, i)) ==
            (strutils.repeat('0', 63 - i) & strutils.repeat('1', i))

  test "replaceSuffix":
    let
      n0 = NibblesBuf.fromBytes(repeat(0x00'u8, 32))
      n1 = NibblesBuf.fromBytes(repeat(0x11'u8, 32))

    check:
      n0.replaceSuffix(default(NibblesBuf)) == n0
      n0.replaceSuffix(n0) == n0
      n0.replaceSuffix(n1) == n1

    for i in 0 ..< 64:
      check:
        $n0.replaceSuffix(n1.slice(0, i)) ==
          (strutils.repeat('0', 64 - i) & strutils.repeat('1', i))
