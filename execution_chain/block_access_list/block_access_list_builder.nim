# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[algorithm, locks],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  ./block_access_list_utils,
  ../concurrency/shared_types

export block_access_lists

type
  # Account data stored in the builder during block execution. This type tracks
  # all changes made to a single account throughout the execution of a block,
  # organized by the type of change and the block access list index where it
  # occurred.
  AccountData = object
    storageChanges*: SharedTable[UInt256, SharedTable[int, UInt256]]
      ## Maps storage key -> block access index -> storage value
    storageReads*: SharedTable[UInt256, bool]
      ## Set of storage keys (the value is always true when the key exists)
    balanceChanges*: SharedTable[int, UInt256] ## Maps block access index -> balance
    nonceChanges*: SharedTable[int, AccountNonce] ## Maps block access index -> nonce
    codeChanges*: SharedTable[int, SharedBytes] ## Maps block access index -> code

  # Builder for constructing a BlockAccessList efficiently during transaction
  # execution. The builder accumulates all account and storage accesses during
  # block execution and constructs a deterministic access list. Changes are
  # tracked by address, field type, and block access list index to enable
  # efficient reconstruction of state changes.
  #
  # All collections use the non-GC SharedTable type (rather than the standard
  # library Table/HashSet which are backed by a GC managed seq) so that the
  # builder can be used safely with the refc memory manager across threads.
  BlockAccessListBuilder* = object
    accounts*: SharedTable[Address, AccountData] ## Maps address -> account data
    threadSafe: bool
    lock: Lock

template init(T: type AccountData): T =
  AccountData()

proc dispose(accData: var AccountData) =
  for slotChanges in accData.storageChanges.mvalues():
    slotChanges.dispose()
  accData.storageChanges.dispose()
  accData.storageReads.dispose()
  accData.balanceChanges.dispose()
  accData.nonceChanges.dispose()
  for code in accData.codeChanges.mvalues():
    code.dispose()
  accData.codeChanges.dispose()

proc `=copy`(
    dest: var AccountData, src: AccountData
) {.error: "Copying AccountData is forbidden".} =
  discard

proc init*(builder: var BlockAccessListBuilder, threadSafe = false) =
  builder.threadSafe = threadSafe
  if threadSafe:
    initLock(builder.lock)

template init*(T: type BlockAccessListBuilder, threadSafe = false): var T =
  var builder = T()
  builder.init(threadSafe)
  builder

proc dispose*(builder: var BlockAccessListBuilder) =
  for accData in builder.accounts.mvalues():
    accData.dispose()
  builder.accounts.dispose()
  if builder.threadSafe:
    deinitLock(builder.lock)

proc `=copy`(
    dest: var BlockAccessListBuilder, src: BlockAccessListBuilder
) {.error: "Copying BlockAccessListBuilder is forbidden".} =
  discard

template withOptionalLock(builder: BlockAccessListBuilder, body: untyped) =
  if builder.threadSafe:
    withLock(builder.lock):
      body
  else:
    body

proc ensureAccount(builder: var BlockAccessListBuilder, address: Address) =
  if address notin builder.accounts:
    builder.accounts[address] = AccountData.init()

proc addTouchedAccount*(builder: var BlockAccessListBuilder, address: Address) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

proc addStorageWrite*(
    builder: var BlockAccessListBuilder,
    address: Address,
    slot: UInt256,
    blockAccessIndex: int,
    newValue: UInt256,
) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

    builder.accounts.withValue(address, accData):
      if slot notin accData[].storageChanges:
        accData[].storageChanges[slot] = default(SharedTable[int, UInt256])
      accData[].storageChanges.withValue(slot, slotChanges):
        slotChanges[][blockAccessIndex] = newValue

proc addStorageRead*(
    builder: var BlockAccessListBuilder, address: Address, slot: UInt256
) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

    builder.accounts.withValue(address, accData):
      accData[].storageReads[slot] = true

proc addBalanceChange*(
    builder: var BlockAccessListBuilder,
    address: Address,
    blockAccessIndex: int,
    postBalance: UInt256,
) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

    builder.accounts.withValue(address, accData):
      accData[].balanceChanges[blockAccessIndex] = postBalance

proc addNonceChange*(
    builder: var BlockAccessListBuilder,
    address: Address,
    blockAccessIndex: int,
    newNonce: AccountNonce,
) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

    builder.accounts.withValue(address, accData):
      accData[].nonceChanges[blockAccessIndex] = newNonce

proc addCodeChange*(
    builder: var BlockAccessListBuilder,
    address: Address,
    blockAccessIndex: int,
    newCode: openArray[byte],
) =
  withOptionalLock(builder):
    builder.ensureAccount(address)

    builder.accounts.withValue(address, accData):
      accData[].codeChanges.withValue(blockAccessIndex, existing):
        existing[].dispose()
      accData[].codeChanges[blockAccessIndex] = SharedBytes.init(newCode)

func buildBlockAccessListImpl(builder: var BlockAccessListBuilder): BlockAccessListRef =
  let blockAccessList: BlockAccessListRef = new BlockAccessList

  for address, accData in builder.accounts.mpairs():
    # Collect and sort storageChanges
    var storageChanges: seq[SlotChanges]
    for slot, changes in accData.storageChanges.mpairs():
      var slotChanges: seq[StorageChange]

      for balIndex, value in changes.pairs():
        slotChanges.add((BlockAccessIndex(balIndex), StorageValue(value)))
      slotChanges.sort(balIndexCmp)

      storageChanges.add((StorageKey(slot), slotChanges))
    storageChanges.sort(slotChangesCmp)

    # Collect and sort storageReads
    var storageReads: seq[StorageKey]
    for slot in accData.storageReads.keys():
      if slot notin accData.storageChanges:
        storageReads.add(StorageKey(slot))
    storageReads.sort()

    # Collect and sort balanceChanges
    var balanceChanges: seq[BalanceChange]
    for balIndex, balance in accData.balanceChanges.pairs():
      balanceChanges.add((BlockAccessIndex(balIndex), Balance(balance)))
    balanceChanges.sort(balIndexCmp)

    # Collect and sort nonceChanges
    var nonceChanges: seq[NonceChange]
    for balIndex, nonce in accData.nonceChanges.pairs():
      nonceChanges.add((BlockAccessIndex(balIndex), Nonce(nonce)))
    nonceChanges.sort(balIndexCmp)

    # Collect and sort codeChanges
    var codeChanges: seq[CodeChange]
    for balIndex, code in accData.codeChanges.mpairs():
      codeChanges.add((BlockAccessIndex(balIndex), Bytecode(code.data())))
    codeChanges.sort(balIndexCmp)

    blockAccessList[].add(
      AccountChanges(
        address: address,
        storageChanges: storageChanges,
        storageReads: storageReads,
        balanceChanges: balanceChanges,
        nonceChanges: nonceChanges,
        codeChanges: codeChanges,
      )
    )

  blockAccessList[].sort(accChangesCmp)

  blockAccessList

func buildBlockAccessList*(builder: var BlockAccessListBuilder): BlockAccessListRef =
  withOptionalLock(builder):
    result = builder.buildBlockAccessListImpl()
