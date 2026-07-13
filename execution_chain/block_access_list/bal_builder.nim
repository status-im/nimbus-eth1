# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Builder for constructing a BlockAccessList efficiently during transaction
# execution. The builder accumulates all account and storage reads and writes
# during block execution and constructs a deterministic access list. Changes
# are tracked by address, field type, and block access list index to enable
# efficient reconstruction of state changes.
#
# All collections use the non-GC SharedSeq type (rather than the standard
# library Seq) so that the builder can be used safely with the refc memory
# manager across threads.

{.push raises: [], gcsafe.}

import
  std/[algorithm],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  ../concurrency/shared_types

export block_access_lists

type
  StorageWrite = tuple[address: Address, slot: UInt256, value: UInt256]
  StorageReadEntry = tuple[address: Address, slot: UInt256]
  BalanceWrite = tuple[address: Address, balance: UInt256]
  NonceWrite = tuple[address: Address, nonce: AccountNonce]
  CodeWrite = tuple[address: Address, code: SharedBytes]

  BalIndexData = object
    touchedAccounts: SharedSeq[Address]
    storageChanges: SharedSeq[StorageWrite]
    storageReads: SharedSeq[StorageReadEntry]
    balanceChanges: SharedSeq[BalanceWrite]
    nonceChanges: SharedSeq[NonceWrite]
    codeChanges: SharedSeq[CodeWrite]


  BlockAccessListBuilder* = object
    perIndex: SharedSeq[BalIndexData]

proc dispose(indexData: var BalIndexData) =
  indexData.touchedAccounts.dispose()
  indexData.storageChanges.dispose()
  indexData.storageReads.dispose()
  indexData.balanceChanges.dispose()
  indexData.nonceChanges.dispose()
  for code in indexData.codeChanges.mitems():
    code.code.dispose()
  indexData.codeChanges.dispose()

proc `=copy`(
    dest: var BalIndexData, src: BalIndexData
) {.error: "Copying BalIndexData is forbidden".} =
  discard

proc init*(builder: var BlockAccessListBuilder) =
  discard

proc newShared*(T: type BlockAccessListBuilder): ptr BlockAccessListBuilder =
  let builderPtr = createShared(BlockAccessListBuilder)
  builderPtr[].init()
  builderPtr

proc dispose*(builder: var BlockAccessListBuilder) =
  for idxData in builder.perIndex.mitems():
    idxData.dispose()
  builder.perIndex.dispose()

proc dispose*(builderPtr: ptr BlockAccessListBuilder) =
  if not builderPtr.isNil():
    builderPtr[].dispose()
    deallocShared(builderPtr)

proc `=copy`(
    dest: var BlockAccessListBuilder, src: BlockAccessListBuilder
) {.error: "Copying BlockAccessListBuilder is forbidden".} =
  discard

proc ensureIndexCount*(builder: var BlockAccessListBuilder, n: int, exact = false) =
  if n > builder.perIndex.len:
    builder.perIndex.setLen(n, zeroed = true, exact)

proc addTouchedAccount*(
    builder: var BlockAccessListBuilder, blockAccessIndex: int, address: Address
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].touchedAccounts.add(address)

proc addStorageWrite*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].storageChanges.add((address, slot, newValue))

proc addStorageRead*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].storageReads.add((address, slot))

proc addBalanceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    postBalance: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].balanceChanges.add((address, postBalance))

proc addNonceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newNonce: AccountNonce,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].nonceChanges.add((address, newNonce))

proc addCodeChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newCode: openArray[byte],
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].codeChanges.add(
    (address, SharedBytes.init(newCode))
  )

type
  FStorage =
    tuple[address: Address, slot: UInt256, index: BlockAccessIndex, value: UInt256]
  FRead = tuple[address: Address, slot: UInt256]
  FBalance = tuple[address: Address, index: BlockAccessIndex, value: UInt256]
  FNonce = tuple[address: Address, index: BlockAccessIndex, value: AccountNonce]
  FCode = tuple[address: Address, index: BlockAccessIndex, value: seq[byte]]

func addrCmp(x, y: Address): int =
  let
    xd = x.data()
    yd = y.data()
  for i in 0 ..< xd.len:
    if xd[i] != yd[i]:
      return (if xd[i] < yd[i]: -1 else: 1)
  0

func fStorageCmp(x, y: FStorage): int =
  result = addrCmp(x.address, y.address)
  if result == 0:
    result = cmp(x.slot, y.slot)
  if result == 0:
    result = cmp(x.index, y.index)

func fReadCmp(x, y: FRead): int =
  result = addrCmp(x.address, y.address)
  if result == 0:
    result = cmp(x.slot, y.slot)

func fIndexedCmp[T](
    x, y: tuple[address: Address, index: BlockAccessIndex, value: T]
): int =
  result = addrCmp(x.address, y.address)
  if result == 0:
    result = cmp(x.index, y.index)

func buildBlockAccessList*(builder: var BlockAccessListBuilder): BlockAccessListRef =
  # This function is not thread safe and should only be called once all threads
  # have finished writing to the builder.
  let blockAccessList: BlockAccessListRef = new BlockAccessList

  var totS, totR, totB, totN, totC, totT = 0
  for idx in 0 ..< builder.perIndex.len:
    let d = addr builder.perIndex[idx]
    totS += d[].storageChanges.len
    totR += d[].storageReads.len
    totB += d[].balanceChanges.len
    totN += d[].nonceChanges.len
    totC += d[].codeChanges.len
    totT += d[].touchedAccounts.len

  var
    sChanges = newSeqOfCap[FStorage](totS)
    sReads = newSeqOfCap[FRead](totR)
    bChanges = newSeqOfCap[FBalance](totB)
    nChanges = newSeqOfCap[FNonce](totN)
    cChanges = newSeqOfCap[FCode](totC)
    touched = newSeqOfCap[Address](totT)

  for idx in 0 ..< builder.perIndex.len:
    let
      balIndex = BlockAccessIndex(idx)
      d = addr builder.perIndex[idx]
    for a in d[].touchedAccounts.items():
      touched.add(a)
    for w in d[].storageChanges.items():
      sChanges.add((w.address, w.slot, balIndex, w.value))
    for r in d[].storageReads.items():
      sReads.add((r.address, r.slot))
    for b in d[].balanceChanges.items():
      bChanges.add((b.address, balIndex, b.balance))
    for nc in d[].nonceChanges.items():
      nChanges.add((nc.address, balIndex, nc.nonce))
    for cc in d[].codeChanges.items():
      cChanges.add((cc.address, balIndex, cc.code.data()))

  sort(sChanges, fStorageCmp)
  sort(sReads, fReadCmp)
  sort(bChanges, fIndexedCmp[UInt256])
  sort(nChanges, fIndexedCmp[AccountNonce])
  sort(cChanges, fIndexedCmp[seq[byte]])
  sort(touched, addrCmp)

  var si, ri, bi, ni, ci, ti = 0

  while true:
    var nextAddr = Opt.none(Address)
    template consider(head: untyped) =
      let h = head
      if h.isSome and (nextAddr.isNone or addrCmp(h.get, nextAddr.get) < 0):
        nextAddr = h
    consider(
      if si < sChanges.len: Opt.some(sChanges[si].address) else: Opt.none(Address))
    consider(if ri < sReads.len: Opt.some(sReads[ri].address) else: Opt.none(Address))
    consider(
      if bi < bChanges.len: Opt.some(bChanges[bi].address) else: Opt.none(Address))
    consider(
      if ni < nChanges.len: Opt.some(nChanges[ni].address) else: Opt.none(Address))
    consider(
      if ci < cChanges.len: Opt.some(cChanges[ci].address) else: Opt.none(Address))
    consider(if ti < touched.len: Opt.some(touched[ti]) else: Opt.none(Address))
    if nextAddr.isNone:
      break
    let address = nextAddr.get

    var storageChanges: seq[SlotChanges]
    while si < sChanges.len and sChanges[si].address == address:
      let slot = sChanges[si].slot
      var slotChanges: seq[StorageChange]
      while si < sChanges.len and sChanges[si].address == address and
          sChanges[si].slot == slot:
        let index = sChanges[si].index
        var value = sChanges[si].value
        inc si
        while si < sChanges.len and sChanges[si].address == address and
            sChanges[si].slot == slot and sChanges[si].index == index:
          value = sChanges[si].value
          inc si
        slotChanges.add((index, StorageValue(value)))
      storageChanges.add((StorageKey(slot), slotChanges))

    var storageReads: seq[StorageKey]
    var sj = 0
    while ri < sReads.len and sReads[ri].address == address:
      let slot = sReads[ri].slot
      inc ri
      while ri < sReads.len and sReads[ri].address == address and sReads[ri].slot == slot:
        inc ri
      while sj < storageChanges.len and storageChanges[sj].slot < slot:
        inc sj
      if sj >= storageChanges.len or storageChanges[sj].slot != slot:
        storageReads.add(StorageKey(slot))

    var balanceChanges: seq[BalanceChange]
    while bi < bChanges.len and bChanges[bi].address == address:
      let index = bChanges[bi].index
      var value = bChanges[bi].value
      inc bi
      while bi < bChanges.len and bChanges[bi].address == address and
          bChanges[bi].index == index:
        value = bChanges[bi].value
        inc bi
      balanceChanges.add((index, Balance(value)))

    var nonceChanges: seq[NonceChange]
    while ni < nChanges.len and nChanges[ni].address == address:
      let index = nChanges[ni].index
      var value = nChanges[ni].value
      inc ni
      while ni < nChanges.len and nChanges[ni].address == address and
          nChanges[ni].index == index:
        value = nChanges[ni].value
        inc ni
      nonceChanges.add((index, Nonce(value)))

    var codeChanges: seq[CodeChange]
    while ci < cChanges.len and cChanges[ci].address == address:
      let index = cChanges[ci].index
      var value = cChanges[ci].value
      inc ci
      while ci < cChanges.len and cChanges[ci].address == address and
          cChanges[ci].index == index:
        value = cChanges[ci].value
        inc ci
      codeChanges.add((index, Bytecode(value)))

    while ti < touched.len and touched[ti] == address:
      inc ti

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

  blockAccessList
