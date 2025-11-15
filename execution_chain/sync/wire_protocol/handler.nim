# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles, chronos,
  ./types,
  ./requester,
  ./broadcast,
  ../../core/[chain, tx_pool, pooled_txs_rlp],
  ../../networking/p2p

logScope:
  topics = "eth-wire"

const
  MAX_RECEIPTS_SERVE  = 1024
  MAX_HEADERS_SERVE   = 1024
  MAX_BODIES_SERVE    = 256
  # https://github.com/ethereum/devp2p/blob/master/caps/eth.md#getpooledtransactions-0x09
  MAX_TXS_SERVE       = 256
  MAX_ACTION_HANDLER  = 128

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(_: type EthWireRef,
          txPool: TxPoolRef,
          node: EthereumNode): EthWireRef =
  let wire = EthWireRef(
    chain : txPool.chain,
    txPool: txPool,
    node  : node,
    quota : setupTokenBucket(),
    actionQueue : newAsyncQueue[ActionHandler](maxsize = MAX_ACTION_HANDLER),
  )
  wire.tickerHeartbeat = tickerLoop(wire)
  wire.actionHeartbeat = actionLoop(wire)
  wire.gossipEnabled   = not syncerRunning(wire)
  wire

# ------------------------------------------------------------------------------
# Public functions: eth wire protocol handlers
# ------------------------------------------------------------------------------

proc getStatus68*(ctx: EthWireRef): Eth68State =
  let
    com = ctx.chain.com
    bestBlock = ctx.chain.latestHeader
    txFrame = ctx.chain.baseTxFrame
    forkId = com.forkId(bestBlock.number, bestBlock.timestamp)

  Eth68State(
    totalDifficulty: txFrame.headTotalDifficulty,
    genesisHash: com.genesisHash,
    bestBlockHash: ctx.chain.latestHash,
    forkId: forkId,
  )

proc getStatus69*(ctx: EthWireRef): Eth69State =
  let
    com = ctx.chain.com
    bestBlock = ctx.chain.latestHeader
    forkId = com.forkId(bestBlock.number, bestBlock.timestamp)

  Eth69State(
    genesisHash: com.genesisHash,
    forkId: forkId,
    earliest: 0,
    latest: bestBlock.number,
    latestHash: ctx.chain.latestHash,
  )

proc getReceipts*(ctx: EthWireRef,
                  hashes: openArray[Hash32]):
                    seq[seq[Receipt]] =
  var
    list: seq[seq[Receipt]]
    totalBytes = 0

  for blockHash in hashes:
    var receiptList = ctx.chain.receiptsByBlockHash(blockHash).valueOr:
      continue

    totalBytes += getEncodedLength(receiptList)
    list.add(receiptList.to(seq[Receipt]))

    if list.len >= MAX_RECEIPTS_SERVE or
       totalBytes > SOFT_RESPONSE_LIMIT:
      break

  move(list)

proc getStoredReceipts*(ctx: EthWireRef,
                  hashes: openArray[Hash32]):
                    seq[seq[StoredReceipt]] =
  var
    list: seq[seq[StoredReceipt]]
    totalBytes = 0

  for blockHash in hashes:
    var receiptList = ctx.chain.receiptsByBlockHash(blockHash).valueOr:
      continue

    totalBytes += getEncodedLength(receiptList)
    list.add(move(receiptList))

    if list.len >= MAX_RECEIPTS_SERVE or
       totalBytes > SOFT_RESPONSE_LIMIT:
      break

  move(list)

proc getPooledTransactions*(ctx: EthWireRef,
                     hashes: openArray[Hash32]):
                       seq[PooledTransaction] =

  let txPool = ctx.txPool
  var
    list: seq[PooledTransaction]
    totalBytes = 0

  for txHash in hashes:
    let item = txPool.getItem(txHash).valueOr:
      trace "handlers.getPooledTxs: tx not found", txHash
      continue

    totalBytes += getEncodedLength(item.pooledTx)
    list.add item.pooledTx

    if list.len >= MAX_TXS_SERVE or
       totalBytes > SOFT_RESPONSE_LIMIT:
      break

  move(list)

proc getBlockBodies*(ctx: EthWireRef,
                     hashes: openArray[Hash32]):
                        seq[BlockBody] =
  var
    list: seq[BlockBody]
    totalBytes = 0

  template body(blk: Block): BlockBody =
    BlockBody(
      transactions: blk.transactions,
      uncles: blk.uncles,
      withdrawals: blk.withdrawals,
      blockAccessList: blk.blockAccessList,
    )

  for blockHash in hashes:
    let blk = ctx.chain.blockByHash(blockHash).valueOr:
      trace "handlers.getBlockBodies: blockBody not found", blockHash
      continue

    # EIP-4444 limit
    if ctx.chain.isHistoryExpiryActive:
      if blk.header.number > ctx.chain.portal.limit:
        trace "handlers.getBlockBodies: blockBody older than expiry limit", blockHash
        continue

    totalBytes += getEncodedLength(blk.body)
    list.add blk.body

    if list.len >= MAX_BODIES_SERVE or
       totalBytes > SOFT_RESPONSE_LIMIT:
      break

  move(list)

proc getBlockHeaders*(ctx: EthWireRef,
                      req: BlockHeadersRequest):
                        seq[Header] =
  let
    chain = ctx.chain

  var
    list = newSeqOfCap[Header](min(req.maxResults, MAX_HEADERS_SERVE))
    header = chain.blockHeader(req.startBlock).valueOr:
      return move(list)
    totalBytes = 0

  # EIP-4444 limit
  if chain.isHistoryExpiryActive:
    if req.reverse:
      if header.number > chain.portal.limit:
        return move(list)
    else:
      if header.number + req.maxResults > chain.portal.limit:
        return move(list)

  totalBytes += getEncodedLength(header)
  list.add header

  while uint64(list.len) < req.maxResults:
    if not req.reverse:
      header = chain.headerByNumber(header.number + 1 + req.skip).valueOr:
        break
    else:
      header = chain.headerByNumber(header.number - 1 - req.skip).valueOr:
        break

    totalBytes += getEncodedLength(header)
    list.add header

    if list.len >= MAX_HEADERS_SERVE or
       totalBytes > SOFT_RESPONSE_LIMIT:
      break

  move(list)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
