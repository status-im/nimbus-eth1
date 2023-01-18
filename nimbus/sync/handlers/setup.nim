# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/p2p,
  ../../core/[chain, tx_pool],
  ../protocol,
  ./eth as handlers_eth

{.used, push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions: convenience mappings for `eth`
# ------------------------------------------------------------------------------

proc setEthHandlerNewBlocksAndHashes*(
    node: var EthereumNode;
    blockHandler: NewBlockHandler;
    hashesHandler: NewBlockHashesHandler;
    arg: pointer)
    {.gcsafe, raises: [Defect,CatchableError].} =
  let w = EthWireRef(node.protocolState protocol.eth)
  w.setNewBlockHandler(blockHandler, arg)
  w.setNewBlockHashesHandler(hashesHandler, arg)

proc addEthHandlerCapability*(
    node: var EthereumNode;
    chain: ChainRef;
    txPool: TxPoolRef;
    peerPool: PeerPool) =
  ## Install handler
  node.addCapability(
    protocol.eth,
    EthWireRef.new(chain, txPool, peerPool))
  
# ------------------------------------------------------------------------------
# Public functions: convenience mappings for `snap`
# ------------------------------------------------------------------------------

# To do ...

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
