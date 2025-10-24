# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets, algorithm],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  stew/byteutils

type
  # Account data stored in the builder during block execution.
  # This type tracks all changes made to a single account throughout
  # the execution of a block, organized by the type of change and the
  # block access list index where it occurred.
  AccountData = object
    storageChanges: Table[UInt256, Table[int, UInt256]]
      ## Maps storage key -> block access list index -> storage value
    storageReads: HashSet[UInt256]
      ## Set of storage keys
    balanceChanges: Table[int, UInt256]
      ## Maps block access list index -> balance
    nonceChanges: Table[int, AccountNonce]
      ## Maps block access list index -> nonce
    codeChanges: Table[int, seq[byte]]
      ## Maps block access list index -> code

  # Builder for constructing a BlockAccessList efficiently during transaction
  # execution.
  # The builder accumulates all account and storage accesses during block
  # execution and constructs a deterministic access list. Changes are tracked
  # by address, field type, and block access list index to enable efficient
  # reconstruction of state changes.
  BlockAccessListBuilderRef* = ref object
    accounts: Table[Address, AccountData]
      ## Maps address -> account data

proc init*(T: type AccountData): T =
  AccountData()

# Disallow copying of AccountData
proc `=copy`(dest: var AccountData; src: AccountData) {.error: "Copying AccountData is forbidden".} =
  discard

proc init*(T: type BlockAccessListBuilderRef): T =
  BlockAccessListBuilderRef()

proc ensureAccount(builder: BlockAccessListBuilderRef, address: Address) =
  if address notin builder.accounts:
    builder.accounts[address] = AccountData.init()

proc addStorageWrite*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    slot: UInt256,
    blockAccessIndex: int,
    newValue: UInt256) =

  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    if slot notin accData[].storageChanges:
      accData[].storageChanges[slot] = default(Table[int, UInt256])
    accData[].storageChanges.withValue(slot, slotChanges):
      slotChanges[][blockAccessIndex] = newValue

proc addStorageRead*(builder: BlockAccessListBuilderRef, address: Address, slot: UInt256) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].storageReads.incl(slot)

proc addBalanceChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    postBalance: UInt256) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].balanceChanges[blockAccessIndex] = postBalance

proc addNonceChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newNonce: AccountNonce) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].nonceChanges[blockAccessIndex] = newNonce

proc addCodeChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newCode: seq[byte]) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].codeChanges[blockAccessIndex] = newCode

proc addTouchedAccount*(builder: BlockAccessListBuilderRef, address: Address) =
  ensureAccount(builder, address)

proc balIndexCmp(x, y: StorageChange | BalanceChange | NonceChange | CodeChange): int =
  cmp(x.blockAccessIndex, y.blockAccessIndex)

proc slotCmp(x, y: SlotChanges): int =
  cmp(x.slot, y.slot)

proc addressCmp(x, y: AccountChanges): int =
  cmp(x.address.data.toHex(), y.address.data.toHex())

proc buildBlockAccessList*(builder: BlockAccessListBuilderRef): BlockAccessList =
  var blockAccessList: BlockAccessList

  for address, accData in builder.accounts:
    # Collect and sort storageChanges
    var storageChanges: seq[SlotChanges]
    for slot, changes in accData.storageChanges:
      var slotChanges: seq[StorageChange]

      for balIndex, value in changes:
        slotChanges.add((BlockAccessIndex(balIndex), StorageValue(value)))
      slotChanges.sort(balIndexCmp)

      storageChanges.add((StorageKey(slot), slotChanges))
    storageChanges.sort(slotCmp)

    # Collect and sort storageReads
    var storageReads: seq[StorageKey]
    for slot in accData.storageReads:
      if slot notin accData.storageChanges:
        storageReads.add(slot)
    storageReads.sort()

    # Collect and sort balanceChanges
    var balanceChanges: seq[BalanceChange]
    for balIndex, balance in accData.balanceChanges:
      balanceChanges.add((BlockAccessIndex(balIndex), Balance(balance)))
    balanceChanges.sort(balIndexCmp)

    # Collect and sort nonceChanges
    var nonceChanges: seq[NonceChange]
    for balIndex, nonce in accData.nonceChanges:
      nonceChanges.add((BlockAccessIndex(balIndex), Nonce(nonce)))
    nonceChanges.sort(balIndexCmp)

    # Collect and sort codeChanges
    var codeChanges: seq[CodeChange]
    for balIndex, code in accData.codeChanges:
      codeChanges.add((BlockAccessIndex(balIndex), CodeData(code)))
    codeChanges.sort(balIndexCmp)

    blockAccessList.add(AccountChanges(
      address: address,
      storageChanges: storageChanges,
      storageReads: storageReads,
      balanceChanges: balanceChanges,
      nonceChanges: nonceChanges,
      codeChanges: codeChanges
    ))

  blockAccessList.sort(addressCmp)

  blockAccessList
