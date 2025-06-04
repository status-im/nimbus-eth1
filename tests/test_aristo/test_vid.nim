# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  unittest2,
  eth/trie/nibbles,
  ../../execution_chain/db/aristo/[aristo_constants, aristo_vid]

suite "Aristo VertexID":
  test "Static basics":
    var buf = NibblesBuf.fromBytes([])
    check:
      buf.staticVid(0) == STATE_ROOT_VID

    buf = buf & NibblesBuf.nibble(byte 2)

    check:
      buf.staticVid(0) == STATE_ROOT_VID
      buf.staticVid(1) == STATE_ROOT_VID + 1 + 2

    buf = buf & NibblesBuf.nibble(byte 4)

    check:
      buf.staticVid(0) == STATE_ROOT_VID
      buf.staticVid(1) == STATE_ROOT_VID + 1 + 2
      buf.staticVid(2) == STATE_ROOT_VID + 1 + 16 + 0x24

    var
      buf2 = NibblesBuf.nibble(0) & buf
    var
      buf3 = NibblesBuf.nibble(1) & buf

    check:
      buf2.staticVid(3) != buf3.staticVid(3)

  test "fetching":
    var buf = NibblesBuf.fromBytes([])
    let txFrame = AristoTxRef()

    check:
      txFrame.accVidFetch(buf) == STATE_ROOT_VID

    buf = buf & NibblesBuf.nibble(byte 2)

    check:
      txFrame.accVidFetch(buf) == STATE_ROOT_VID + 1 + 2

    while buf.len <= STATIC_VID_LEVELS:
      buf = buf & NibblesBuf.nibble(byte 2)

    check:
      txFrame.accVidFetch(buf) == VertexID(FIRST_DYNAMIC_VID)
      txFrame.accVidFetch(buf) == VertexID(FIRST_DYNAMIC_VID + 1)
