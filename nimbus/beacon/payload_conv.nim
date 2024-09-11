# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

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

func wdRoot(x: Opt[seq[WithdrawalV1]]): Opt[common.Hash256]
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    if x.isNone: Opt.none(common.Hash256)
    else: Opt.some(wdRoot x.get)

func txRoot(list: openArray[Web3Tx]): common.Hash256
             {.gcsafe, raises:[RlpError].} =
  {.noSideEffect.}:
    calcTxRoot(ethTxs(list))

func requestsRoot(p: ExecutionPayload): Opt[common.Hash256]
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    let reqs = ethRequests(p)
    if reqs.isNone: Opt.none(common.Hash256)
    else: Opt.some(calcRequestsRoot reqs.get)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

{.push gcsafe, raises:[].}

func executionPayload*(blk: EthBlock): ExecutionPayload =
  ExecutionPayload(
    parentHash   : w3Hash blk.header.parentHash,
    feeRecipient : w3Addr blk.header.coinbase,
    stateRoot    : w3Hash blk.header.stateRoot,
    receiptsRoot : w3Hash blk.header.receiptsRoot,
    logsBloom    : w3Bloom blk.header.logsBloom,
    prevRandao   : w3PrevRandao blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.number,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.baseFeePerGas.get(0.u256),
    blockHash    : w3Hash blk.header,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
    blobGasUsed  : w3Qty blk.header.blobGasUsed,
    excessBlobGas: w3Qty blk.header.excessBlobGas,
    depositRequests: w3DepositRequests blk.requests,
    withdrawalRequests: w3WithdrawalRequests blk.requests,
    consolidationRequests: w3ConsolidationRequests blk.requests,
  )

func executionPayloadV1V2*(blk: EthBlock): ExecutionPayloadV1OrV2 =
  ExecutionPayloadV1OrV2(
    parentHash   : w3Hash blk.header.parentHash,
    feeRecipient : w3Addr blk.header.coinbase,
    stateRoot    : w3Hash blk.header.stateRoot,
    receiptsRoot : w3Hash blk.header.receiptsRoot,
    logsBloom    : w3Bloom blk.header.logsBloom,
    prevRandao   : w3PrevRandao blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.number,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.baseFeePerGas.get(0.u256),
    blockHash    : w3Hash blk.header,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
  )

func blockHeader*(p: ExecutionPayload,
                  beaconRoot: Opt[common.Hash256]):
                    common.BlockHeader {.gcsafe, raises:[RlpError].} =
  common.BlockHeader(
    parentHash     : ethHash p.parentHash,
    ommersHash     : EMPTY_UNCLE_HASH,
    coinbase       : ethAddr p.feeRecipient,
    stateRoot      : ethHash p.stateRoot,
    txRoot         : txRoot p.transactions,
    receiptsRoot   : ethHash p.receiptsRoot,
    logsBloom      : ethBloom p.logsBloom,
    difficulty     : 0.u256,
    number         : common.BlockNumber(p.blockNumber),
    gasLimit       : ethGasInt p.gasLimit,
    gasUsed        : ethGasInt p.gasUsed,
    timestamp      : ethTime p.timestamp,
    extraData      : ethBlob p.extraData,
    mixHash        : ethHash p.prevRandao,
    nonce          : default(BlockNonce),
    baseFeePerGas  : Opt.some(p.baseFeePerGas),
    withdrawalsRoot: wdRoot p.withdrawals,
    blobGasUsed    : u64(p.blobGasUsed),
    excessBlobGas  : u64(p.excessBlobGas),
    parentBeaconBlockRoot: beaconRoot,
    requestsRoot   : requestsRoot(p),
  )

func blockBody*(p: ExecutionPayload):
                  common.BlockBody {.gcsafe, raises:[RlpError].} =
  common.BlockBody(
    uncles      : @[],
    transactions: ethTxs p.transactions,
    withdrawals : ethWithdrawals p.withdrawals,
    requests    : ethRequests(p),
  )

func ethBlock*(p: ExecutionPayload,
               beaconRoot: Opt[common.Hash256]):
                 common.EthBlock {.gcsafe, raises:[RlpError].} =
  common.EthBlock(
    header      : blockHeader(p, beaconRoot),
    uncles      : @[],
    transactions: ethTxs p.transactions,
    withdrawals : ethWithdrawals p.withdrawals,
    requests    : ethRequests(p),
  )
