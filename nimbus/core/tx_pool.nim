# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Pool coding
## ===========
## A piece of code using this pool architecture could look like as follows:
## ::
##    # see also unit test examples, e.g. "Block packer tests"
##    var chain: ForkedChainRef              # to be initialised
##
##
##    var xp = TxPoolRef.new(chain)          # initialise tx-pool
##    ..
##
##    xq.addTx(txs)                          # add transactions ..
##    ..                                     # .. into the buckets
##
##    let bundle = xp.assembleBlock          # fetch current block
##
##    xp.removeNewBlockTxs(bundle.blk)       # remove used transactions
##
## Why not remove used transactions in `assembleBlock`?
## ::
##    There is probability the block we proposed is rejected by
##    by network or other client produce an accepted block.
##    The block param passed through `removeNewBlockTxs` can be
##    a block newer than the the one last produced by `assembleBlock`.


{.push raises: [].}

import
  eth/common/blocks,
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_item,
  ./tx_pool/tx_desc,
  ./tx_pool/tx_packer,
  ./chain/forked_chain,
  ./casper

from eth/common/eth_types_rlp import rlpHash

# ------------------------------------------------------------------------------
# TxPoolRef public types
# ------------------------------------------------------------------------------

export
  TxPoolRef,
  TxError

# ------------------------------------------------------------------------------
# TxItemRef public getters
# ------------------------------------------------------------------------------

export
  tx,        # : Transaction
  pooledTx,  # : PooledTransaction
  id,        # : Hash32
  sender     # : Address

# ------------------------------------------------------------------------------
# TxPoolRef constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxPoolRef; chain: ForkedChainRef): T =
  ## Constructor, returns a new tx-pool descriptor.
  new result
  result.init(chain)

# ------------------------------------------------------------------------------
# TxPoolRef public getters
# ------------------------------------------------------------------------------

export
  chain,
  com,
  len

# chain(xp: TxPoolRef): ForkedChainRef
# com(xp: TxPoolRef): CommonRef
# len(xp: TxPoolRef): int

# ------------------------------------------------------------------------------
# TxPoolRef public functions
# ------------------------------------------------------------------------------

export
  addTx,
  getItem,
  removeTx,
  removeExpiredTxs

# addTx(xp: TxPoolRef, ptx: PooledTransaction): Result[void, TxError]
# addTx(xp: TxPoolRef, tx: Transaction): Result[void, TxError]
# getItem(xp: TxPoolRef, id: Hash32): Result[TxItemRef, TxError]
# removeTx(xp: TxPoolRef, id: Hash32)
# removeExpiredTxs(xp: TxPoolRef, lifeTime: Duration)

proc removeNewBlockTxs*(xp: TxPoolRef, blk: Block, optHash = Opt.none(Hash32)) =
  let fromHash = if optHash.isSome: optHash.get
                 else: blk.header.blockHash

  # Up to date, no need for further actions
  if fromHash == xp.rmHash:
    return

  # Remove only the latest block transactions
  if blk.header.parentHash == xp.rmHash:
    for tx in blk.transactions:
      let txHash = rlpHash(tx)
      xp.removeTx(txHash)

    xp.rmHash = fromHash
    return

  # Also remove transactions from older blocks
  for txHash in xp.chain.txHashInRange(fromHash, xp.rmHash):
    xp.removeTx(txHash)

  xp.rmHash = fromHash

type AssembledBlock* = object
  blk*: EthBlock
  blobsBundle*: Opt[BlobsBundle]
  blockValue*: UInt256
  executionRequests*: Opt[seq[seq[byte]]]

proc assembleBlock*(
    xp: TxPoolRef,
    someBaseFee: bool = false
): Result[AssembledBlock, string] =
  xp.updateVmState()

  # Run EVM with most profitable transactions
  var pst = xp.packerVmExec().valueOr:
    return err(error)

  var blk = EthBlock(
    header: pst.assembleHeader
  )
  var blobsBundle: BlobsBundle
  for item in pst.packedTxs:
    let tx = item.pooledTx
    blk.txs.add tx.tx
    if tx.networkPayload != nil:
      for k in tx.networkPayload.commitments:
        blobsBundle.commitments.add k
      for p in tx.networkPayload.proofs:
        blobsBundle.proofs.add p
      for blob in tx.networkPayload.blobs:
        blobsBundle.blobs.add blob
  blk.header.transactionsRoot = calcTxRoot(blk.txs)

  let com = xp.vmState.com
  if com.isShanghaiOrLater(blk.header.timestamp):
    blk.withdrawals = Opt.some(com.pos.withdrawals)

  if not com.isCancunOrLater(blk.header.timestamp) and blobsBundle.commitments.len > 0:
    return err("PooledTransaction contains blobs prior to Cancun")
  let blobsBundleOpt =
    if com.isCancunOrLater(blk.header.timestamp):
      doAssert blobsBundle.commitments.len == blobsBundle.blobs.len
      doAssert blobsBundle.proofs.len == blobsBundle.blobs.len
      Opt.some blobsBundle
    else:
      Opt.none BlobsBundle

  if someBaseFee:
    # make sure baseFee always has something
    blk.header.baseFeePerGas = Opt.some(blk.header.baseFeePerGas.get(0.u256))

  let executionRequestsOpt =
    if com.isPragueOrLater(blk.header.timestamp):
      Opt.some(pst.executionRequests)
    else:
      Opt.none(seq[seq[byte]])

  ok AssembledBlock(
    blk: blk,
    blobsBundle: blobsBundleOpt,
    blockValue: pst.blockValue,
    executionRequests: executionRequestsOpt)
