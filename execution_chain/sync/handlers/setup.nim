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
  eth/p2p,
  ../../core/[chain, tx_pool],
  ../protocol,
  ./eth as handlers_eth

# ------------------------------------------------------------------------------
# Public functions: convenience mappings for `eth`
# ------------------------------------------------------------------------------
proc addEthHandlerCapability*(
    node: EthereumNode;
    peerPool: PeerPool;
    chain: ForkedChainRef;
    txPool = TxPoolRef(nil);
      ) =
  ## Install `eth` handlers. Passing `txPool` as `nil` installs the handler
  ## in minimal/outbound mode.
  node.addCapability(
    protocol.eth,
    EthWireRef.new(chain, txPool, peerPool))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
