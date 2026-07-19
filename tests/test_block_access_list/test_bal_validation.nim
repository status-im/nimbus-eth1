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
  ../../execution_chain/constants,
  ../../execution_chain/block_access_list/[bal_builder, bal_validation]

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
    var builder: BlockAccessListBuilder
    builder.init()
    # These tests use block access indices 0 .. 3.
    builder.ensureIndexCount(4)

  teardown:
    builder.dispose()

  test "Empty BAL should equal the EMPTY_BLOCK_ACCESS_LIST_HASH":
    let emptyBal = builder.buildBlockAccessList()
    check:
      emptyBal.validate(EMPTY_BLOCK_ACCESS_LIST_HASH).isOk()
      emptyBal.validate(default(Hash32)).isErr()

  test "Valid BAL should validate successfully":
    builder.addTouchedAccount(0, address3)
    builder.addTouchedAccount(0, address2)
    builder.addTouchedAccount(0, address1)
    builder.addTouchedAccount(0, address1) # duplicate

    builder.addStorageWrite(0, address1, slot3, 3.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(1, address2, slot1, 1.u256)
    builder.addStorageWrite(3, address1, slot3, 4.u256)
    builder.addStorageWrite(3, address1, slot3, 5.u256) # duplicate should overwrite

    builder.addStorageRead(0, address2, slot3)
    builder.addStorageRead(0, address2, slot2)
    builder.addStorageRead(0, address3, slot3)
    builder.addStorageRead(0, address1, slot1)
    builder.addStorageRead(0, address1, slot1) # duplicate

    builder.addBalanceChange(1, address2, 0.u256)
    builder.addBalanceChange(0, address2, 1.u256)
    builder.addBalanceChange(3, address3, 3.u256)
    builder.addBalanceChange(2, address1, 2.u256)
    builder.addBalanceChange(2, address1, 10.u256) # duplicate should overwrite

    builder.addNonceChange(3, address1, 3)
    builder.addNonceChange(2, address2, 2)
    builder.addNonceChange(1, address2, 1)
    builder.addNonceChange(1, address3, 1)
    builder.addNonceChange(1, address3, 10) # duplicate should overwrite

    builder.addCodeChange(0, address2, @[0x1.byte])
    builder.addCodeChange(1, address2, @[0x2.byte])
    builder.addCodeChange(3, address1, @[0x3.byte])
    builder.addCodeChange(3, address1, @[0x4.byte]) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()

  test "Storage changes and reads don't overlap for the same slot":
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(3, address1, slot3, 3.u256)

    var bal = builder.buildBlockAccessList()
    bal[0].storageReads = @[slot1]

    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Account changes out of order should fail validation":
    builder.addTouchedAccount(0, address1)
    builder.addTouchedAccount(0, address2)
    builder.addTouchedAccount(0, address3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0] = bal[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Account changes with duplicates should fail validation":
    builder.addTouchedAccount(0, address1)
    builder.addTouchedAccount(0, address2)
    builder.addTouchedAccount(0, address3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[].insert(bal[0]) # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage changes out of order should fail validation":
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(3, address1, slot3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0] = bal[0].storageChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage changes with duplicates should fail validation":
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(3, address1, slot3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges.insert bal[0].storageChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot with no changes should fail validation":
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(3, address1, slot3, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes.setLen(0) # remove all changes for the slot
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot changes out of order should fail validation":
    builder.addStorageWrite(0, address1, slot1, 0.u256)
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot1, 2.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes[0] = bal[0].storageChanges[0].changes[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Slot changes with duplicates should fail validation":
    builder.addStorageWrite(0, address1, slot1, 0.u256)
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(2, address1, slot1, 2.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageChanges[0].changes.insert bal[0].storageChanges[0].changes[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage reads out of order should fail validation":
    builder.addStorageRead(0, address1, slot1)
    builder.addStorageRead(0, address1, slot2)
    builder.addStorageRead(0, address1, slot3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageReads[0] = bal[0].storageReads[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Storage reads with duplicates should fail validation":
    builder.addStorageRead(0, address1, slot1)
    builder.addStorageRead(0, address1, slot2)
    builder.addStorageRead(0, address1, slot3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].storageReads.insert bal[0].storageReads[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Balance changes out of order should fail validation":
    builder.addBalanceChange(1, address1, 1.u256)
    builder.addBalanceChange(2, address1, 2.u256)
    builder.addBalanceChange(3, address1, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].balanceChanges[0] = bal[0].balanceChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Balance changes with duplicates should fail validation":
    builder.addBalanceChange(1, address1, 1.u256)
    builder.addBalanceChange(2, address1, 2.u256)
    builder.addBalanceChange(3, address1, 3.u256)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].balanceChanges.insert bal[0].balanceChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Nonce changes out of order should fail validation":
    builder.addNonceChange(1, address1, 1)
    builder.addNonceChange(2, address1, 2)
    builder.addNonceChange(3, address1, 3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].nonceChanges[0] = bal[0].nonceChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Nonce changes with duplicates should fail validation":
    builder.addNonceChange(1, address1, 1)
    builder.addNonceChange(2, address1, 2)
    builder.addNonceChange(3, address1, 3)

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].nonceChanges.insert bal[0].nonceChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code changes out of order should fail validation":
    builder.addCodeChange(0, address1, @[0x1.byte])
    builder.addCodeChange(1, address1, @[0x2.byte])
    builder.addCodeChange(2, address1, @[0x3.byte])

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].codeChanges[0] = bal[0].codeChanges[2]
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code changes with duplicates should fail validation":
    builder.addCodeChange(0, address1, @[0x1.byte])
    builder.addCodeChange(1, address1, @[0x2.byte])
    builder.addCodeChange(2, address1, @[0x3.byte])

    var bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()
    bal[0].codeChanges.insert bal[0].codeChanges[0] # duplicate the first item
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with empty bytecode should validate":
    builder.addCodeChange(0, address1, newSeq[byte](0))

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()

  test "Code change with bytecode at the max size should validate":
    builder.addCodeChange(0, address1, newSeq[byte](EIP7954_MAX_CODE_SIZE))

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()

  test "Code change with bytecode exceeding the max size should fail validation":
    builder.addCodeChange(0, address1, newSeq[byte](EIP7954_MAX_CODE_SIZE + 1))

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with a valid EIP-7702 delegation designator should validate":
    # 0xef0100 prefix followed by a 20-byte address (23 bytes total).
    let delegation = @[0xEF.byte, 0x01, 0x00] & newSeq[byte](20)
    builder.addCodeChange(0, address1, delegation)

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isOk()

  test "Code change starting with 0xEF that is not a delegation should fail (EIP-3541)":
    builder.addCodeChange(0, address1, @[0xEF.byte, 0x60, 0x00])

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with a malformed EIP-7702 delegation should fail (EIP-3541)":
    # Correct 0xef0100 prefix but the wrong total length (22 instead of 23 bytes).
    let malformed = @[0xEF.byte, 0x01, 0x00] & newSeq[byte](19)
    builder.addCodeChange(0, address1, malformed)

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with a wrong EIP-7702 version byte should fail (EIP-3541)":
    # 23 bytes starting with 0xef01 but a non-zero version byte is not a valid
    # delegation designator.
    let badVersion = @[0xEF.byte, 0x01, 0x01] & newSeq[byte](20)
    builder.addCodeChange(0, address1, badVersion)

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with a wrong EIP-7702 second prefix byte should fail (EIP-3541)":
    # 23 bytes with the 0xEF prefix but a wrong second byte (0xef02..) is not a
    # valid delegation designator.
    let badPrefix = @[0xEF.byte, 0x02, 0x00] & newSeq[byte](20)
    builder.addCodeChange(0, address1, badPrefix)

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with single 0xEF byte should fail (EIP-3541)":
    # Too short to be a delegation designator; the length guard must short-circuit
    # before the prefix bytes are indexed.
    builder.addCodeChange(0, address1, @[0xEF.byte])

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

  test "Code change with two byte 0xef01 should fail (EIP-3541)":
    builder.addCodeChange(0, address1, @[0xEF.byte, 0x01])

    let bal = builder.buildBlockAccessList()
    check bal.validate(bal[].computeBlockAccessListHash()).isErr()

when ENABLE_BENCHMARKS:
  import std/times

  suite "Block access list validation benchmarks":
    setup:
      var builder: BlockAccessListBuilder
      builder.init()
      builder.ensureIndexCount(4)

      builder.addTouchedAccount(0, address3)
      builder.addTouchedAccount(0, address2)
      builder.addTouchedAccount(0, address1)

      builder.addStorageWrite(0, address1, slot3, 3.u256)
      builder.addStorageWrite(2, address1, slot2, 2.u256)
      builder.addStorageWrite(1, address1, slot1, 1.u256)
      builder.addStorageWrite(1, address2, slot1, 1.u256)
      builder.addStorageWrite(3, address1, slot3, 4.u256)

      builder.addStorageRead(0, address2, slot3)
      builder.addStorageRead(0, address2, slot2)
      builder.addStorageRead(0, address3, slot3)
      builder.addStorageRead(0, address1, slot1)

      builder.addBalanceChange(1, address2, 0.u256)
      builder.addBalanceChange(0, address2, 1.u256)
      builder.addBalanceChange(3, address3, 3.u256)
      builder.addBalanceChange(2, address1, 2.u256)

      builder.addNonceChange(3, address1, 3)
      builder.addNonceChange(2, address2, 2)
      builder.addNonceChange(1, address2, 1)
      builder.addNonceChange(1, address3, 1)

      builder.addCodeChange(0, address2, @[0x1.byte])
      builder.addCodeChange(1, address2, @[0x2.byte])
      builder.addCodeChange(3, address1, @[0x3.byte])

    teardown:
      builder.dispose()

    test "Benchmark validation":
      let
        bal = builder.buildBlockAccessList()
        balHash = bal[].computeBlockAccessListHash()

      let start = cpuTime()
      for i in 0..<1000000:
        check bal.validate(balHash).isOk()
      let finish = cpuTime()

      echo "Total run time: ", (finish - start)
