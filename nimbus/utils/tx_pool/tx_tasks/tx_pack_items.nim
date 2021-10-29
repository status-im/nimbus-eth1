# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
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
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool pack block"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packItemsIntoBlock*(xp: TxPoolRef) {.gcsafe,raises: [Defect,KeyError].} =
  ## Pack a new block and cache the components in the pool descriptor.
  var
    accu: TxPoolEthBlock # txs accumulator
    packAlgo = xp.algoSelect

  block packerFrame:
    for item in xp.txDB.byStatus.incItemList(txItemPacked):
      # FIXME: there must not be more than one item per sender per nonce

      # Note: the following if/else clauses assume that
      #       `xp.dbHead.trgGasLimit` <= `xp.dbHead.maxGasLimit `
      #       which is not verified here
      if xp.dbHead.trgGasLimit < accu.blockSize + item.tx.gasLimit:

        # curremt tx will exceed soft/target limit
        if algoPackTrgGasLimitMax notin packAlgo:
          # so this `trgGasLimit` is considered a hard limit
          if algoPackTryHarder in packAlgo:
            # try next one
            continue
          # done otherwise
          break packerFrame

        # otherwise, `trgGasLimit` might be slightly exceeded
        if xp.dbHead.maxGasLimit < accu.blockSize + item.tx.gasLimit:
          # curremt tx will exceed hard limit
          if {algoPackTrgGasLimitMax,algoPackTryHarder} <= packAlgo:
            # try the next one
            continue
          # done otherwise
          break packerFrame

      accu.blockItems.add item
      accu.blockSize += item.tx.gasLimit

  # derive block header
  accu.blockHeader.blockNumber = xp.dbHead.header.blockNumber + 1.u256
  accu.blockHeader.timestamp = now().utc.toTime
  accu.blockHeader.parentHash = xp.dbHead.header.blockHash
  accu.blockHeader.stateRoot = xp.dbHead.header.stateRoot
  accu.blockHeader.txRoot = xp.dbHead.header.txRoot
  accu.blockHeader.gasLimit = xp.dbHead.header.gasLimit

  if accu.blockHeader.gasLimit < accu.blockSize:
    accu.blockHeader.gasLimit = xp.dbHead.maxGasLimit
  # TODO ...

  xp.blockCache = accu

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
