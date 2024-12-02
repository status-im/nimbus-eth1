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
    forkJunction*: BlockNumber
    hash*: Hash32

  BlockDesc* = object
    blk*: Block
    receipts*: seq[Receipt]

  BaseDesc* = object
    hash*: Hash32
    header*: Header

  CanonicalDesc* = object
    ## Designate some `header` entry on a `CursorDesc` sub-chain named
    ## `cursorDesc` identified by `cursorHash == cursorDesc.hash`.
    cursorHash*: Hash32
    header*: Header

  ForkedChainRef* = ref object
    stagingTx*: CoreDbTxRef
    db*: CoreDbRef
    com*: CommonRef
    blocks*: Table[Hash32, BlockDesc]
    txRecords: Table[Hash32, (Hash32, uint64)]
    baseHash*: Hash32
    baseHeader*: Header
    cursorHash*: Hash32
    cursorHeader*: Header
    cursorHeads*: seq[CursorDesc]
    extraValidation*: bool
    baseDistance*: uint64

# ----------------

func txRecords*(c: ForkedChainRef): var Table[Hash32, (Hash32, uint64)] =
  ## Avoid clash with `forked_chain.txRecords()`
  c.txRecords

# End
