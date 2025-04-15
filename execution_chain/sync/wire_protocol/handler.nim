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
  stew/endians2,
  ./types,
  ./requester,
  ../../core/[chain, tx_pool],
  ../../networking/p2p

logScope:
  topics = "eth-wire"

const
  MAX_RECEIPTS_SERVE  = 1024
  MAX_HEADERS_SERVE   = 1024
  MAX_BODIES_SERVE    = 256
  # https://github.com/ethereum/devp2p/blob/master/caps/eth.md#getpooledtransactions-0x09
  MAX_TXS_SERVE       = 256
  SOFT_RESPONSE_LIMIT = 2 * 1024 * 1024

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(_: type EthWireRef,
          txPool: TxPoolRef): EthWireRef =
  EthWireRef(
    chain: txPool.chain,
    txPool: txPool
  )

# ------------------------------------------------------------------------------
# Public functions: eth wire protocol handlers
# ------------------------------------------------------------------------------

proc getStatus*(ctx: EthWireRef): EthState =
  let
    com = ctx.chain.com
    bestBlock = ctx.chain.latestHeader
    txFrame = ctx.chain.baseTxFrame
    forkId = com.forkId(bestBlock.number, bestBlock.timestamp)

  EthState(
    totalDifficulty: txFrame.headTotalDifficulty,
    genesisHash: com.genesisHash,
    bestBlockHash: bestBlock.blockHash,
    forkId: ChainForkId(
      forkHash: forkId.crc.toBytesBE,
      forkNext: forkId.nextFork
  ))

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
      withdrawals: blk.withdrawals
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
    list = newSeqOfCap[Header](req.maxResults)
    header = chain.blockHeader(req.startBlock).valueOr:
      return move(list)
    totalBytes = 0

  # EIP-4444 limit
  if chain.isHistoryExpiryActive:
    if req.reverse:
      if req.startBlock.number > chain.portal.limit:
        return move(list)
    else:
      if req.startBlock.number + req.maxResults > chain.portal.limit:
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

proc handleAnnouncedTxs*(ctx: EthWireRef,
                         packet: TransactionsPacket) =
  if packet.transactions.len == 0:
    return

  debug "received new transactions",
    number = packet.transactions.len

  for tx in packet.transactions:
    ctx.txPool.addTx(tx).isOkOr:
      continue

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
