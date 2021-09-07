# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool
## ================
##
## Current transaction data organisation:
##
## * All incoming transactions are queued (see `tx_queue` module)
## * Transactions indexed/bucketed by *gas price* (see `tx_list` module)
##

import
  # ./keequ,
  ./tx_pool/[tx_base, tx_item],
  eth/[keys],
  stew/results

export
  #  results,
  TxItemRef,
  tx_item.id,
  tx_item.info,
  tx_item.local,
  tx_item.timeStamp,
  tx_item.tx

type
  TxPool* = object of TxPoolBase ##\
    ## Transaction pool descriptor

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

method init*(xp: var TxPool) =
  ## Constructor, returns new tx-pool descriptor.
  procCall xp.TxPoolBase.init

proc initTxPool*: TxPool =
  ## Ditto
  result.init

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
