# nim-eth
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  eth/p2p/[private/p2p_types, peer_pool],
  ../p2p/chain/chain_desc,
  ../p2p/executor/process_block,
  ./protocol

{.push raises:[Defect].}

logScope:
  topics = "stateless-mode"

type
  # FIXME-Adam: copied from FastSyncCtx, but for now let's leave out some of it;
  # I don't really understand what all the fields are.
  StatelessCtx* = ref object
    finalizedBlockHeader: BlockHeader # Block which was downloaded and verified
    chain: AbstractChainDB
    peerPool: PeerPool
    trustedPeers: HashSet[Peer]
    dataSourceUrl: string

proc onPeerConnected(ctx: StatelessCtx, peer: Peer) =
  trace "New candidate for sync, not going to do anything with it for now", peer

proc onPeerDisconnected(ctx: StatelessCtx, p: Peer) =
  trace "peer disconnected", peer = p

proc new*(T: type StatelessCtx; ethNode: EthereumNode, dataSourceUrl: string): T
    {.gcsafe, raises:[Defect,CatchableError].} =
  StatelessCtx(
    # workQueue:           n/a
    # endBlockNumber:      n/a
    # hasOutOfOrderBlocks: n/a
    chain:          ethNode.chain,
    peerPool:       ethNode.peerPool,
    trustedPeers:   initHashSet[Peer](),
    finalizedBlockHeader: ethNode.chain.getBestBlockHeader,
    dataSourceUrl:  dataSourceUrl)

proc start*(ctx: StatelessCtx) {.raises:[Defect,CatchableError].} =
  var po = PeerObserver(
    onPeerConnected:
      proc(p: Peer) {.gcsafe.} =
         ctx.onPeerConnected(p),
    onPeerDisconnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerDisconnected(p))
  po.setProtocol eth
  ctx.peerPool.addObserver(ctx, po)
