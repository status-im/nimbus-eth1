# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets
## =========================
##

import
  std/[times],
  ../keyed_queue,
  ./tx_desc,
  ./tx_gauge,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  ./tx_tabs/tx_leaf,
  chronicles,
  eth/[common, keys],
  stew/results

logScope:
  topics = "tx-pool tasks"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc getRemotesBelowTip*(xp: TxPoolRef; threshold: GasPrice): seq[Hash256]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold.
  if 0.GasPrice < threshold:
    for itemList in xp.txDB.byTipCap.decItemList(maxCap = threshold - 1):
      for item in itemList.walkItems:
        if not xp.txDB.isLocal(item.sender):
          result.add item.itemID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
