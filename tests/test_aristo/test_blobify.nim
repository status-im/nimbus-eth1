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

import unittest2, ../../nimbus/db/aristo/aristo_blobify

suite "Aristo blobify":
  test "VertexRef roundtrip":
    let
      leafRawData = VertexRef(vType: Leaf, lData: LeafPayload(pType: RawData))
      leafAccount = VertexRef(vType: Leaf, lData: LeafPayload(pType: AccountData))
      leafStoData =
        VertexRef(vType: Leaf, lData: LeafPayload(pType: StoData, stoData: 42.u256))
      branch = VertexRef(
        vType: Branch,
        bVid: [
          VertexID(0),
          VertexID(1),
          VertexID(0),
          VertexID(0),
          VertexID(4),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
        ],
      )

      extension = VertexRef(
        vType: Branch,
        ePfx: NibblesBuf.nibble(2),
        bVid: [
          VertexID(0),
          VertexID(0),
          VertexID(2),
          VertexID(0),
          VertexID(0),
          VertexID(5),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
          VertexID(0),
        ],
      )

    check:
      deblobify(blobify(leafRawData), VertexRef)[] == leafRawData
      deblobify(blobify(leafAccount), VertexRef)[] == leafAccount
      deblobify(blobify(leafStoData), VertexRef)[] == leafStoData
      deblobify(blobify(branch), VertexRef)[] == branch
      deblobify(blobify(extension), VertexRef)[] == extension
