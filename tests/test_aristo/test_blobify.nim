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

import unittest2, std/sequtils, ../../nimbus/db/aristo/aristo_blobify

suite "Aristo blobify":
  test "VertexRef roundtrip":
    let
      leafAccount = VertexRef(
        vType: Leaf,
        pfx: NibblesBuf.nibble(1),
        lData: LeafPayload(
          pType: AccountData, account: AristoAccount(nonce: 100, balance: 123.u256)
        ),
      )
      leafStoData = VertexRef(
        vType: Leaf,
        pfx: NibblesBuf.nibble(3),
        lData: LeafPayload(pType: StoData, stoData: 42.u256),
      )
      branch = VertexRef(vType: Branch, startVid: VertexID(0x334452), used: 0x43'u16)

      extension = VertexRef(
        vType: Branch,
        pfx: NibblesBuf.nibble(2),
        startVid: VertexID(0x55),
        used: 0x12'u16,
      )

      key = HashKey.fromBytes(repeat(0x34'u8, 32))[]

    check:
      deblobify(blobify(leafAccount, key), VertexRef)[] == leafAccount
      deblobify(blobify(leafStoData, key), VertexRef)[] == leafStoData
      deblobify(blobify(branch, key), VertexRef)[] == branch
      deblobify(blobify(extension, key), VertexRef)[] == extension

      deblobify(blobify(branch, key), HashKey)[] == key
      deblobify(blobify(extension, key), HashKey)[] == key
