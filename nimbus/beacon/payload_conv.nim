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
  eth/common/eth_types_rlp
# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func wdRoot(list: openArray[WithdrawalV1]): Hash32
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    calcWithdrawalsRoot(ethWithdrawals list)

func wdRoot(x: Opt[seq[WithdrawalV1]]): Opt[Hash32]
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    if x.isNone: Opt.none(Hash32)
    else: Opt.some(wdRoot x.get)

func txRoot(list: openArray[Web3Tx]): Hash32
             {.gcsafe, raises:[RlpError].} =
  {.noSideEffect.}:
    calcTxRoot(ethTxs(list))

func requestsRoot(p: ExecutionPayload): Opt[Hash32]
             {.gcsafe, raises:[].} =
  {.noSideEffect.}:
    let reqs = ethRequests(p)
    if reqs.isNone: Opt.none(Hash32)
    else: Opt.some(calcRequestsRoot reqs.get)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

{.push gcsafe, raises:[].}

func executionPayload*(blk: Block): ExecutionPayload =
  ExecutionPayload(
    parentHash   : blk.header.parentHash,
    feeRecipient : blk.header.coinbase,
    stateRoot    : blk.header.stateRoot,
    receiptsRoot : blk.header.receiptsRoot,
    logsBloom    : blk.header.logsBloom,
    prevRandao   : blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.number,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.baseFeePerGas.get(0.u256),
    blockHash    : blk.header.rlpHash,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
    blobGasUsed  : w3Qty blk.header.blobGasUsed,
    excessBlobGas: w3Qty blk.header.excessBlobGas,
    depositRequests: w3DepositRequests blk.requests,
    withdrawalRequests: w3WithdrawalRequests blk.requests,
    consolidationRequests: w3ConsolidationRequests blk.requests,
  )

func executionPayloadV1V2*(blk: Block): ExecutionPayloadV1OrV2 =
  ExecutionPayloadV1OrV2(
    parentHash   : blk.header.parentHash,
    feeRecipient : blk.header.coinbase,
    stateRoot    : blk.header.stateRoot,
    receiptsRoot : blk.header.receiptsRoot,
    logsBloom    : blk.header.logsBloom,
    prevRandao   : blk.header.prevRandao,
    blockNumber  : w3Qty blk.header.number,
    gasLimit     : w3Qty blk.header.gasLimit,
    gasUsed      : w3Qty blk.header.gasUsed,
    timestamp    : w3Qty blk.header.timestamp,
    extraData    : w3ExtraData blk.header.extraData,
    baseFeePerGas: blk.header.baseFeePerGas.get(0.u256),
    blockHash    : blk.header.rlpHash,
    transactions : w3Txs blk.txs,
    withdrawals  : w3Withdrawals blk.withdrawals,
  )

func blockHeader*(p: ExecutionPayload,
                  beaconRoot: Opt[Hash32]):
                    Header {.gcsafe, raises:[RlpError].} =
  Header(
    parentHash     : p.parentHash,
    ommersHash     : EMPTY_UNCLE_HASH,
    coinbase       : p.feeRecipient,
    stateRoot      : p.stateRoot,
    transactionsRoot: txRoot p.transactions,
    receiptsRoot   : p.receiptsRoot,
    logsBloom      : p.logsBloom,
    difficulty     : 0.u256,
    number         : distinctBase(p.blockNumber),
    gasLimit       : distinctBase(p.gasLimit),
    gasUsed        : distinctBase(p.gasUsed),
    timestamp      : ethTime p.timestamp,
    extraData      : ethBlob p.extraData,
    mixHash        : p.prevRandao,
    nonce          : default(Bytes8),
    baseFeePerGas  : Opt.some(p.baseFeePerGas),
    withdrawalsRoot: wdRoot p.withdrawals,
    blobGasUsed    : u64(p.blobGasUsed),
    excessBlobGas  : u64(p.excessBlobGas),
    parentBeaconBlockRoot: beaconRoot,
    requestsHash   : requestsRoot(p),
  )

func blockBody*(p: ExecutionPayload):
                  BlockBody {.gcsafe, raises:[RlpError].} =
  BlockBody(
    uncles      : @[],
    transactions: ethTxs p.transactions,
    withdrawals : ethWithdrawals p.withdrawals,
    requests    : ethRequests(p),
  )

func ethBlock*(p: ExecutionPayload,
               beaconRoot: Opt[Hash32]):
                 Block {.gcsafe, raises:[RlpError].} =
  Block(
    header      : blockHeader(p, beaconRoot),
    uncles      : @[],
    transactions: ethTxs p.transactions,
    withdrawals : ethWithdrawals p.withdrawals,
    requests    : ethRequests(p),
  )
