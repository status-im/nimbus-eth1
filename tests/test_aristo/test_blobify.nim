# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import unittest2, std/sequtils, ../../execution_chain/db/aristo/aristo_blobify

suite "Aristo blobify":
  test "VertexRef roundtrip":
    let
      leafAccount = AccLeafRef.init(
        NibblesBuf.nibble(1),
        AristoAccount(nonce: 100, balance: 123.u256),
        (isValid: true, vid: VertexID(5)),
      )
      leafStoData = StoLeafRef.init(NibblesBuf.nibble(3), 42.u256)
      branch = BranchRef.init(VertexID(0x334452), 0x43'u16)
      extension = ExtBranchRef.init(NibblesBuf.nibble(2), VertexID(0x55), 0x12'u16)
      leafPtr = LeafPtrRef.init(VertexID(0x8000_1234_5678_9abc'u64))
      marker = LeafPtrRef.init(VertexID(0))
      derived1 = VertexID(0x8000_0000_0000_0001'u64)
      derived2 = VertexID(0x8000_0000_0000_0002'u64)

      key = HashKey.fromBytes(repeat(0x34'u8, 32))[]

    branch.setLeaf(5, derived1)
    branch.setLeaf(2, derived2)
    extension.setLeaf(15, derived1)

    check:
      branch.used == 0x67'u16
      branch.leafMask == 0x24'u16
      branch.bVid(2) == derived2
      branch.bVid(5) == derived1
      branch.bVid(0) == VertexID(0x334452)
      branch.bVid(3) == VertexID(0)
      branch.nChildren == 5

      deblobify(blobify(leafAccount, key), VertexRef)[] == leafAccount
      deblobify(blobify(leafStoData, key), VertexRef)[] == leafStoData
      deblobify(blobify(branch, key), VertexRef)[] == branch
      deblobify(blobify(branch, VOID_HASH_KEY), VertexRef)[] == branch
      deblobify(blobify(extension, key), VertexRef)[] == extension
      deblobify(blobify(leafPtr, key), VertexRef)[] == leafPtr
      deblobify(blobify(leafPtr, VOID_HASH_KEY), VertexRef)[] == leafPtr
      deblobify(blobify(marker, VOID_HASH_KEY), VertexRef)[] == marker

      deblobify(blobify(branch, key), HashKey)[] == key
      deblobify(blobify(extension, key), HashKey)[] == key
      deblobify(blobify(leafPtr, key), HashKey)[] == key
      deblobify(blobify(branch, VOID_HASH_KEY), HashKey).isNone()
      deblobify(blobify(leafPtr, VOID_HASH_KEY), HashKey).isNone()
      deblobify(blobify(leafAccount, key), HashKey).isNone()

      deblobifyType(blobify(leafAccount, key), VertexRef)[] == AccLeaf
      deblobifyType(blobify(leafStoData, key), VertexRef)[] == StoLeaf
      deblobifyType(blobify(branch, key), VertexRef)[] == Branch
      deblobifyType(blobify(extension, key), VertexRef)[] == ExtBranch
      deblobifyType(blobify(leafPtr, key), VertexRef)[] == LeafPtr

    branch.clearSlot(5)
    check:
      branch.used == 0x47'u16
      branch.leafMask == 0x04'u16
      branch.setBranch(2) == VertexID(0x334454)
      branch.leafMask == 0'u16
      branch.leafMask == 0
      branch.bVid(2) == VertexID(0x334454)
