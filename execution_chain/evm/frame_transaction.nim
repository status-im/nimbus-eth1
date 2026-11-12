# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/[tables, typetraits, algorithm],
  stint,
  ./evm_errors,
  ../db/ledger,
  eth/common/[addresses, base, hashes]

from eth/common/receipts import Log, FrameReceipt, Topic

export FrameReceipt

const
  CHANGE_FLAG_NONCE   = 0x01
  CHANGE_FLAG_BALANCE = 0x02
  CHANGE_FLAG_STORAGE = 0x04
  CHANGE_FLAG_CODE    = 0x08

type
  AccountSlot* = object
    address*: Address
    slot*   : UInt256

  FrameSnapshotRef* = ref object
    currentFrameIndex*: int
    receipts*         : seq[FrameReceipt]
    payer*            : Opt[Address]
    senderApproved*   : bool
    stateGasLeft*     : GasInt
    ocOwners*         : Table[AccountSlot, int]

  FrameContext* = object
    legacyNonce*     : uint64
    signatureHash*   : Hash32
    resolvedSigners* : seq[Address]
    standardGasLimit*: GasInt
    maxCost*         : UInt256
    snapshot*        : FrameSnapshotRef
    txDiff*          : TransactionDiffRef
    error*           : string

  BalanceChange* = object
    # Entry of the `balances_changed` table: an address whose balance
    # differs from its transaction prestate value.

    address*: Address
    # The account whose balance changed.

    before*: UInt256
    # The balance at the start of the transaction.

    after*: UInt256
    # The balance as of the reading instruction.

  SlotChange* = object
    # Entry of the `slots_changed` table: a storage slot whose value
    # differs from its transaction prestate value.

    address*: Address
    # The account whose storage changed.

    key*: UInt256
    # The storage slot key.

    before*: UInt256
    # The slot value at the start of the transaction.

    after*: UInt256
    # The slot value as of the reading instruction.

  DeployedContract* = object
    # Entry of the `contracts_deployed` table: an address whose code hash
    # changed from the empty-code hash to the hash of code that is not an
    # [EIP-7702] delegation designator.
    # [EIP-7702]: https://eips.ethereum.org/EIPS/eip-7702

    address*: Address
    # The address of the newly deployed contract.

    codeHash*: Hash32
    # The code hash as of the reading instruction.

  TransactionDiffRef* = ref object
    # The transaction's state diff, in the canonical enumeration order:
    # balance and slot changes ascending by address, slots of one address
    # ascending by key, and events in emission order.

    balances*: seq[BalanceChange]
    # The `balances_changed` table.

    slots*: seq[SlotChange]
    # The `slots_changed` table.

    deployed*: seq[DeployedContract]
    # The `contracts_deployed` table.

    events*: seq[Log]
    # The `events_count` table: every event the transaction's completed
    # frames emitted, in their global log order.

  AccountList = OrderedTable[Address, AccountRef]

func hash*(v: AccountSlot): Hash {.inline.} =
  var h: Hash = 0
  h = h !& hash(v.address)
  h = h !& hash(v.slot)
  result = !$h

proc fillAndSortList(ledger: LedgerRef): AccountList =
  var list: AccountList
  for address, acc in ledger.dirtyAccounts():
    if address notin list:
      list[address] = acc
  list.sort(proc(a, b: (Address, AccountRef)): int =
    cmpMem(a[0].data[0].addr, b[0].data[0].addr, sizeof(Address))
  )
  move(list)

func slotCmp(x, y: UInt256): int =
  # Most significant limb first with an early exit, unlike stint's `cmp` which
  # always runs a full borrow chain.
  for i in countdown(x.limbs.len - 1, 0):
    if x.limbs[i] != y.limbs[i]:
      return (if x.limbs[i] < y.limbs[i]: -1 else: 1)
  0

proc fillAndSortSlots(acc: AccountRef): seq[UInt256] =
  var list = acc.slots()
  list.sort(slotCmp)
  move(list)

proc transactionDiff*(ledger: ReadOnlyLedger, snapshot: FrameSnapshotRef): TransactionDiffRef =
  let
    txd = TransactionDiffRef()
    accounts = fillAndSortList(distinctBase ledger)

  for address, acc in accounts:
    if acc.balanceChanged:
      txd.balances.add BalanceChange(
        address: address,
        before : acc.originalStatement().balance,
        after : acc.statement().balance,
      )
    if acc.codeChangedToSomething:
      txd.deployed.add DeployedContract(
        address : address,
        codeHash: acc.statement().codeHash,
      )
    if acc.storageChanged:
      let slots = fillAndSortSlots(acc)
      for key in slots:
        let
          before = acc.originalStorage(key)
          after = acc.storage(key)

        if after == before:
          continue

        txd.slots.add SlotChange(
          address: address,
          key    : key,
          before : before,
          after  : after,
        )

  for rec in snapshot.receipts:
    txd.events.add rec.logs

  txd

proc accountChangeFlags*(ledger: ReadOnlyLedger, txd: TransactionDiffRef, address: Address): UInt256 =
  ## Return the `account_change_flags` bitmask of an account: one bit per
  ## field of the account tuple, following its `(nonce, balance,
  ## storage_root, code_hash)` order, set when the field's net value
  ## differs from the transaction prestate.
  ##
  ## An account with neither an account write nor a changed slot has no
  ## set bit, and no live state is read to establish that.

  let acc = ledger.getDirtyAccount(address)
  if acc.isNil:
    return 0.u256

  var flags = 0'u
  if acc.nonceChanged:
    flags = flags or CHANGE_FLAG_NONCE
  if acc.balanceChanged:
    flags = flags or CHANGE_FLAG_BALANCE
  if acc.codeChanged:
    flags = flags or CHANGE_FLAG_CODE
  if acc.storageChanged:
    for change in txd.slots:
      if change.address == address:
        flags = flags or CHANGE_FLAG_STORAGE
        break

  flags.u256

func tableEntry*[T](table: openArray[T], index: int): EvmResultVoid =
  ## Return the entry of a diff table at an index, or exceptionally halt
  ## when the index is out of bounds.
  if index >= table.len:
    return err(opErr(EvmInvalidParam))
  ok()

func balanceAddress*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.balances, index)
  ok(UInt256.fromBytesBE(diff.balances[index].address.data))

func slotAddress*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.slots, index)
  ok(UInt256.fromBytesBE(diff.slots[index].address.data))

func deployedAddress*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.deployed, index)
  ok(UInt256.fromBytesBE(diff.deployed[index].address.data))

func deployedCodeHash*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.deployed, index)
  ok(UInt256.fromBytesBE(diff.deployed[index].codeHash.data))

func eventTopicsCount*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.events, index)
  ok(diff.events[index].topics.len.u256)

func eventAddress*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.events, index)
  ok(UInt256.fromBytesBE(diff.events[index].address.data))

func eventDataLen*(diff: TransactionDiffRef, index: int): EvmResult[UInt256] =
  ? tableEntry(diff.events, index)
  ok(diff.events[index].data.len.u256)

func eventTopic*(diff: TransactionDiffRef, index: int, position: int): EvmResult[UInt256] =
  # Return one topic of an event, or exceptionally halt when the event
  # carries no topic at that position.
  ? tableEntry(diff.events, index)
  if position >= diff.events[index].topics.len:
    return err(opErr(EvmInvalidParam))
  ok(UInt256.fromBytesBE(diff.events[index].topics[position].data))

func slotIndicesLen*(diff: TransactionDiffRef, address: Address): UInt256 =
  var count = 0
  for z in diff.slots:
    if z.address == address:
      inc count
  count.u256

func eventIndicesLen*(diff: TransactionDiffRef, address: Address): UInt256 =
  var count = 0
  for z in diff.events:
    if z.address == address:
      inc count
  count.u256

func slotIndicesOf*(diff: TransactionDiffRef, address: Address, index: int): EvmResult[UInt256] =
  var count = 0
  for i, z in diff.slots:
    if z.address == address:
      if count == index:
        return ok(i.u256)
      inc count
  err(opErr(EvmInvalidParam))

func eventIndicesOf*(diff: TransactionDiffRef, address: Address, index: int): EvmResult[UInt256] =
  var count = 0
  for i, z in diff.events:
    if z.address == address:
      if count == index:
        return ok(i.u256)
      inc count
  err(opErr(EvmInvalidParam))

func eventIndicesWithTopicLen*(diff: TransactionDiffRef, topic: Topic): UInt256 =
  ## Return the `events_count` indices of the events carrying `topic` in
  ## any indexed position (`topic1` to `topic3`), the per-topic view
  ## `TXDIFF` exposes, in emission order. The signature topic `topic0`
  ## identifies the event type and is excluded.
  var count = 0
  for event in diff.events:
    for i in 1..<event.topics.len:
      if event.topics[i] == topic:
        inc count
        break
  count.u256

func eventIndicesWithTopic*(diff: TransactionDiffRef, topic: Topic, index: int): EvmResult[UInt256] =
  ## Return the `events_count` indices of the events carrying `topic` in
  ## any indexed position (`topic1` to `topic3`), the per-topic view
  ## `TXDIFF` exposes, in emission order. The signature topic `topic0`
  ## identifies the event type and is excluded.
  var count = 0
  for w, event in diff.events:
    for i in 1..<event.topics.len:
      if event.topics[i] == topic:
        if count == index:
          return ok(w.u256)
        inc count
        break

  err(opErr(EvmInvalidParam))
