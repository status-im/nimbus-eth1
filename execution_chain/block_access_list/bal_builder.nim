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
# All collections use the non-GC SharedSeq/SmallSeq types (rather than the
# standard library Seq) so that the builder can be used safely with the refc
# memory manager across threads. Each per-index collection keeps inline room
# for what a plain transfer or a token transfer records (a few touched accounts
# with their balance changes, the sender's nonce, a couple of storage writes and
# a read, or one code change) so that such a transaction records its changes
# without any heap allocation. The capacities were tuned on the scenarios in
# tests/test_block_access_list/bench_bal_builder.nim: larger ones make heavier
# transactions pay for unused inline space in their cache footprint.
#
# The idea here is that each thread writes to a separate index in the internal
# `perIndex` array so that concurrent lock free writes are possible during
# parallel execution.

{.push raises: [], gcsafe.}

import
  std/[math],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  ../concurrency/shared_types

export block_access_lists

type
  # Position of an account in its index's `accounts` list. Entries refer to
  # accounts this way, which keeps them small and lets the writer thread do
  # the address matching, so that the single-threaded build only has to map
  # each index's distinct addresses rather than every entry.
  LocalId = uint32

  AccessedSlot* = tuple[address: Address, slot: UInt256]

  StorageWrite = tuple[slot: UInt256, value: UInt256, account: LocalId]
  StorageReadEntry = tuple[slot: UInt256, account: LocalId]
  BalanceWrite = tuple[balance: UInt256, account: LocalId]
  NonceWrite = tuple[nonce: AccountNonce, account: LocalId]
  CodeWrite = tuple[code: SharedBytes, account: LocalId]

const
  inlineAccounts = 4
  inlineStorageChanges = 2
  inlineStorageReads = 1
  inlineBalanceChanges = 4
  inlineNonceChanges = 1
  inlineCodeChanges = 1
  linearAccountLimit = 8
    ## Up to this many accounts per index are matched by a linear scan; beyond
    ## it an open addressing index over the list is maintained.

type
  BalIndexData = object
    accounts: SmallSeq[inlineAccounts, Address]
      ## Every address referenced at this index in first-seen order.
    accountIndex: SharedSeq[uint32]
      ## Open addressing index into `accounts` holding position + 1 (0 is
      ## empty), only built once the list outgrows the linear scan.
    storageChanges: SmallSeq[inlineStorageChanges, StorageWrite]
    storageReads: SmallSeq[inlineStorageReads, StorageReadEntry]
    balanceChanges: SmallSeq[inlineBalanceChanges, BalanceWrite]
    nonceChanges: SmallSeq[inlineNonceChanges, NonceWrite]
    codeChanges: SmallSeq[inlineCodeChanges, CodeWrite]

func addrHash(address: Address): uint64 =
  # Addresses are hash outputs so a cheap fold of their bytes spreads well, and
  # every byte takes part so that vanity addresses sharing a prefix still spread.
  var
    w0, w1: uint64
    w2: uint32
  copyMem(addr w0, unsafeAddr address.data[0], sizeof(w0))
  copyMem(addr w1, unsafeAddr address.data[8], sizeof(w1))
  copyMem(addr w2, unsafeAddr address.data[16], sizeof(w2))
  let h =
    w0 * 0x9E3779B97F4A7C15'u64 + w1 * 0xC2B2AE3D27D4EB4F'u64 +
    uint64(w2) * 0x165667B19E3779F9'u64
  h xor (h shr 29)

proc rebuildAccountIndex(indexData: var BalIndexData, size: int) =
  indexData.accountIndex.setLen(0)
  indexData.accountIndex.setLen(size, zeroed = true, exact = true)
  let mask = uint64(size - 1)
  for i in 0 ..< indexData.accounts.len:
    var b = int(addrHash(indexData.accounts[i]) and mask)
    while indexData.accountIndex[b] != 0:
      b = int((uint64(b) + 1) and mask)
    indexData.accountIndex[b] = uint32(i + 1)

proc localId(indexData: var BalIndexData, address: Address): LocalId =
  ## Position of `address` in the index's account list, appending it if new.
  let n = indexData.accounts.len
  if n <= linearAccountLimit:
    for i in 0 ..< n:
      if indexData.accounts[i] == address:
        return LocalId(i)
    indexData.accounts.add(address)
    if n + 1 > linearAccountLimit:
      indexData.rebuildAccountIndex(4 * linearAccountLimit)
    return LocalId(n)

  let mask = uint64(indexData.accountIndex.len - 1)
  var b = int(addrHash(address) and mask)
  while true:
    let e = indexData.accountIndex[b]
    if e == 0:
      indexData.accounts.add(address)
      if (n + 1) * 2 > indexData.accountIndex.len:
        indexData.rebuildAccountIndex(indexData.accountIndex.len * 2)
      else:
        indexData.accountIndex[b] = uint32(n + 1)
      return LocalId(n)
    if indexData.accounts[int(e) - 1] == address:
      return LocalId(e - 1)
    b = int((uint64(b) + 1) and mask)

type
  BlockAccessListBuilder* = object
    perIndex: SharedSeq[BalIndexData]

proc dispose(indexData: var BalIndexData) =
  indexData.accounts.dispose()
  indexData.accountIndex.dispose()
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
  # Is a no-op because the perIndex array is zero initialized
  # and valid with default values.
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

proc clear*(builder: var BlockAccessListBuilder) =
  for d in builder.perIndex.mitems():
    d.accounts.setLen(0)
    d.accountIndex.setLen(0)
    d.storageChanges.setLen(0)
    d.storageReads.setLen(0)
    d.balanceChanges.setLen(0)
    d.nonceChanges.setLen(0)
    for code in d.codeChanges.mitems():
      code.code.dispose()
    d.codeChanges.setLen(0)

proc addTouchedAccount*(
    builder: var BlockAccessListBuilder, blockAccessIndex: int, address: Address
) =
  assert blockAccessIndex < builder.perIndex.len
  discard builder.perIndex[blockAccessIndex].localId(address)

proc addTouchedAccounts*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    addresses: openArray[Address],
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  for address in addresses:
    discard d[].localId(address)

proc addStorageReads*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    reads: openArray[AccessedSlot],
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  for r in reads:
    let account = d[].localId(r.address)
    d[].storageReads.add((r.slot, account))

proc addStorageWrite*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  let account = d[].localId(address)
  d[].storageChanges.add((slot, newValue, account))

proc addStorageRead*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  let account = d[].localId(address)
  d[].storageReads.add((slot, account))

proc addBalanceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    postBalance: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  let account = d[].localId(address)
  d[].balanceChanges.add((postBalance, account))

proc addNonceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newNonce: AccountNonce,
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  let account = d[].localId(address)
  d[].nonceChanges.add((newNonce, account))

proc addCodeChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newCode: openArray[byte],
) =
  assert blockAccessIndex < builder.perIndex.len
  let d = addr builder.perIndex[blockAccessIndex]
  let account = d[].localId(address)
  d[].codeChanges.add((SharedBytes.init(newCode), account))

type
  # Flattened per-index writes, tagged with a dense account id instead of the
  # address so that grouping by account is a counting sort rather than a
  # comparison sort over 20-byte keys.
  FlatStorageChange =
    tuple[acct: int32, index: BlockAccessIndex, slot: UInt256, value: UInt256]
  FlatStorageRead = tuple[acct: int32, slot: UInt256]
  FlatBalanceChange = tuple[acct: int32, index: BlockAccessIndex, value: UInt256]
  FlatNonceChange = tuple[acct: int32, index: BlockAccessIndex, value: AccountNonce]
  # The code stays in the builder's storage, which is stable for the duration
  # of the build, and is copied exactly once into the output.
  FlatCodeChange = tuple[acct: int32, index: BlockAccessIndex, value: ptr SharedBytes]

  # Open addressing table from address to dense id, with the addresses kept in
  # id order.
  AccountIds = object
    buckets: seq[int32] ## power-of-two size; 0 is empty, otherwise id + 1
    addresses: seq[Address] ## address of each id, in first-seen order

  AccountOrder = tuple[address: Address, id: int32]

template dataPtr[T](s: seq[T]): ptr UncheckedArray[T] =
  ## Unchecked view of a seq's elements for the hot loops below, which index
  ## within bounds they establish themselves; the seq must not change length
  ## while the view is in use.
  if s.len > 0:
    cast[ptr UncheckedArray[T]](unsafeAddr s[0])
  else:
    nil

func init(T: type AccountIds, expected: int): AccountIds =
  let size = nextPowerOfTwo(max(expected * 2, 64))
  AccountIds(buckets: newSeq[int32](size), addresses: newSeqOfCap[Address](expected))

func insert(buckets: var seq[int32], address: Address, id: int32) =
  let
    mask = uint64(buckets.len - 1)
    bk = buckets.dataPtr()
  var i = int(addrHash(address) and mask)
  while bk[i] != 0:
    i = int((uint64(i) + 1) and mask)
  bk[i] = id + 1

func idOf(accounts: var AccountIds, address: Address): int32 =
  if accounts.addresses.len * 2 >= accounts.buckets.len:
    # Keep the load factor at or below one half.
    var grown = newSeq[int32](accounts.buckets.len * 2)
    for id in 0 ..< accounts.addresses.len:
      grown.insert(accounts.addresses[id], int32(id))
    accounts.buckets = grown

  let
    mask = uint64(accounts.buckets.len - 1)
    bk = accounts.buckets.dataPtr()
    ad = accounts.addresses.dataPtr()
  var i = int(addrHash(address) and mask)
  while true:
    let b = bk[i]
    if b == 0:
      result = int32(accounts.addresses.len)
      accounts.addresses.add(address)
      bk[i] = result + 1
      return
    if ad[b - 1] == address:
      return b - 1
    i = int((uint64(i) + 1) and mask)

func sortByAddress(order: var seq[AccountOrder], bits: static int) =
  ## Stable LSD radix sort by address bytes, which is the lexicographic (big
  ## endian numeric) order EIP-7928 requires, in `bits`-wide digits.
  const
    numBuckets = 1 shl bits
    bytesPerDigit = bits div 8
    numDigits = sizeof(Address) div bytesPerDigit
  let n = order.len
  var
    tmp = newSeq[AccountOrder](n)
    counts = newSeq[int32](numBuckets)
    src = order.dataPtr()
    dst = tmp.dataPtr()
  let cp = counts.dataPtr()

  template digitOf(e: AccountOrder, d: int): int =
    when bits == 8:
      int(e.address.data[d])
    else:
      (int(e.address.data[2 * d]) shl 8) or int(e.address.data[2 * d + 1])

  for d in countdown(numDigits - 1, 0):
    zeroMem(cp, numBuckets * sizeof(int32))
    for i in 0 ..< n:
      inc cp[digitOf(src[i], d)]
    if int(cp[digitOf(src[0], d)]) == n:
      continue # every address shares this digit
    var total = 0'i32
    for b in 0 ..< numBuckets:
      let c = cp[b]
      cp[b] = total
      total += c
    for i in 0 ..< n:
      let b = digitOf(src[i], d)
      dst[cp[b]] = src[i]
      inc cp[b]
    swap(src, dst)

  if src != order.dataPtr():
    swap(order, tmp)

func sortByAddress(order: var seq[AccountOrder]) =
  if order.len <= 1:
    return
  if order.len >= 16384:
    order.sortByAddress(16)
  else:
    order.sortByAddress(8)

func slotLess(x, y: UInt256): bool {.inline.} =
  # Most significant limb first with an early exit, unlike stint's `<` which
  # always runs a full borrow chain.
  for i in countdown(x.limbs.len - 1, 0):
    if x.limbs[i] != y.limbs[i]:
      return x.limbs[i] < y.limbs[i]
  false

func groupByAccount[T](
    entries: seq[T], numAccounts: int, grouped: var seq[T], offsets: var seq[int32]
) =
  ## Stable counting sort of `entries` by account id into `grouped`. The entries
  ## of account `i` end up in `grouped[offsets[i] ..< offsets[i + 1]]`, keeping
  ## their relative (block access index) order.
  let n = entries.len
  offsets = newSeq[int32](numAccounts + 1)
  grouped = newSeq[T](n)
  if n == 0:
    return
  let
    src = entries.dataPtr()
    off = offsets.dataPtr()
  for i in 0 ..< n:
    inc off[src[i].acct + 1]
  for i in 1 .. numAccounts:
    off[i] += off[i - 1]

  var cursor = offsets
  let
    cur = cursor.dataPtr()
    dst = grouped.dataPtr()
  for i in 0 ..< n:
    let acct = src[i].acct
    dst[cur[acct]] = src[i]
    inc cur[acct]

func sortBySlot[T](
    entries: ptr UncheckedArray[T], lo, hi: int, tmp: ptr UncheckedArray[T]
) =
  ## Stable merge sort of `entries[lo ..< hi]` by slot with the comparison
  ## inlined. The range is already in block access index order so the result is
  ## ordered by (slot, index). Small ranges, which is most accounts, are
  ## insertion sorted. `tmp` must hold at least half the range.
  const insertionLimit = 24
  if hi - lo <= insertionLimit:
    for i in lo + 1 ..< hi:
      var j = i
      while j > lo and slotLess(entries[j].slot, entries[j - 1].slot):
        swap(entries[j - 1], entries[j])
        dec j
    return

  let mid = (lo + hi) div 2
  entries.sortBySlot(lo, mid, tmp)
  entries.sortBySlot(mid, hi, tmp)
  if not slotLess(entries[mid].slot, entries[mid - 1].slot):
    return # the halves are already in order

  let leftLen = mid - lo
  copyMem(addr tmp[0], addr entries[lo], leftLen * sizeof(T))
  var
    i = 0
    j = mid
    k = lo
  while i < leftLen and j < hi:
    # Take from the right only when strictly less, which keeps the sort stable.
    if slotLess(entries[j].slot, tmp[i].slot):
      entries[k] = entries[j]
      inc j
    else:
      entries[k] = tmp[i]
      inc i
    inc k
  while i < leftLen:
    entries[k] = tmp[i]
    inc i
    inc k

func countDistinctIndices[T](src: ptr UncheckedArray[T], lo, hi: int): int =
  ## Number of distinct block access indices in `src[lo ..< hi]`, which is in
  ## index order.
  var i = lo
  while i < hi:
    let index = src[i].index
    inc i
    while i < hi and src[i].index == index:
      inc i
    inc result

func seqOfCap[T](n: int): seq[T] =
  ## Like newSeqOfCap but leaves an empty seq unallocated, which most of the
  ## per-account output seqs are.
  if n > 0:
    newSeqOfCap[T](n)
  else:
    default(seq[T])

template collapseByIndex[T](
    src: ptr UncheckedArray[T], lo, hi: int, emit: untyped
) =
  ## `src[lo ..< hi]` is in block access index order. Run `emit` once per distinct
  ## `index` with the last `value` seen for that index injected, reproducing
  ## last-write-wins for the pre/post-execution indices, which are the only ones
  ## that can repeat.
  var cursor = lo
  while cursor < hi:
    let index {.inject.} = src[cursor].index
    var value {.inject.} = src[cursor].value
    inc cursor
    while cursor < hi and src[cursor].index == index:
      value = src[cursor].value
      inc cursor
    emit

func buildBlockAccessList*(builder: var BlockAccessListBuilder): BlockAccessListRef =
  # Not thread safe: only call once all threads have finished writing.
  #
  # Rebuild is done in three phases:
  #   1. assign a dense id to every address and flatten every per-index write
  #      into flat, id-tagged seqs (which are therefore in index order),
  #   2. group each seq by account with a stable counting sort and sort each
  #      account's storage entries by slot,
  #   3. emit one AccountChanges per account in address order.
  let blockAccessList = new BlockAccessList

  # Phase 1: reserve exact capacity, then flatten.
  var totT, totS, totR, totB, totN, totC = 0
  for idx in 0 ..< builder.perIndex.len:
    let d = addr builder.perIndex[idx]
    totT += d[].accounts.len
    totS += d[].storageChanges.len
    totR += d[].storageReads.len
    totB += d[].balanceChanges.len
    totN += d[].nonceChanges.len
    totC += d[].codeChanges.len

  var
    # The per-index account lists bound the distinct addresses.
    accounts = AccountIds.init(totT)
    globalIds: seq[int32]
    sFlat = newSeq[FlatStorageChange](totS)
    rFlat = newSeq[FlatStorageRead](totR)
    bFlat = newSeq[FlatBalanceChange](totB)
    nFlat = newSeq[FlatNonceChange](totN)
    cFlat = newSeq[FlatCodeChange](totC)
    si, ri, bi, ni, ci = 0
  let
    sp = sFlat.dataPtr()
    rp = rFlat.dataPtr()
    bp = bFlat.dataPtr()
    np = nFlat.dataPtr()
    cp = cFlat.dataPtr()

  for idx in 0 ..< builder.perIndex.len:
    let
      balIndex = BlockAccessIndex(idx)
      d = addr builder.perIndex[idx]
    globalIds.setLen(d[].accounts.len)
    let gid = globalIds.dataPtr()
    for j in 0 ..< d[].accounts.len:
      gid[j] = accounts.idOf(d[].accounts[j])
    for w in d[].storageChanges.items():
      sp[si] = (gid[w.account], balIndex, w.slot, w.value)
      inc si
    for r in d[].storageReads.items():
      rp[ri] = (gid[r.account], r.slot)
      inc ri
    for b in d[].balanceChanges.items():
      bp[bi] = (gid[b.account], balIndex, b.balance)
      inc bi
    for nc in d[].nonceChanges.items():
      np[ni] = (gid[nc.account], balIndex, nc.nonce)
      inc ni
    for cc in d[].codeChanges.items():
      cp[ci] = (gid[cc.account], balIndex, unsafeAddr cc.code)
      inc ci

  let numAccounts = accounts.addresses.len

  # Phase 2: group by account, then order each account's storage entries by
  # slot. Balance, nonce and code entries need no sorting: grouping is stable
  # and the flat seqs are in index order.
  var
    sChanges: seq[FlatStorageChange]
    sReads: seq[FlatStorageRead]
    bChanges: seq[FlatBalanceChange]
    nChanges: seq[FlatNonceChange]
    cChanges: seq[FlatCodeChange]
    sOff, rOff, bOff, nOff, cOff: seq[int32]
  groupByAccount(sFlat, numAccounts, sChanges, sOff)
  groupByAccount(rFlat, numAccounts, sReads, rOff)
  groupByAccount(bFlat, numAccounts, bChanges, bOff)
  groupByAccount(nFlat, numAccounts, nChanges, nOff)
  groupByAccount(cFlat, numAccounts, cChanges, cOff)

  var maxS, maxR = 0
  for id in 0 ..< numAccounts:
    maxS = max(maxS, int(sOff[id + 1] - sOff[id]))
    maxR = max(maxR, int(rOff[id + 1] - rOff[id]))
  var
    sTmp = newSeq[FlatStorageChange](maxS div 2 + 1)
    rTmp = newSeq[FlatStorageRead](maxR div 2 + 1)
  let
    sg = sChanges.dataPtr()
    rg = sReads.dataPtr()
    bg = bChanges.dataPtr()
    ng = nChanges.dataPtr()
    cg = cChanges.dataPtr()
    sOffP = sOff.dataPtr()
    rOffP = rOff.dataPtr()
    bOffP = bOff.dataPtr()
    nOffP = nOff.dataPtr()
    cOffP = cOff.dataPtr()
    sTmpP = sTmp.dataPtr()
    rTmpP = rTmp.dataPtr()
  for id in 0 ..< numAccounts:
    sg.sortBySlot(int(sOffP[id]), int(sOffP[id + 1]), sTmpP)
    rg.sortBySlot(int(rOffP[id]), int(rOffP[id + 1]), rTmpP)

  var order = newSeqOfCap[AccountOrder](numAccounts)
  for id in 0 ..< numAccounts:
    order.add((accounts.addresses[id], int32(id)))
  order.sortByAddress()

  # Phase 3: emit per account. Every output seq is written in place through
  # the final BlockAccessList rather than built in a local and moved, since a
  # seq move under refc is a deep copy.
  blockAccessList[].setLen(numAccounts)
  for k, (acc, id) in order:
    template acct(): untyped =
      blockAccessList[][k]

    acct.address = acc

    # storageChanges: group by slot, then collapse each slot's writes by index.
    let
      sLo = int(sOffP[id])
      sHi = int(sOffP[id + 1])
    var
      numSlots = 0
      si = sLo
    while si < sHi:
      let slot = sg[si].slot
      inc si
      while si < sHi and sg[si].slot == slot:
        inc si
      inc numSlots

    if numSlots > 0:
      acct.storageChanges.setLen(numSlots)
    let outSlots = acct.storageChanges.dataPtr()
    var slotIdx = 0
    si = sLo
    while si < sHi:
      let slot = sg[si].slot
      var slotHi = si
      while slotHi < sHi and sg[slotHi].slot == slot:
        inc slotHi
      template slotChanges(): untyped =
        acct.storageChanges[slotIdx]

      slotChanges.slot = StorageKey(slot)
      slotChanges.changes = seqOfCap[StorageChange](sg.countDistinctIndices(si, slotHi))
      collapseByIndex(sg, si, slotHi):
        slotChanges.changes.add((index, StorageValue(value)))
      inc slotIdx
      si = slotHi

    # storageReads: unique read slots that were not also written. Both ranges
    # are slot-sorted, so a single forward cursor (`written`) decides membership.
    let
      rLo = int(rOffP[id])
      rHi = int(rOffP[id + 1])
    var
      numReads = 0
      written = 0
      ri = rLo
    while ri < rHi:
      let slot = rg[ri].slot
      inc ri
      while ri < rHi and rg[ri].slot == slot:
        inc ri
      while written < numSlots and outSlots[written].slot < slot:
        inc written
      if written >= numSlots or outSlots[written].slot != slot:
        inc numReads

    acct.storageReads = seqOfCap[StorageKey](numReads)
    written = 0
    ri = rLo
    while ri < rHi:
      let slot = rg[ri].slot
      inc ri
      while ri < rHi and rg[ri].slot == slot:
        inc ri
      while written < numSlots and outSlots[written].slot < slot:
        inc written
      if written >= numSlots or outSlots[written].slot != slot:
        acct.storageReads.add(StorageKey(slot))

    let
      bLo = int(bOffP[id])
      bHi = int(bOffP[id + 1])
    acct.balanceChanges = seqOfCap[BalanceChange](bg.countDistinctIndices(bLo, bHi))
    collapseByIndex(bg, bLo, bHi):
      acct.balanceChanges.add((index, Balance(value)))

    let
      nLo = int(nOffP[id])
      nHi = int(nOffP[id + 1])
    acct.nonceChanges = seqOfCap[NonceChange](ng.countDistinctIndices(nLo, nHi))
    collapseByIndex(ng, nLo, nHi):
      acct.nonceChanges.add((index, Nonce(value)))

    let
      cLo = int(cOffP[id])
      cHi = int(cOffP[id + 1])
    let numCodes = cg.countDistinctIndices(cLo, cHi)
    if numCodes > 0:
      acct.codeChanges.setLen(numCodes)
      var ci = 0
      collapseByIndex(cg, cLo, cHi):
        acct.codeChanges[ci].blockAccessIndex = index
        acct.codeChanges[ci].newCode = value[].data()
        inc ci

  blockAccessList
