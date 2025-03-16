# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.used, push raises: [].}

import
  ../../networking/p2p,
  ../../core/tx_pool,
  ./requester,
  ./handler

# ------------------------------------------------------------------------------
# Public functions: convenience mappings for `eth`
# ------------------------------------------------------------------------------
proc addEthHandlerCapability*(
    node: EthereumNode;
    txPool: TxPoolRef;
      ) =
  ## Install `eth` handlers.
  node.addCapability(
    requester.eth68,
    EthWireRef.new(txPool))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
