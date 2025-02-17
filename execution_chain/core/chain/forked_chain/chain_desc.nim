# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ./chain_branch,
  ../../../common,
  ../../../db/core_db

type
  ForkedChainRef* = ref object
    com*: CommonRef
    hashToBlock* : Table[Hash32, BlockPos]
    branches*    : seq[BranchRef]
    baseBranch*  : BranchRef
    activeBranch*: BranchRef

    txRecords    : Table[Hash32, (Hash32, uint64)]
    baseTxFrame* : CoreDbTxRef
      # Frame that skips all in-memory state that ForkedChain holds - used to
      # lookup items straight from the database

    extraValidation*: bool
    baseDistance*: uint64

# ----------------

func txRecords*(c: ForkedChainRef): var Table[Hash32, (Hash32, uint64)] =
  ## Avoid clash with `forked_chain.txRecords()`
  c.txRecords

# End
