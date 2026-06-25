# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
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
  eth/common/block_access_lists,
  ../../execution_chain/block_access_list/block_access_list_utils

func accountChanges(address: Address): AccountChanges =
  # Only the address is relevant for findAccountChanges, so the change lists are
  # left empty. All fields are set explicitly to satisfy ImplicitDefaultValue.
  AccountChanges(
    address: address,
    storageChanges: @[],
    storageReads: @[],
    balanceChanges: @[],
    nonceChanges: @[],
    codeChanges: @[],
  )

func balanceChangesAt(indices: openArray[int]): seq[BalanceChange] =
  # Builds a BalanceChange list with the given blockAccessIndex values. Only the
  # index matters to findLastWriteBefore, so the post balances are left as zero.
  for i in indices:
    result.add((BlockAccessIndex(i), 0.u256))

suite "Block access list utils":
  # These tests exercise the binary search helpers in block_access_list_utils
  # directly with small, hand-constructed and pre-sorted inputs, covering the
  # boundary, not-found, empty and single-element cases. Both length classes of
  # std/algorithm.binarySearch (the power-of-two fast path and the general path)
  # are covered.

  let
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    address4 = address"0x40007bc31cedb7bfb8a345f31e668033056b2728"
    addressBelow = address"0x00007bc31cedb7bfb8a345f31e668033056b2728"
    addressBetween = address"0x25007bc31cedb7bfb8a345f31e668033056b2728"
    addressAbove = address"0xff007bc31cedb7bfb8a345f31e668033056b2728"

  test "findAccountChanges returns the index of a matching address or -1":
    # The BAL is assumed to be sorted by address. Length 4 hits the power-of-two
    # code path of binarySearch.
    let bal = @[
      accountChanges(address1),
      accountChanges(address2),
      accountChanges(address3),
      accountChanges(address4),
    ]
    check:
      bal.findAccountChanges(address1) == 0
      bal.findAccountChanges(address2) == 1
      bal.findAccountChanges(address3) == 2
      bal.findAccountChanges(address4) == 3

    # Addresses below, between and above the range are not found.
    check:
      bal.findAccountChanges(addressBelow) == -1
      bal.findAccountChanges(addressBetween) == -1
      bal.findAccountChanges(addressAbove) == -1

    # Length 3 hits the other (non power-of-two) binarySearch code path.
    let bal3 =
      @[accountChanges(address1), accountChanges(address2), accountChanges(address3)]
    check:
      bal3.findAccountChanges(address1) == 0
      bal3.findAccountChanges(address3) == 2
      bal3.findAccountChanges(addressBetween) == -1
      bal3.findAccountChanges(address4) == -1

    # Empty and single-element lists.
    let emptyBal: seq[AccountChanges] = @[]
    check:
      emptyBal.findAccountChanges(address1) == -1

    let singleBal = @[accountChanges(address2)]
    check:
      singleBal.findAccountChanges(address2) == 0
      singleBal.findAccountChanges(address1) == -1
      singleBal.findAccountChanges(address3) == -1

  test "findSlotChanges returns the index of a matching slot or -1":
    # Storage changes are assumed to be sorted by slot. Only the slot is used by
    # the lookup, so the change lists are left empty.
    let storageChanges: seq[SlotChanges] = @[
      (slot: 2.u256, changes: newSeq[StorageChange]()),
      (slot: 4.u256, changes: newSeq[StorageChange]()),
      (slot: 6.u256, changes: newSeq[StorageChange]()),
      (slot: 8.u256, changes: newSeq[StorageChange]()),
    ]
    check:
      storageChanges.findSlotChanges(2.u256) == 0
      storageChanges.findSlotChanges(4.u256) == 1
      storageChanges.findSlotChanges(6.u256) == 2
      storageChanges.findSlotChanges(8.u256) == 3

    # Slots below, between and above the range are not found.
    check:
      storageChanges.findSlotChanges(0.u256) == -1
      storageChanges.findSlotChanges(1.u256) == -1
      storageChanges.findSlotChanges(3.u256) == -1
      storageChanges.findSlotChanges(5.u256) == -1
      storageChanges.findSlotChanges(7.u256) == -1
      storageChanges.findSlotChanges(9.u256) == -1

    # Empty and single-element lists.
    let emptyChanges: seq[SlotChanges] = @[]
    check:
      emptyChanges.findSlotChanges(2.u256) == -1

    let singleChanges: seq[SlotChanges] =
      @[(slot: 4.u256, changes: newSeq[StorageChange]())]
    check:
      singleChanges.findSlotChanges(4.u256) == 0
      singleChanges.findSlotChanges(2.u256) == -1
      singleChanges.findSlotChanges(6.u256) == -1

  # findLastWriteBefore returns the index of the last change whose
  # blockAccessIndex is strictly less than balIndex, or -1 if there is none. The
  # changes are assumed to be sorted ascending by blockAccessIndex. The following
  # tests cover the empty, single, two and three element lists.

  test "findLastWriteBefore on an empty list returns -1":
    let changes: seq[BalanceChange] = @[]
    check:
      changes.findLastWriteBefore(0) == -1
      changes.findLastWriteBefore(1) == -1
      changes.findLastWriteBefore(100) == -1

  test "findLastWriteBefore on a single-element list":
    # The single write is at blockAccessIndex 5.
    let changes = balanceChangesAt([5])
    check:
      changes.findLastWriteBefore(0) == -1 # below the write
      changes.findLastWriteBefore(4) == -1 # still below
      changes.findLastWriteBefore(5) == -1 # equal: strict, nothing precedes
      changes.findLastWriteBefore(6) == 0 # above: resolves to the write
      changes.findLastWriteBefore(100) == 0

  test "findLastWriteBefore on a two-element list":
    # Writes are at blockAccessIndex 2 and 4.
    let changes = balanceChangesAt([2, 4])
    check:
      changes.findLastWriteBefore(0) == -1 # below both
      changes.findLastWriteBefore(2) == -1 # equal first: nothing precedes
      changes.findLastWriteBefore(3) == 0 # between: first write
      changes.findLastWriteBefore(4) == 0 # equal second: first write
      changes.findLastWriteBefore(5) == 1 # above both: second write
      changes.findLastWriteBefore(100) == 1

  test "findLastWriteBefore on a three-element list":
    # Writes are at blockAccessIndex 1, 3 and 5.
    let changes = balanceChangesAt([1, 3, 5])
    check:
      changes.findLastWriteBefore(0) == -1 # below all
      changes.findLastWriteBefore(1) == -1 # equal first: nothing precedes
      changes.findLastWriteBefore(2) == 0 # between first and middle
      changes.findLastWriteBefore(3) == 0 # equal middle: first write
      changes.findLastWriteBefore(4) == 1 # between middle and last
      changes.findLastWriteBefore(5) == 1 # equal last: middle write
      changes.findLastWriteBefore(6) == 2 # above all: last write
      changes.findLastWriteBefore(100) == 2

  test "findLastWriteBefore is generic over the change tuple types":
    # The same lookup is used for storage, balance, nonce and code changes. Here
    # StorageChange and NonceChange are exercised (BalanceChange is used above).
    let storageChanges: seq[StorageChange] = @[
      (BlockAccessIndex(2), 22.u256),
      (BlockAccessIndex(6), 66.u256),
    ]
    check:
      storageChanges.findLastWriteBefore(2) == -1
      storageChanges.findLastWriteBefore(3) == 0
      storageChanges.findLastWriteBefore(7) == 1

    let nonceChanges: seq[NonceChange] = @[
      (BlockAccessIndex(0), 1.AccountNonce),
      (BlockAccessIndex(4), 9.AccountNonce),
    ]
    check:
      nonceChanges.findLastWriteBefore(0) == -1
      nonceChanges.findLastWriteBefore(1) == 0
      nonceChanges.findLastWriteBefore(5) == 1
