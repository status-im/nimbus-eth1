import
  eth/[common],
  json_rpc/[rpcclient],
  web3/ethtypes,
  ../../../nimbus/transaction

import eth/common/eth_types as common_eth_types
type Hash256 = common_eth_types.Hash256

import web3/engine_api_types
from web3/ethtypes as web3types import nil

type
  Web3BlockHash* = web3types.BlockHash
  Web3Address* = web3types.Address
  Web3Bloom* = web3types.FixedBytes[256]
  Web3Quantity* = web3types.Quantity
  Web3PrevRandao* = web3types.FixedBytes[32]
  Web3ExtraData* = web3types.DynamicBytes[0, 32]

func toWdV1(wd: Withdrawal): WithdrawalV1 =
  result = WithdrawalV1(
    index: Web3Quantity wd.index,
    validatorIndex: Web3Quantity wd.validatorIndex,
    address: Web3Address wd.address,
    amount: Web3Quantity wd.amount
  )

func toPayloadV1OrV2*(blk: EthBlock): ExecutionPayloadV1OrV2 =
  let header = blk.header

  # Return the new payload
  result = ExecutionPayloadV1OrV2(
    parentHash:    Web3BlockHash header.parentHash.data,
    feeRecipient:  Web3Address header.coinbase,
    stateRoot:     Web3BlockHash header.stateRoot.data,
    receiptsRoot:  Web3BlockHash header.receiptRoot.data,
    logsBloom:     Web3Bloom header.bloom,
    prevRandao:    Web3PrevRandao header.mixDigest.data,
    blockNumber:   Web3Quantity header.blockNumber.truncate(uint64),
    gasLimit:      Web3Quantity header.gasLimit,
    gasUsed:       Web3Quantity header.gasUsed,
    timestamp:     Web3Quantity toUnix(header.timestamp),
    extraData:     Web3ExtraData header.extraData,
    baseFeePerGas: header.baseFee,
    blockHash:     Web3BlockHash header.blockHash.data
  )

  for tx in blk.txs:
    let txData = rlp.encode(tx)
    result.transactions.add TypedTransaction(txData)

  if blk.withdrawals.isSome:
    let withdrawals = blk.withdrawals.get
    var wds = newSeqOfCap[WithdrawalV1](withdrawals.len)
    for wd in withdrawals:
      wds.add toWdV1(wd)
    result.withdrawals = some(wds)
