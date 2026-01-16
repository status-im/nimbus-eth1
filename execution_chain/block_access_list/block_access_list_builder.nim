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
  std/[tables, sets, algorithm, locks],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  stew/byteutils

export block_access_lists

type
  # Account data stored in the builder during block execution. This type tracks
  # all changes made to a single account throughout the execution of a block,
  # organized by the type of change and the block access list index where it
  # occurred.
  AccountData = object
    storageChanges*: Table[UInt256, Table[int, UInt256]]
      ## Maps storage key -> block access index -> storage value
    storageReads*: HashSet[UInt256]
      ## Set of storage keys
    balanceChanges*: Table[int, UInt256]
      ## Maps block access index -> balance
    nonceChanges*: Table[int, AccountNonce]
      ## Maps block access index -> nonce
    codeChanges*: Table[int, seq[byte]]
      ## Maps block access index -> code

  # Builder for constructing a BlockAccessList efficiently during transaction
  # execution. The builder accumulates all account and storage accesses during
  # block execution and constructs a deterministic access list. Changes are
  # tracked by address, field type, and block access list index to enable
  # efficient reconstruction of state changes.
  BlockAccessListBuilderRef* = ref object of RootObj
    accounts*: Table[Address, AccountData]
      ## Maps address -> account data

  ConcurrentBlockAccessListBuilderRef* = ref object of BlockAccessListBuilderRef
    lock: Lock

template init*(T: type AccountData): T =
  AccountData()

# Disallow copying of AccountData
proc `=copy`(dest: var AccountData; src: AccountData) {.error: "Copying AccountData is forbidden".} =
  discard

template init*(T: type BlockAccessListBuilderRef): T =
  BlockAccessListBuilderRef()

func init*(T: type ConcurrentBlockAccessListBuilderRef): T =
  var lock = Lock()
  initLock(lock)
  ConcurrentBlockAccessListBuilderRef(lock: lock)

func ensureAccount(builder: BlockAccessListBuilderRef, address: Address) =
  if address notin builder.accounts:
    builder.accounts[address] = AccountData.init()

template addTouchedAccount*(builder: BlockAccessListBuilderRef, address: Address) =
  ensureAccount(builder, address)

template addTouchedAccount*(builder: ConcurrentBlockAccessListBuilderRef, address: Address) =
  withLock(builder.lock):
    ensureAccount(builder, address)

func addTouchedAccount*(builder: ptr ConcurrentBlockAccessListBuilderRef, adr: Address) =
  builder[].addTouchedAccount(adr)

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

template addStorageWrite*(
    builder: ConcurrentBlockAccessListBuilderRef,
    address: Address,
    slot: UInt256,
    blockAccessIndex: int,
    newValue: UInt256) =
  withLock(builder.lock):
    addStorageWrite(builder.BlockAccessListBuilderRef, address, slot, blockAccessIndex, newValue)

func addStorageWrite*(
    builder: ptr ConcurrentBlockAccessListBuilderRef,
    address: Address,
    slot: UInt256,
    blockAccessIndex: int,
    newValue: UInt256) =
  builder[].addStorageWrite(address, slot, blockAccessIndex, newValue)

proc addStorageRead*(builder: BlockAccessListBuilderRef, address: Address, slot: UInt256) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].storageReads.incl(slot)

template addStorageRead*(builder: ConcurrentBlockAccessListBuilderRef, address: Address, slot: UInt256) =
  withLock(builder.lock):
    addStorageRead(builder.BlockAccessListBuilderRef, address, slot)

func addStorageRead*(builder: ptr ConcurrentBlockAccessListBuilderRef, address: Address, slot: UInt256) =
  builder[].addStorageRead(address, slot)

proc addBalanceChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    postBalance: UInt256) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].balanceChanges[blockAccessIndex] = postBalance

template addBalanceChange*(
    builder: ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    postBalance: UInt256) =
  withLock(builder.lock):
    addBalanceChange(builder.BlockAccessListBuilderRef, address, blockAccessIndex, postBalance)

func addBalanceChange*(
    builder: ptr ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    postBalance: UInt256) =
  builder[].addBalanceChange(address, blockAccessIndex, postBalance)

proc addNonceChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newNonce: AccountNonce) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].nonceChanges[blockAccessIndex] = newNonce

template addNonceChange*(
    builder: ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newNonce: AccountNonce) =
  withLock(builder.lock):
    addNonceChange(builder.BlockAccessListBuilderRef, address, blockAccessIndex, newNonce)

func addNonceChange*(
    builder: ptr ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newNonce: AccountNonce) =
  builder[].addNonceChange(address, blockAccessIndex, newNonce)

proc addCodeChange*(
    builder: BlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newCode: seq[byte]) =
  builder.ensureAccount(address)

  builder.accounts.withValue(address, accData):
    accData[].codeChanges[blockAccessIndex] = newCode

template addCodeChange*(
    builder: ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newCode: seq[byte]) =
  withLock(builder.lock):
    addCodeChange(builder.BlockAccessListBuilderRef, address, blockAccessIndex, newCode)

func addCodeChange*(
    builder: ptr ConcurrentBlockAccessListBuilderRef,
    address: Address,
    blockAccessIndex: int,
    newCode: seq[byte]) =
  builder[].addCodeChange(address, blockAccessIndex, newCode)

func balIndexCmp(x, y: StorageChange | BalanceChange | NonceChange | CodeChange): int =
  cmp(x.blockAccessIndex, y.blockAccessIndex)

func slotChangesCmp(x, y: SlotChanges): int =
  cmp(x.slot, y.slot)

func accChangesCmp(x, y: AccountChanges): int =
  cmp(x.address.data.toHex(), y.address.data.toHex())

func buildBlockAccessList*(builder: BlockAccessListBuilderRef): BlockAccessListRef =
  let blockAccessList: BlockAccessListRef = new BlockAccessList

  for address, accData in builder.accounts.mpairs():
    # Collect and sort storageChanges
    var storageChanges: seq[SlotChanges]
    for slot, changes in accData.storageChanges:
      var slotChanges: seq[StorageChange]

      for balIndex, value in changes:
        slotChanges.add((BlockAccessIndex(balIndex), StorageValue(value)))
      slotChanges.sort(balIndexCmp)

      storageChanges.add((StorageKey(slot), slotChanges))
    storageChanges.sort(slotChangesCmp)

    # Collect and sort storageReads
    var storageReads: seq[StorageKey]
    for slot in accData.storageReads:
      if slot notin accData.storageChanges:
        storageReads.add(StorageKey(slot))
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
      codeChanges.add((BlockAccessIndex(balIndex), Bytecode(code)))
    codeChanges.sort(balIndexCmp)

    blockAccessList[].add(AccountChanges(
      address: address,
      storageChanges: storageChanges,
      storageReads: storageReads,
      balanceChanges: balanceChanges,
      nonceChanges: nonceChanges,
      codeChanges: codeChanges
    ))

  blockAccessList[].sort(accChangesCmp)

  blockAccessList

func buildBlockAccessList*(builder: ConcurrentBlockAccessListBuilderRef): BlockAccessListRef =
  var bal: BlockAccessListRef
  withLock(builder.lock):
    bal = buildBlockAccessList(builder.BlockAccessListBuilderRef)
  bal
