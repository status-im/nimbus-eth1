# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Move Head of Block Chain
## ==================================================
##


import
  std/[tables],
  ../../../common/common,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../../chain/forked_chain,
  eth/keys

{.push raises: [].}

type
  TxHeadDiffRef* = ref object ##\
    ## Diff data, txs changes that apply after changing the head\
    ## insertion point of the block chain

    remTxs*: Table[Hash256,bool] ##\
      ## txs to remove

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(218): func (pool *TxPool) reset(oldHead, newHead ...
proc headDiff*(xp: TxPoolRef;
               newHead: BlockHeader, chain: ForkedChainRef): Result[TxHeadDiffRef,TxInfo] =
  let
    newHash = newHead.blockHash
    txDiffs = TxHeadDiffRef()
    blk     = chain.blockByHash(newHash).valueOr:
                return err(txInfoErrForwardHeadMissing)

  for tx in blk.transactions:
    txDiffs.remTxs[tx.itemID] = true

  ok(txDiffs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
