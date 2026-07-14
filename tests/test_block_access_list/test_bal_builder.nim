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
  taskpools,
  ../../execution_chain/block_access_list/bal_builder

suite "Block access list builder":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()

  setup:
    var builder: BlockAccessListBuilder
    builder.init()
    # The sequential tests use block access indices 0 .. 3.
    builder.ensureIndexCount(4)


  teardown:
    builder.dispose()

  test "Add touched account":
    builder.addTouchedAccount(0, address3)
    builder.addTouchedAccount(0, address2)
    builder.addTouchedAccount(0, address1)
    builder.addTouchedAccount(0, address1) # duplicate

    let bal = builder.buildBlockAccessList()[]
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
    builder.addStorageWrite(0, address1, slot3, 3.u256)
    builder.addStorageWrite(2, address1, slot2, 2.u256)
    builder.addStorageWrite(1, address1, slot1, 1.u256)
    builder.addStorageWrite(1, address2, slot1, 1.u256)
    builder.addStorageWrite(3, address1, slot3, 4.u256)
    builder.addStorageWrite(3, address1, slot3, 5.u256) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 2
      bal[0].address == address1
      bal[0].storageChanges.len() == 3
      bal[0].storageChanges[0] == (slot1, @[(1.BlockAccessIndex, 1.u256)])
      bal[0].storageChanges[1] == (slot2, @[(2.BlockAccessIndex, 2.u256)])
      bal[0].storageChanges[2] == (slot3, @[(0.BlockAccessIndex, 3.u256), (3.BlockAccessIndex, 5.u256)])
      bal[1].address == address2
      bal[1].storageChanges.len() == 1
      bal[1].storageChanges[0] == (slot1, @[(1.BlockAccessIndex, 1.u256)])

  test "Add storage read":
    builder.addStorageRead(0, address2, slot3)
    builder.addStorageRead(0, address2, slot2)
    builder.addStorageRead(0, address3, slot3)
    builder.addStorageRead(0, address1, slot1)
    builder.addStorageRead(0, address1, slot1) # duplicate

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].storageReads == @[slot1]
      bal[1].address == address2
      bal[1].storageReads == @[slot2, slot3]
      bal[2].address == address3
      bal[2].storageReads == @[slot3]

  test "Add balance change":
    builder.addBalanceChange(1, address2, 0.u256)
    builder.addBalanceChange(0, address2, 1.u256)
    builder.addBalanceChange(3, address3, 3.u256)
    builder.addBalanceChange(2, address1, 2.u256)
    builder.addBalanceChange(2, address1, 10.u256) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].balanceChanges == @[(2.BlockAccessIndex, 10.u256)]
      bal[1].address == address2
      bal[1].balanceChanges == @[(0.BlockAccessIndex, 1.u256), (1.BlockAccessIndex, 0.u256)]
      bal[2].address == address3
      bal[2].balanceChanges == @[(3.BlockAccessIndex, 3.u256)]

  test "Add nonce change":
    builder.addNonceChange(3, address1, 3)
    builder.addNonceChange(2, address2, 2)
    builder.addNonceChange(1, address2, 1)
    builder.addNonceChange(1, address3, 1)
    builder.addNonceChange(1, address3, 10) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 3
      bal[0].address == address1
      bal[0].nonceChanges == @[(3.BlockAccessIndex, 3.AccountNonce)]
      bal[1].address == address2
      bal[1].nonceChanges == @[(1.BlockAccessIndex, 1.AccountNonce), (2.BlockAccessIndex, 2.AccountNonce)]
      bal[2].address == address3
      bal[2].nonceChanges == @[(1.BlockAccessIndex, 10.AccountNonce)]

  test "Add code change":
    builder.addCodeChange(0, address2, @[0x1.byte])
    builder.addCodeChange(1, address2, @[0x2.byte])
    builder.addCodeChange(3, address1, @[0x3.byte])
    builder.addCodeChange(3, address1, @[0x4.byte]) # duplicate should overwrite

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 2
      bal[0].address == address1
      bal[0].codeChanges == @[(3.BlockAccessIndex, @[0x4.byte])]
      bal[1].address == address2
      bal[1].codeChanges == @[(0.BlockAccessIndex, @[0x1.byte]), (1.BlockAccessIndex, @[0x2.byte])]

  test "Appending two code changes at the same index frees both on dispose":
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 100:
      var b: BlockAccessListBuilder
      b.init()
      b.ensureIndexCount(4)
      b.addCodeChange(3, address1, @[0x1.byte, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8])
      b.addCodeChange(3, address1, @[0x9.byte]) # both buffers retained until dispose
      b.dispose()
    check getOccupiedSharedMem() == before

  test "All changes and reads":
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

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 3

      bal[0].address == address1
      bal[0].storageChanges.len() == 3
      bal[0].storageChanges[0] == (slot1, @[(1.BlockAccessIndex, 1.u256)])
      bal[0].storageChanges[1] == (slot2, @[(2.BlockAccessIndex, 2.u256)])
      bal[0].storageChanges[2] == (slot3, @[(0.BlockAccessIndex, 3.u256), (3.BlockAccessIndex, 5.u256)])
      bal[0].storageReads.len() == 0 # read removed by storage change with the same slot
      bal[0].balanceChanges == @[(2.BlockAccessIndex, 10.u256)]
      bal[0].nonceChanges == @[(3.BlockAccessIndex, 3.AccountNonce)]
      bal[0].codeChanges == @[(3.BlockAccessIndex, @[0x4.byte])]

      bal[1].address == address2
      bal[1].storageChanges.len() == 1
      bal[1].storageChanges[0] == (slot1, @[(1.BlockAccessIndex, 1.u256)])
      bal[1].storageReads == @[slot2, slot3]
      bal[1].balanceChanges == @[(0.BlockAccessIndex, 1.u256), (1.BlockAccessIndex, 0.u256)]
      bal[1].nonceChanges == @[(1.BlockAccessIndex, 1.AccountNonce), (2.BlockAccessIndex, 2.AccountNonce)]
      bal[1].codeChanges == @[(0.BlockAccessIndex, @[0x1.byte]), (1.BlockAccessIndex, @[0x2.byte])]

      bal[2].address == address3
      bal[2].storageReads == @[slot3]
      bal[2].balanceChanges == @[(3.BlockAccessIndex, 3.u256)]
      bal[2].nonceChanges == @[(1.BlockAccessIndex, 10.AccountNonce)]


# The builder is lock-free because each block access index has a single writer.
# These helpers mirror that model: one task per distinct block access index.

proc writeChangesForIndex(
    builder: ptr BlockAccessListBuilder, address: Address, index: int
) =
  ## Simulates a worker thread that exclusively owns block access `index`,
  ## appending a mix of changes for that index.
  builder[].addTouchedAccount(index, address)
  builder[].addStorageWrite(index, address, 1.u256, index.u256)
  builder[].addStorageRead(index, address, 2.u256)
  builder[].addBalanceChange(index, address, (index * 10).u256)
  builder[].addNonceChange(index, address, index.AccountNonce)
  builder[].addCodeChange(index, address, @[index.byte])

proc writeSlotAtIndex(
    builder: ptr BlockAccessListBuilder, address: Address, slot: UInt256, index: int
) =
  builder[].addStorageWrite(index, address, slot, index.u256)

suite "Concurrent block access list builder":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    address4 = address"0x40007bc31cedb7bfb8a345f31e668033056b2728"
    address5 = address"0x50007bc31cedb7bfb8a345f31e668033056b2728"
    address6 = address"0x60007bc31cedb7bfb8a345f31e668033056b2728"
    address7 = address"0x70007bc31cedb7bfb8a345f31e668033056b2728"
    address8 = address"0x80007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()

  setup:
    let taskpool = Taskpool.new()
    var builder: BlockAccessListBuilder
    builder.init()
    let builderPtr = builder.addr

  teardown:
    builder.dispose()

  test "Concurrent writes to distinct block access indices":
    const addresses =
      [address1, address2, address3, address4, address5, address6, address7, address8]

    # Pre-size on the main thread before spawning, exactly like the parallel
    # execution path. Each task then writes only its own distinct index (1..N),
    # so there is a single writer per partition and no locking is required.
    builder.ensureIndexCount(addresses.len + 1)
    for i, a in addresses:
      taskpool.spawn builderPtr.writeChangesForIndex(a, i + 1)
    taskpool.syncAll()

    let bal = builder.buildBlockAccessList()[]
    check bal.len() == addresses.len

    # The addresses are ordered so the sorted BAL matches the array order.
    for i, a in addresses:
      let index = i + 1
      check:
        bal[i].address == a
        bal[i].storageChanges == @[(1.u256, @[(index.BlockAccessIndex, index.u256)])]
        bal[i].storageReads == @[2.u256]
        bal[i].balanceChanges == @[(index.BlockAccessIndex, (index * 10).u256)]
        bal[i].nonceChanges == @[(index.BlockAccessIndex, index.AccountNonce)]
        bal[i].codeChanges == @[(index.BlockAccessIndex, @[index.byte])]

  test "Concurrent writes to the same slot at distinct indices merge":
    # Every task targets the same address and slot but each at its own distinct
    # index, so there is still exactly one writer per partition. The build phase
    # must merge them into one slot with one change per index, sorted by index.
    const n = 8
    builder.ensureIndexCount(n + 1)
    for index in 1 .. n:
      taskpool.spawn builderPtr.writeSlotAtIndex(address1, slot1, index)
    taskpool.syncAll()

    let bal = builder.buildBlockAccessList()[]
    check:
      bal.len() == 1
      bal[0].address == address1
      bal[0].storageChanges.len() == 1
      bal[0].storageChanges[0].slot == slot1
      bal[0].storageChanges[0].changes.len() == n

    for i in 0 ..< n:
      check bal[0].storageChanges[0].changes[i] == ((i + 1).BlockAccessIndex, (i + 1).u256)
