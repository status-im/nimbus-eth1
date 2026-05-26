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
  std/[tables, sets],
  #eth/common/addresses,
  #stint,
  ./block_access_list_builder

import
  ../db/ledger {.all.}

type
  BalLedgerRef* = ref object
    index: int
      ## The current block access index (0 for pre-execution,
      ## 1..n for transactions, n+1 for post-execution).

    builder: BlockAccessListBuilderRef
      ## The builder instance that accumulates all tracked changes.

    blockAccessList: Opt[BlockAccessListRef]
      ## Created by the builder and cached for reuse.

proc collectBAL(bal: BalLedgerRef, ledger: LedgerRef, trackTouchedAddress: bool) =
  discard

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
  bal.index = blockAccessIndex

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
