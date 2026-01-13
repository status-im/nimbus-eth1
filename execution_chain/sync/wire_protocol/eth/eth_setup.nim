# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.used, push raises: [].}

import
  ../../../core/tx_pool,
  ../../../networking/p2p,
  ./[eth_handler, eth_requester, eth_types]

# ------------------------------------------------------------------------------
# Public functions: convenience mappings for `eth`
# ------------------------------------------------------------------------------

proc addEthHandlerCapability*(
    node: EthereumNode;
    txPool: TxPoolRef;
      ): EthWireRef =
  ## Install wire prototcol handlers for each cap.
  ##
  ## Note that the currently available `eth` versions have a different maximal
  ## message ID number. Setting the argument `latestOnly` to `true` there is
  ## (trivially) the same message ID for all (i.e. the only one) base protocols.
  ##
  let wire = EthWireRef.new(txPool, node)
  node.addCapability(eth69, wire)
  node.addCapability(eth68, wire)
  wire

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
