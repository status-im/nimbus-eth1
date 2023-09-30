# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, times, typetraits],
  web3/ethtypes,
  web3/engine_api_types,
  eth/common/eth_types_rlp,
  stew/byteutils,
  ../utils/utils

from web3/ethtypes as web3types import nil
import eth/common/eth_types as common

type
  Web3Hash*       = web3types.Hash256
  Web3Address*    = web3types.Address
  Web3Bloom*      = web3types.FixedBytes[256]
  Web3Quantity*   = web3types.Quantity
  Web3PrevRandao* = web3types.FixedBytes[32]
  Web3ExtraData*  = web3types.DynamicBytes[0, 32]
  Web3Tx*         = web3types.TypedTransaction
  Web3Blob*       = web3types.Blob
  Web3KZGProof*   = web3types.KZGProof
  Web3KZGCommitment* = web3types.KZGCommitment

{.push gcsafe, raises:[].}

# ------------------------------------------------------------------------------
# Pretty printers
# ------------------------------------------------------------------------------

proc `$`*(x: Option[common.Hash256]): string =
  if x.isNone: "none"
  else: x.get().data.toHex

proc `$`*(x: Option[Web3Hash]): string =
  if x.isNone: "none"
  else: x.get().toHex

proc `$`*(x: Option[PayloadID]): string =
  if x.isNone: "none"
  else: x.get().toHex

proc `$`*[N](x: FixedBytes[N]): string =
  x.toHex

proc `$`*(x: Web3Quantity): string =
  $distinctBase(x)

proc `$`*(x: Web3Address): string =
  distinctBase(x).toHex

proc short*(x: Web3Hash): string =
  let z = common.Hash256(data: distinctBase x)
  short(z)

# ------------------------------------------------------------------------------
# Web3 defaults
# ------------------------------------------------------------------------------

func w3PrevRandao*(): Web3PrevRandao =
  discard

func w3Address*(): Web3Address =
  discard

# ------------------------------------------------------------------------------
# Web3 types to Eth types
# ------------------------------------------------------------------------------

template unsafeQuantityToInt64*(q: Web3Quantity): int64 =
  int64 q

func u64*(x: Option[Web3Quantity]): Option[uint64] =
  if x.isNone: none(uint64)
  else: some(uint64 x.get)

func u256*(x: Web3Quantity): UInt256 =
  u256(x.uint64)

func ethTime*(x: Web3Quantity): common.EthTime =
  fromUnix(x.unsafeQuantityToInt64)

func ethHash*(x: Web3PrevRandao): common.Hash256 =
  common.Hash256(data: distinctBase x)

func ethHash*(x: Option[Web3Hash]): Option[common.Hash256] =
  if x.isNone: none(common.Hash256)
  else: some(ethHash x.get)

func ethAddr*(x: Web3Address): common.EthAddress =
  EthAddress x

func ethBloom*(x: Web3Bloom): common.BloomFilter =
  common.BloomFilter distinctBase x

func ethGasInt*(x: Web3Quantity): common.GasInt =
  common.GasInt x

func ethBlob*(x: Web3ExtraData): common.Blob =
  common.Blob distinctBase x

func ethWithdrawal*(x: WithdrawalV1): common.Withdrawal =
  result.index = x.index.uint64
  result.validatorIndex = x.validatorIndex.uint64
  result.address = x.address.EthAddress
  result.amount = x.amount.uint64

func ethWithdrawals*(list: openArray[WithdrawalV1]):
                       seq[common.Withdrawal] =
  result = newSeqOfCap[common.Withdrawal](list.len)
  for x in list:
    result.add ethWithdrawal(x)

func ethWithdrawals*(x: Option[seq[WithdrawalV1]]):
                       Option[seq[common.Withdrawal]] =
  if x.isNone: none(seq[common.Withdrawal])
  else: some(ethWithdrawals x.get)

func ethTx*(x: Web3Tx): common.Transaction {.gcsafe, raises:[RlpError].} =
  result = rlp.decode(distinctBase x, common.Transaction)

func ethTxs*(list: openArray[Web3Tx]):
               seq[common.Transaction] {.gcsafe, raises:[RlpError].} =
  result = newSeqOfCap[common.Transaction](list.len)
  for x in list:
    result.add ethTx(x)

# ------------------------------------------------------------------------------
# Eth types to Web3 types
# ------------------------------------------------------------------------------

func w3Hash*(x: common.Hash256): Web3Hash =
  Web3Hash x.data

func w3Hash*(x: Option[common.Hash256]): Option[BlockHash] =
  if x.isNone: none(BlockHash)
  else: some(BlockHash x.get.data)

func w3Hash*(x: common.BlockHeader): BlockHash =
  BlockHash rlpHash(x).data

func w3Addr*(x: common.EthAddress): Web3Address =
  Web3Address x

func w3Bloom*(x: common.BloomFilter): Web3Bloom =
  Web3Bloom x

func w3PrevRandao*(x: common.Hash256): Web3PrevRandao =
  Web3PrevRandao x.data

func w3Qty*(x: UInt256): Web3Quantity =
  Web3Quantity x.truncate(uint64)

func w3Qty*(x: common.GasInt): Web3Quantity =
  Web3Quantity x.uint64

func w3Qty*(x: common.EthTime): Web3Quantity =
  Web3Quantity x.toUnix

func w3Qty*(x: common.EthTime, y: int): Web3Quantity =
  Web3Quantity(x.toUnix + y.int64)

func w3Qty*(x: Web3Quantity, y: int): Web3Quantity =
  Web3Quantity(x.uint64 + y.uint64)

func w3Qty*(x: Option[uint64]): Option[Web3Quantity] =
  if x.isNone: none(Web3Quantity)
  else: some(Web3Quantity x.get)

func w3ExtraData*(x: common.Blob): Web3ExtraData =
  Web3ExtraData x

func w3Withdrawal*(w: common.Withdrawal): WithdrawalV1 =
  WithdrawalV1(
    index         : Web3Quantity w.index,
    validatorIndex: Web3Quantity w.validatorIndex,
    address       : Web3Address  w.address,
    amount        : Web3Quantity w.amount
  )

func w3Withdrawals*(list: openArray[common.Withdrawal]): seq[WithdrawalV1] =
  result = newSeqOfCap[WithdrawalV1](list.len)
  for x in list:
    result.add w3Withdrawal(x)

func w3Withdrawals*(x: Option[seq[common.Withdrawal]]):
                     Option[seq[WithdrawalV1]] =
  if x.isNone: none(seq[WithdrawalV1])
  else: some(w3Withdrawals x.get)

func w3Tx*(tx: common.Transaction): Web3Tx =
  Web3Tx rlp.encode(tx.removeNetworkPayload)

func w3Txs*(list: openArray[common.Transaction]): seq[Web3Tx] =
  result = newSeqOfCap[Web3Tx](list.len)
  for tx in list:
    result.add w3Tx(tx)
