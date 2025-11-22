# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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
  ../execution_chain/block_access_list/block_access_list_builder

template toBytes32(slot: UInt256): Bytes32 =
  Bytes32(slot.toBytesBE())

suite "Block access list builder":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()

  setup:
    let builder = BlockAccessListBuilderRef.init()

  test "Add touched account":
    builder.addTouchedAccount(address3)
    builder.addTouchedAccount(address2)
    builder.addTouchedAccount(address1)
    builder.addTouchedAccount(address1) # duplicate

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[1].address == address2
      bal[2].address == address3

    for accChange in bal:
      check:
        accChange.storageChanges.len() == 0
        accChange.storageReads.len() == 0
        accChange.balanceChanges.len() == 0
        accChange.nonceChanges.len() == 0
        accChange.codeChanges.len() == 0

  test "Add storage write":
    builder.addStorageWrite(address1, slot3, 0, 3.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address2, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot3, 3, 4.u256)
    builder.addStorageWrite(address1, slot3, 3, 5.u256) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 2
      bal[0].address == address1
      bal[0].storageChanges.len() == 3
      bal[0].storageChanges[0] == (slot1.toBytes32(), @[(1.BlockAccessIndex, 1.u256.toBytes32())])
      bal[0].storageChanges[1] == (slot2.toBytes32(), @[(2.BlockAccessIndex, 2.u256.toBytes32())])
      bal[0].storageChanges[2] == (slot3.toBytes32(), @[(0.BlockAccessIndex, 3.u256.toBytes32()), (3.BlockAccessIndex, 5.u256.toBytes32())])
      bal[1].address == address2
      bal[1].storageChanges.len() == 1
      bal[1].storageChanges[0] == (slot1.toBytes32(), @[(1.BlockAccessIndex, 1.u256.toBytes32())])

  test "Add storage read":
    builder.addStorageRead(address2, slot3)
    builder.addStorageRead(address2, slot2)
    builder.addStorageRead(address3, slot3)
    builder.addStorageRead(address1, slot1)
    builder.addStorageRead(address1, slot1) # duplicate

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].storageReads == @[slot1.toBytes32()]
      bal[1].address == address2
      bal[1].storageReads == @[slot2.toBytes32(), slot3.toBytes32()]
      bal[2].address == address3
      bal[2].storageReads == @[slot3.toBytes32()]

  test "Add balance change":
    builder.addBalanceChange(address2, 1, 0.u256)
    builder.addBalanceChange(address2, 0, 1.u256)
    builder.addBalanceChange(address3, 3, 3.u256)
    builder.addBalanceChange(address1, 2, 2.u256)
    builder.addBalanceChange(address1, 2, 10.u256) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].balanceChanges == @[(2.BlockAccessIndex, 10.u256)]
      bal[1].address == address2
      bal[1].balanceChanges == @[(0.BlockAccessIndex, 1.u256), (1.BlockAccessIndex, 0.u256)]
      bal[2].address == address3
      bal[2].balanceChanges == @[(3.BlockAccessIndex, 3.u256)]

  test "Add nonce change":
    builder.addNonceChange(address1, 3, 3)
    builder.addNonceChange(address2, 2, 2)
    builder.addNonceChange(address2, 1, 1)
    builder.addNonceChange(address3, 1, 1)
    builder.addNonceChange(address3, 1, 10) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].nonceChanges == @[(3.BlockAccessIndex, 3.AccountNonce)]
      bal[1].address == address2
      bal[1].nonceChanges == @[(1.BlockAccessIndex, 1.AccountNonce), (2.BlockAccessIndex, 2.AccountNonce)]
      bal[2].address == address3
      bal[2].nonceChanges == @[(1.BlockAccessIndex, 10.AccountNonce)]

  test "Add code change":
    builder.addCodeChange(address2, 0, @[0x1.byte])
    builder.addCodeChange(address2, 1, @[0x2.byte])
    builder.addCodeChange(address1, 3, @[0x3.byte])
    builder.addCodeChange(address1, 3, @[0x4.byte]) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 2
      bal[0].address == address1
      bal[0].codeChanges == @[(3.BlockAccessIndex, @[0x4.byte])]
      bal[1].address == address2
      bal[1].codeChanges == @[(0.BlockAccessIndex, @[0x1.byte]), (1.BlockAccessIndex, @[0x2.byte])]

  test "All changes and reads":
    builder.addTouchedAccount(address3)
    builder.addTouchedAccount(address2)
    builder.addTouchedAccount(address1)
    builder.addTouchedAccount(address1) # duplicate

    builder.addStorageWrite(address1, slot3, 0, 3.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address2, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot3, 3, 4.u256)
    builder.addStorageWrite(address1, slot3, 3, 5.u256) # duplicate should overwrite

    builder.addStorageRead(address2, slot3)
    builder.addStorageRead(address2, slot2)
    builder.addStorageRead(address3, slot3)
    builder.addStorageRead(address1, slot1)
    builder.addStorageRead(address1, slot1) # duplicate

    builder.addBalanceChange(address2, 1, 0.u256)
    builder.addBalanceChange(address2, 0, 1.u256)
    builder.addBalanceChange(address3, 3, 3.u256)
    builder.addBalanceChange(address1, 2, 2.u256)
    builder.addBalanceChange(address1, 2, 10.u256) # duplicate should overwrite

    builder.addNonceChange(address1, 3, 3)
    builder.addNonceChange(address2, 2, 2)
    builder.addNonceChange(address2, 1, 1)
    builder.addNonceChange(address3, 1, 1)
    builder.addNonceChange(address3, 1, 10) # duplicate should overwrite

    builder.addCodeChange(address2, 0, @[0x1.byte])
    builder.addCodeChange(address2, 1, @[0x2.byte])
    builder.addCodeChange(address1, 3, @[0x3.byte])
    builder.addCodeChange(address1, 3, @[0x4.byte]) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check:
      bal.len() == 3

      bal[0].address == address1
      bal[0].storageChanges.len() == 3
      bal[0].storageChanges[0] == (slot1.toBytes32(), @[(1.BlockAccessIndex, 1.u256.toBytes32())])
      bal[0].storageChanges[1] == (slot2.toBytes32(), @[(2.BlockAccessIndex, 2.u256.toBytes32())])
      bal[0].storageChanges[2] == (slot3.toBytes32(), @[(0.BlockAccessIndex, 3.u256.toBytes32()), (3.BlockAccessIndex, 5.u256.toBytes32())])
      bal[0].storageReads.len() == 0 # read removed by storage change with the same slot
      bal[0].balanceChanges == @[(2.BlockAccessIndex, 10.u256)]
      bal[0].nonceChanges == @[(3.BlockAccessIndex, 3.AccountNonce)]
      bal[0].codeChanges == @[(3.BlockAccessIndex, @[0x4.byte])]

      bal[1].address == address2
      bal[1].storageChanges.len() == 1
      bal[1].storageChanges[0] == (slot1.toBytes32(), @[(1.BlockAccessIndex, 1.u256.toBytes32())])
      bal[1].storageReads == @[slot2.toBytes32(), slot3.toBytes32()]
      bal[1].balanceChanges == @[(0.BlockAccessIndex, 1.u256), (1.BlockAccessIndex, 0.u256)]
      bal[1].nonceChanges == @[(1.BlockAccessIndex, 1.AccountNonce), (2.BlockAccessIndex, 2.AccountNonce)]
      bal[1].codeChanges == @[(0.BlockAccessIndex, @[0x1.byte]), (1.BlockAccessIndex, @[0x2.byte])]

      bal[2].address == address3
      bal[2].storageReads == @[slot3.toBytes32()]
      bal[2].balanceChanges == @[(3.BlockAccessIndex, 3.u256)]
      bal[2].nonceChanges == @[(1.BlockAccessIndex, 10.AccountNonce)]
