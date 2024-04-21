# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ./web3_eth_conv,
  web3/execution_types,
  ../utils/utils,
  eth/common

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func wdRoot(list: openArray[WithdrawalV1]): common.Hash256
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    calcWithdrawalsRoot(ethWithdrawals list)

func wdRoot(x: Option[seq[WithdrawalV1]]): Option[common.Hash256]
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    if x.isNone: none(common.Hash256)
    else: some(wdRoot x.get)

func txRoot(list: openArray[Web3Tx], removeBlobs: bool): common.Hash256
             {.gcsafe, raises:[RlpError].} =
  {.noSideEffect.}:
    calcTxRoot(ethTxs(list, removeBlobs))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

{.push gcsafe, raises:[].}

func executionPayload*(blk: EthBlock): ExecutionPayload =
  ExecutionPayload(
    parentHash   : w3Hash blk.header.parentHash,
    feeRecipient : w3Addr blk.header.coinbase,
    stateRoot    : w3Hash blk.header.stateRoot,
    receiptsRoot : w3Hash blk.header.receiptRoot,
    logsBloom    : w3Bloom blk.header.bloom,
    prevRandao   : w3PrevRandao blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.blockNumber,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.fee.get(0.u256),
    blockHash    : w3Hash blk.header,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
    blobGasUsed  : w3Qty blk.header.blobGasUsed,
    excessBlobGas: w3Qty blk.header.excessBlobGas
  )

func executionPayloadV1V2*(blk: EthBlock): ExecutionPayloadV1OrV2 =
  ExecutionPayloadV1OrV2(
    parentHash   : w3Hash blk.header.parentHash,
    feeRecipient : w3Addr blk.header.coinbase,
    stateRoot    : w3Hash blk.header.stateRoot,
    receiptsRoot : w3Hash blk.header.receiptRoot,
    logsBloom    : w3Bloom blk.header.bloom,
    prevRandao   : w3PrevRandao blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.blockNumber,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.fee.get(0.u256),
    blockHash    : w3Hash blk.header,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
  )

func blockHeader*(p: ExecutionPayload,
                  removeBlobs: bool,
                  beaconRoot: Option[common.Hash256]):
                       common.BlockHeader {.gcsafe, raises:[CatchableError].} =
  common.BlockHeader(
    parentHash     : ethHash p.parentHash,
    ommersHash     : EMPTY_UNCLE_HASH,
    coinbase       : ethAddr p.feeRecipient,
    stateRoot      : ethHash p.stateRoot,
    txRoot         : txRoot(p.transactions, removeBlobs),
    receiptRoot    : ethHash p.receiptsRoot,
    bloom          : ethBloom p.logsBloom,
    difficulty     : 0.u256,
    blockNumber    : u256 p.blockNumber,
    gasLimit       : ethGasInt p.gasLimit,
    gasUsed        : ethGasInt p.gasUsed,
    timestamp      : ethTime p.timestamp,
    extraData      : ethBlob p.extraData,
    mixDigest      : ethHash p.prevRandao,
    nonce          : default(BlockNonce),
    fee            : some(p.baseFeePerGas),
    withdrawalsRoot: wdRoot p.withdrawals,
    blobGasUsed    : u64(p.blobGasUsed),
    excessBlobGas  : u64(p.excessBlobGas),
    parentBeaconBlockRoot: beaconRoot
  )

func blockBody*(p: ExecutionPayload, removeBlobs: bool):
                 common.BlockBody {.gcsafe, raises:[RlpError].} =
  common.BlockBody(
    uncles      : @[],
    transactions: ethTxs(p.transactions, removeBlobs),
    withdrawals : ethWithdrawals p.withdrawals,
  )

func ethBlock*(p: ExecutionPayload,
               removeBlobs: bool,
               beaconRoot: Option[common.Hash256]):
                 common.EthBlock {.gcsafe, raises:[CatchableError].} =
  common.Ethblock(
    header     : blockHeader(p, removeBlobs, beaconRoot),
    uncles     : @[],
    txs        : ethTxs(p.transactions, removeBlobs),
    withdrawals: ethWithdrawals p.withdrawals,
  )
