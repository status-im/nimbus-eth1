# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos,
  web3/eth_api,
  eth/common/[base, blocks_rlp, receipts],
  ../../rpc/portal_rpc_client,
  ../../network/history/history_content,
  ../../../execution_chain/common/[hardforks, chain_config]

export chain_config, hardforks, history_content

type PortalHistoryBridge* = ref object
  portalClient*: PortalRpcClient
  web3Client*: RpcClient
  gossipQueue*: AsyncQueue[(seq[byte], seq[byte])]
  cfg*: ChainConfig

proc gossipBlockBody*(
    bridge: PortalHistoryBridge, blockNumber: uint64, body: BlockBody
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = blockBodyContentKey(blockNumber)
  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), rlp.encode(body)))

proc gossipReceipts*(
    bridge: PortalHistoryBridge, blockNumber: uint64, receipts: StoredReceipts
): Future[void] {.async: (raises: [CancelledError]).} =
  let contentKey = receiptsContentKey(blockNumber)
  await bridge.gossipQueue.addLast((contentKey.encode.asSeq(), rlp.encode(receipts)))
