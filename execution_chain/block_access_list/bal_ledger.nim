# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets, importutils],
  ./block_access_list_builder

import
  ../db/ledger {.all.}

type
  BalLedgerRef* = ref object
    blockAccessIndex: int
      ## The current block access index (0 for pre-execution,
      ## 1..n for transactions, n+1 for post-execution).

    builder: BlockAccessListBuilderRef
      ## The builder instance that accumulates all tracked changes.

    blockAccessList: Opt[BlockAccessListRef]
      ## Created by the builder and cached for reuse.

proc collectBAL(bal: BalLedgerRef, ledger: LedgerRef, trackTouchedAddress: bool) =
  privateAccess(LedgerRef)
  privateAccess(AccountRef)
  privateAccess(LedgerSpRef)
  privateAccess(OriginalValueRef)

  let
    currentIndex = bal.blockAccessIndex
    builder = bal.builder

  for address, acc in ledger.savePoint.dirty:
    case acc.persistMode():
    of Update:
      if CodeChanged in acc.flags:
        if acc.statement.codeHash != acc.original.statement.codeHash:
          builder.addCodeChange(address, currentIndex, acc.code.bytes)

      if acc.statement.balance != acc.original.statement.balance:
        builder.addBalanceChange(address, currentIndex, acc.statement.balance)

      if acc.statement.nonce != acc.original.statement.nonce:
        builder.addNonceChange(address, currentIndex, acc.statement.nonce)

      if StorageChanged in acc.flags:
        for slot, newValue in acc.overlayStorage:
          let originalValue = acc.originalStorageValue(slot, ledger)
          if newValue != originalValue:
            builder.addStorageWrite(address, slot, currentIndex, newValue)
    of Remove:
      # BAL test fixtures not covering cases where there is non-NewlyCreated get deleted.
      # The reason is EIP-6780: self destruct only in same transaction.

      # Also it's not allowed by the protocol to have an account become empty from a
      # non empty account and get deleted by the rule of EIP-161.
      # EIP-161 still delete *touched* empty accounts, but it will not appears in the BAL.

      if NewlyCreated in acc.flags:
        # A `NewlyCreated` account appears here means a contract is just created,
        # but then self destructed.
        # But this is weird, why would a non existent account have BAL entries?

        if acc.statement.balance != acc.original.statement.balance:
          builder.addBalanceChange(address, currentIndex, acc.statement.balance)

        if acc.statement.nonce != acc.original.statement.nonce:
          builder.addNonceChange(address, currentIndex, acc.statement.nonce)

        if acc.statement.codeHash != acc.original.statement.codeHash:
          builder.addCodeChange(address, currentIndex, [])

        for slot, newValue in acc.overlayStorage:
          let originalValue = acc.originalStorageValue(slot, ledger)
          if newValue != originalValue:
            builder.addStorageWrite(address, slot, currentIndex, newValue)
    of DoNothing:
      discard

  if trackTouchedAddress:
    for address, slots in ledger.accountRead:
      builder.addTouchedAccount(address)
      for slot in slots:
        builder.addStorageRead(address, slot)
    ledger.accountRead.clear()

proc init*(
    T: type BalLedgerRef,
    builder = BlockAccessListBuilderRef.init(),
): T =
  BalLedgerRef(builder: builder)

proc setBlockAccessIndex*(bal: BalLedgerRef, blockAccessIndex: int) =
  ## Must be called before processing each transaction/system contract
  ## to ensure changes are associated with the correct block access index.
  ## Note: Block access indices differ from transaction indices:
  ##   - 0: Pre-execution (system contracts like beacon roots, block hashes)
  ##   - 1..n: Transactions (tx at index i gets block_access_index i+1)
  ##   - n+1: Post-execution (withdrawals, requests)
  bal.blockAccessIndex = blockAccessIndex

proc writeToTxFrameAndBAL*(bal: BalLedgerRef,
                           ledger: LedgerRef,
                           trackTouchedAddress = false,
                           clearCache = false,
                           clearWitness = false) =
  persistPreambleImpl(ledger, true)
  collectBAL(bal, ledger, trackTouchedAddress)
  persistEpilogueImpl(ledger, clearCache, clearWitness)

proc getBlockAccessList*(
    tracker: BalLedgerRef, rebuild = false
): lent Opt[BlockAccessListRef] =
  if rebuild or tracker.blockAccessList.isNone():
    tracker.blockAccessList = Opt.some(tracker.builder.buildBlockAccessList())

  tracker.blockAccessList
