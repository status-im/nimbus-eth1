# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/tables,
  ../../../common,
  ../../../db/core_db

type
  CursorDesc* = object
    forkJunction*: BlockNumber      ## Bottom or left end of cursor arc
    hash*: Hash32                   ## Top or right end of cursor arc

  BlockDesc* = object
    blk*: Block
    txFrame*: CoreDbTxRef
    receipts*: seq[Receipt]

  PivotArc* = object
    pvHash*: Hash32                 ## Pivot item on cursor arc (e.g. new base)
    pvHeader*: Header               ## Ditto
    cursor*: CursorDesc             ## Cursor arc containing `pv` item

  ForkedChainRef* = ref object
    com*: CommonRef
    blocks*: Table[Hash32, BlockDesc]
    txRecords: Table[Hash32, (Hash32, uint64)]
    baseHash*: Hash32
    baseHeader*: Header
    baseTxFrame*: CoreDbTxRef
      # Frame that skips all in-memory state that ForkecChain holds - used to
      # lookup items straight from the database

    cursorHash*: Hash32
    cursorHeader*: Header
    cursorHeads*: seq[CursorDesc]
    extraValidation*: bool
    baseDistance*: uint64

# ----------------

func pvNumber*(pva: PivotArc): BlockNumber =
  ## Getter
  pva.pvHeader.number

func txRecords*(c: ForkedChainRef): var Table[Hash32, (Hash32, uint64)] =
  ## Avoid clash with `forked_chain.txRecords()`
  c.txRecords

# End
