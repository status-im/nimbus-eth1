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
  eth/common/block_access_lists_rlp,
  ../execution_chain/block_access_list/[block_access_list_builder, block_access_list_validation]

template toBytes32(slot: UInt256): Bytes32 =
  Bytes32(slot.toBytesBE())

suite "Block access list validation":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()

  setup:
    let builder = BlockAccessListBuilderRef.init()

  test "Empty BAL should equal the EMPTY_BLOCK_ACCESS_LIST_HASH":
    let emptyBal = builder.buildBlockAccessList()[]
    check:
      emptyBal.validate(EMPTY_BLOCK_ACCESS_LIST_HASH).isOk()
      emptyBal.validate(default(Hash32)).isErr()

  test "Valid BAL should validate successfully":
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

    let bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()

  test "Storage changes and reads don't overlap for the same slot":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()[]
    bal[0].storageReads = @[slot1.toBytes32()]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Account changes out of order should fail validation":
    builder.addTouchedAccount(address1)
    builder.addTouchedAccount(address2)
    builder.addTouchedAccount(address3)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0] = bal[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Storage changes out of order should fail validation":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0] = bal[0].storageChanges[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Slot changes out of order should fail validation":
    builder.addStorageWrite(address1, slot1, 0, 0.u256)
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot1, 2, 2.u256)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes[0] = bal[0].storageChanges[0].changes[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Storage reads out of order should fail validation":
    builder.addStorageRead(address1, slot1)
    builder.addStorageRead(address1, slot2)
    builder.addStorageRead(address1, slot3)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].storageReads[0] = bal[0].storageReads[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Balance changes out of order should fail validation":
    builder.addBalanceChange(address1, 1, 1.u256)
    builder.addBalanceChange(address1, 2, 2.u256)
    builder.addBalanceChange(address1, 3, 3.u256)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].balanceChanges[0] = bal[0].balanceChanges[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Nonce changes out of order should fail validation":
    builder.addNonceChange(address1, 1, 1)
    builder.addNonceChange(address1, 2, 2)
    builder.addNonceChange(address1, 3, 3)

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].nonceChanges[0] = bal[0].nonceChanges[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()

  test "Code changes out of order should fail validation":
    builder.addCodeChange(address1, 0, @[0x1.byte])
    builder.addCodeChange(address1, 1, @[0x2.byte])
    builder.addCodeChange(address1, 2, @[0x3.byte])

    var bal = builder.buildBlockAccessList()[]
    check bal.validate(bal.computeBlockAccessListHash()).isOk()
    bal[0].codeChanges[0] = bal[0].codeChanges[2]
    check bal.validate(bal.computeBlockAccessListHash()).isErr()
