# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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

const
  ENABLE_BENCHMARKS = false

  address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
  address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
  address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
  slot1 = 1.u256()
  slot2 = 2.u256()
  slot3 = 3.u256()

suite "Block access list validation":
  setup:
    let builder = BlockAccessListBuilderRef.init()

  test "Empty BAL should equal the EMPTY_BLOCK_ACCESS_LIST_HASH":
    let emptyBal = builder.buildBlockAccessList()
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

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()

  test "Storage changes and reads don't overlap for the same slot":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    bal[0].storageReads = @[slot1]

    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Account changes out of order should fail validation":
    builder.addTouchedAccount(address1)
    builder.addTouchedAccount(address2)
    builder.addTouchedAccount(address3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0] = bal[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Account changes with duplicates should fail validation":
    builder.addTouchedAccount(address1)
    builder.addTouchedAccount(address2)
    builder.addTouchedAccount(address3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[].insert(bal[0]) # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage changes out of order should fail validation":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0] = bal[0].storageChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage changes with duplicates should fail validation":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges.insert bal[0].storageChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot with no changes should fail validation":
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot2, 2, 2.u256)
    builder.addStorageWrite(address1, slot3, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes.setLen(0) # remove all changes for the slot
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot changes out of order should fail validation":
    builder.addStorageWrite(address1, slot1, 0, 0.u256)
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot1, 2, 2.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes[0] = bal[0].storageChanges[0].changes[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot changes with duplicates should fail validation":
    builder.addStorageWrite(address1, slot1, 0, 0.u256)
    builder.addStorageWrite(address1, slot1, 1, 1.u256)
    builder.addStorageWrite(address1, slot1, 2, 2.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes.insert bal[0].storageChanges[0].changes[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage reads out of order should fail validation":
    builder.addStorageRead(address1, slot1)
    builder.addStorageRead(address1, slot2)
    builder.addStorageRead(address1, slot3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageReads[0] = bal[0].storageReads[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage reads with duplicates should fail validation":
    builder.addStorageRead(address1, slot1)
    builder.addStorageRead(address1, slot2)
    builder.addStorageRead(address1, slot3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageReads.insert bal[0].storageReads[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Balance changes out of order should fail validation":
    builder.addBalanceChange(address1, 1, 1.u256)
    builder.addBalanceChange(address1, 2, 2.u256)
    builder.addBalanceChange(address1, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].balanceChanges[0] = bal[0].balanceChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Balance changes with duplicates should fail validation":
    builder.addBalanceChange(address1, 1, 1.u256)
    builder.addBalanceChange(address1, 2, 2.u256)
    builder.addBalanceChange(address1, 3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].balanceChanges.insert bal[0].balanceChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Nonce changes out of order should fail validation":
    builder.addNonceChange(address1, 1, 1)
    builder.addNonceChange(address1, 2, 2)
    builder.addNonceChange(address1, 3, 3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].nonceChanges[0] = bal[0].nonceChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Nonce changes with duplicates should fail validation":
    builder.addNonceChange(address1, 1, 1)
    builder.addNonceChange(address1, 2, 2)
    builder.addNonceChange(address1, 3, 3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].nonceChanges.insert bal[0].nonceChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code changes out of order should fail validation":
    builder.addCodeChange(address1, 0, @[0x1.byte])
    builder.addCodeChange(address1, 1, @[0x2.byte])
    builder.addCodeChange(address1, 2, @[0x3.byte])

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].codeChanges[0] = bal[0].codeChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code changes with duplicates should fail validation":
    builder.addCodeChange(address1, 0, @[0x1.byte])
    builder.addCodeChange(address1, 1, @[0x2.byte])
    builder.addCodeChange(address1, 2, @[0x3.byte])

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].codeChanges.insert bal[0].codeChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

suite "Partial block access list verification":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    address4 = address"0x40007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()

  setup:
    let suppliedBuilder = BlockAccessListBuilderRef.init()
    suppliedBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    suppliedBuilder.addStorageWrite(address1, slot1, 2, 222.u256)
    suppliedBuilder.addStorageRead(address1, slot2)
    suppliedBuilder.addBalanceChange(address1, 1, 11.u256)
    suppliedBuilder.addNonceChange(address1, 1, 5.AccountNonce)
    suppliedBuilder.addStorageWrite(address2, slot3, 2, 333.u256)
    suppliedBuilder.addBalanceChange(address2, 2, 22.u256)
    suppliedBuilder.addStorageRead(address3, slot3)

    let
      supplied = suppliedBuilder.buildBlockAccessList()
      partialBuilder = BlockAccessListBuilderRef.init()

  test "Valid partial BAL for the first transaction":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)
    partialBuilder.addStorageRead(address1, slot2)
    partialBuilder.addStorageRead(address3, slot3)
    partialBuilder.addStorageRead(address2, slot3)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isOk()

  test "Valid partial BAL for the second transaction":
    partialBuilder.addStorageWrite(address1, slot1, 2, 222.u256)
    partialBuilder.addStorageWrite(address2, slot3, 2, 333.u256)
    partialBuilder.addBalanceChange(address2, 2, 22.u256)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 2).isOk()

  test "Empty partial BAL is rejected when the supplied BAL has writes at the index":
    let partial = partialBuilder.buildBlockAccessList()
    check:
      verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()
      verifyPartialBlockAccessList(partial[], supplied[], 2).isErr()
      verifyPartialBlockAccessList(partial[], supplied[], 3).isOk()

  test "Storage write value mismatch is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 999.u256)
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Storage write not in the supplied BAL is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addStorageWrite(address1, slot2, 1, 999.u256)
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Missing storage write at the index is rejected":
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Missing balance change is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Balance change value mismatch is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addBalanceChange(address1, 1, 999.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Touched account not in the supplied BAL is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)
    partialBuilder.addTouchedAccount(address4)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Storage read not in the supplied BAL is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 1, 111.u256)
    partialBuilder.addBalanceChange(address1, 1, 11.u256)
    partialBuilder.addNonceChange(address1, 1, 5.AccountNonce)
    partialBuilder.addStorageRead(address1, slot3)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 1).isErr()

  test "Untouched account with writes at the index in the supplied BAL is rejected":
    partialBuilder.addStorageWrite(address1, slot1, 2, 222.u256)

    let partial = partialBuilder.buildBlockAccessList()
    check verifyPartialBlockAccessList(partial[], supplied[], 2).isErr()

when ENABLE_BENCHMARKS:
  import std/times

  suite "Block access list validation benchmarks":
    setup:
      let builder = BlockAccessListBuilderRef.init()

      builder.addTouchedAccount(address3)
      builder.addTouchedAccount(address2)
      builder.addTouchedAccount(address1)

      builder.addStorageWrite(address1, slot3, 0, 3.u256)
      builder.addStorageWrite(address1, slot2, 2, 2.u256)
      builder.addStorageWrite(address1, slot1, 1, 1.u256)
      builder.addStorageWrite(address2, slot1, 1, 1.u256)
      builder.addStorageWrite(address1, slot3, 3, 4.u256)

      builder.addStorageRead(address2, slot3)
      builder.addStorageRead(address2, slot2)
      builder.addStorageRead(address3, slot3)
      builder.addStorageRead(address1, slot1)

      builder.addBalanceChange(address2, 1, 0.u256)
      builder.addBalanceChange(address2, 0, 1.u256)
      builder.addBalanceChange(address3, 3, 3.u256)
      builder.addBalanceChange(address1, 2, 2.u256)

      builder.addNonceChange(address1, 3, 3)
      builder.addNonceChange(address2, 2, 2)
      builder.addNonceChange(address2, 1, 1)
      builder.addNonceChange(address3, 1, 1)

      builder.addCodeChange(address2, 0, @[0x1.byte])
      builder.addCodeChange(address2, 1, @[0x2.byte])
      builder.addCodeChange(address1, 3, @[0x3.byte])

    test "Benchmark validation":
      let
        bal = builder.buildBlockAccessList()
        balHash = bal[].computeBlockAccessListHash()

      let start = cpuTime()
      for i in 0..<1000000:
        check bal.validate(balHash).isOk()
      let finish = cpuTime()

      echo "Total run time: ", (finish - start)
