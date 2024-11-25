# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
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
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo/aristo_desc/desc_nibbles

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
      hexToSeqByte("0100000000000000000000000000000000000000000000000000000000000000")
    )

    check $n == "0100000000000000000000000000000000000000000000000000000000000000"
    check $n.slice(1) == "100000000000000000000000000000000000000000000000000000000000000"

    let
      he = n.toHexPrefix(true)
      ho = n.slice(1).toHexPrefix(true)
    check:
      NibblesBuf.fromHexPrefix(he.data()) == (true, n)
      NibblesBuf.fromHexPrefix(ho.data()) == (true, n.slice(1))
