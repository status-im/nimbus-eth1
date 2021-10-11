#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Pack a Block
## ======================================
##


import
  std/[times],
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool pack block"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packItemsIntoBlock*(xp: TxPoolRef) =
  var
    ethBlock: EthBlock
    gasTotal: GasInt
    packAlgo = xp.algoSelect

  block packerFrame:
    for itemList in xp.txDB.byStatus.incItemList(txItemStaged):
      for item in itemList.walkItems:
        # FIXME: there must not be more than one item per sender per nonce

        # Note: the following if/else clauses assume that
        #       `xp.dbHead.trgGasLimit` <= `xp.dbHead.maxGasLimit `
        #       which is not verified here
        if xp.dbHead.trgGasLimit < gasTotal + item.tx.gasLimit:

          # curremt tx will exceed soft/target limit
          if algoPackTrgGasLimitMax notin packAlgo:
            # so this `trgGasLimit` is considered a hard limit
            if algoPackTryHarder in packAlgo:
              # try next one
              continue
            # done otherwise
            break packerFrame

          # otherwise, `trgGasLimit` might be slightly exceeded
          if xp.dbHead.maxGasLimit < gasTotal + item.tx.gasLimit:
            # curremt tx will exceed hard limit
            if {algoPackTrgGasLimitMax,algoPackTryHarder} <= packAlgo:
              # try the next one
              continue
            # done otherwise
            break packerFrame

        ethBlock.txs.add item.tx
        gasTotal += item.tx.gasLimit

        # dispose in waste basket
        discard xp.txDB.dispose(item, txInfoStagedBlockIncluded)

  # derive block
  ethBlock.header = xp.dbHead.head
  ethBlock.header.blockNumber += 1.u256
  ethBlock.header.timestamp = now().utc.toTime
  ethBlock.header.ommersHash.reset
  # TODO ...

  if gasTotal < ethBlock.header.gasLimit:
    ethBlock.header.gasLimit = xp.dbHead.maxGasLimit

  xp.ethBlock = ethBlock
  xp.ethBlockSize = gasTotal

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
