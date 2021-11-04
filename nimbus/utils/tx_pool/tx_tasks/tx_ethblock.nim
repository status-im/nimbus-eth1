# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Assemble Block For Mining
## ===================================================
##

import
  std/[sequtils, times],
  ../tx_dbhead,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool eth block"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc ethBlockAssemble*(xp: TxPoolRef): EthBlock
    {.gcsafe,raises: [Defect,CatchableError].} =

  result.header = BlockHeader(
    blockNumber: xp.dbHead.header.blockNumber + 1.u256,
    timestamp:   getTime().utc.toTime,
    parentHash:  xp.dbHead.header.blockHash,
    stateRoot:   xp.dbHead.header.stateRoot,
    txRoot:      xp.dbHead.header.txRoot,
    gasLimit:    xp.dbHead.header.gasLimit)

  # may need increase the gas limit
  if result.header.gasLimit < xp.txDB.byStatus.eq(txItemPacked).gasLimits:
    result.header.gasLimit = xp.dbHead.maxGasLimit

  result.txs = toSeq(xp.txDB.byStatus.incItemList(txItemPacked)).mapIt(it.tx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
