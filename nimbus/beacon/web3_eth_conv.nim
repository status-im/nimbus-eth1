# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, typetraits],
  web3/primitives as web3types,
  web3/eth_api_types,
  web3/engine_api_types,
  eth/common/eth_types_rlp,
  stew/byteutils,
  ../utils/utils

import eth/common/eth_types as common

export
  primitives

type
  Web3Hash*          = web3types.Hash256
  Web3Address*       = web3types.Address
  Web3Bloom*         = web3types.FixedBytes[256]
  Web3Quantity*      = web3types.Quantity
  Web3PrevRandao*    = web3types.FixedBytes[32]
  Web3ExtraData*     = web3types.DynamicBytes[0, 32]
  Web3BlockNumber*   = web3types.BlockNumber
  Web3Topic*         = eth_api_types.Topic
  Web3Tx*            = engine_api_types.TypedTransaction
  Web3Blob*          = engine_api_types.Blob
  Web3KZGProof*      = engine_api_types.KZGProof
  Web3KZGCommitment* = engine_api_types.KZGCommitment

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

proc `$`*(x: Web3Quantity): string =
  $distinctBase(x)

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

func w3Hash*(): Web3Hash =
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

func u256*(x: Web3BlockNumber): UInt256 =
  u256(x.uint64)

func u256*(x: FixedBytes[32]): UInt256 =
  UInt256.fromBytesBE(x.bytes)

func ethTime*(x: Web3Quantity): common.EthTime =
  common.EthTime(x)

func ethHash*(x: Web3PrevRandao): common.Hash256 =
  common.Hash256(data: distinctBase x)

func ethHash*(x: Option[Web3Hash]): Option[common.Hash256] =
  if x.isNone: none(common.Hash256)
  else: some(ethHash x.get)

func ethHashes*(list: openArray[Web3Hash]): seq[common.Hash256] =
  for x in list:
    result.add ethHash(x)

func ethHashes*(list: Option[seq[Web3Hash]]): Option[seq[common.Hash256]] =
  if list.isNone: none(seq[common.Hash256])
  else: some ethHashes(list.get)

func ethAddr*(x: Web3Address): common.EthAddress =
  EthAddress x

func ethAddr*(x: Option[Web3Address]): Option[common.EthAddress] =
  if x.isNone: none(common.EthAddress)
  else: some(EthAddress x.get)

func ethAddrs*(list: openArray[Web3Address]): seq[common.EthAddress] =
  for x in list:
    result.add ethAddr(x)

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

func ethTxs*(list: openArray[Web3Tx], removeBlobs = false):
               seq[common.Transaction] {.gcsafe, raises:[RlpError].} =
  result = newSeqOfCap[common.Transaction](list.len)
  if removeBlobs:
    for x in list:
      result.add ethTx(x).removeNetworkPayload
  else:
    for x in list:
      result.add ethTx(x)

func storageKeys(list: seq[FixedBytes[32]]): seq[StorageKey] =
  for x in list:
    result.add StorageKey(x)

func ethAccessList*(list: openArray[AccessTuple]): common.AccessList =
  for x in list:
    result.add common.AccessPair(
      address    : ethAddr x.address,
      storageKeys: storageKeys x.storageKeys,
    )

func ethAccessList*(x: Option[seq[AccessTuple]]): common.AccessList =
  if x.isSome:
    return ethAccessList(x.get)

# ------------------------------------------------------------------------------
# Eth types to Web3 types
# ------------------------------------------------------------------------------

func w3Hash*(x: common.Hash256): Web3Hash =
  Web3Hash x.data

func w3Hashes*(list: openArray[common.Hash256]): seq[Web3Hash] =
  for x in list:
    result.add Web3Hash x.data

func w3Hashes*(z: Option[seq[common.Hash256]]): Option[seq[Web3Hash]] =
  if z.isNone: none(seq[Web3Hash])
  else:
    let list = z.get
    var v = newSeqOfCap[Web3Hash](list.len)
    for x in list:
      v.add Web3Hash x.data
    some(v)

func w3Hash*(x: Option[common.Hash256]): Option[BlockHash] =
  if x.isNone: none(BlockHash)
  else: some(BlockHash x.get.data)

func w3Hash*(x: common.BlockHeader): BlockHash =
  BlockHash rlpHash(x).data

func w3Hash*(list: openArray[StorageKey]): seq[Web3Hash] =
  result = newSeqOfCap[Web3Hash](list.len)
  for x in list:
    result.add Web3Hash x

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
  Web3Quantity x.uint64

func w3Qty*(x: common.EthTime, y: int): Web3Quantity =
  Web3Quantity(x + y.EthTime)

func w3Qty*(x: Web3Quantity, y: int): Web3Quantity =
  Web3Quantity(x.uint64 + y.uint64)

func w3Qty*(x: Web3Quantity, y: EthTime): Web3Quantity =
  Web3Quantity(x.uint64 + y.uint64)

func w3Qty*(x: Web3Quantity, y: uint64): Web3Quantity =
  Web3Quantity(x.uint64 + y)

func w3Qty*(x: Option[uint64]): Option[Web3Quantity] =
  if x.isNone: none(Web3Quantity)
  else: some(Web3Quantity x.get)

func w3Qty*(x: uint64): Web3Quantity =
  Web3Quantity(x)

func w3BlockNumber*(x: Option[uint64]): Option[Web3BlockNumber] =
  if x.isNone: none(Web3BlockNumber)
  else: some(Web3BlockNumber x.get)

func w3BlockNumber*(x: uint64): Web3BlockNumber =
  Web3BlockNumber(x)

func w3BlockNumber*(x: UInt256): Web3BlockNumber =
  Web3BlockNumber x.truncate(uint64)

func w3FixedBytes*(x: UInt256): FixedBytes[32] =
  FixedBytes[32](x.toBytesBE)

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
  Web3Tx rlp.encode(tx)

func w3Txs*(list: openArray[common.Transaction]): seq[Web3Tx] =
  result = newSeqOfCap[Web3Tx](list.len)
  for tx in list:
    result.add w3Tx(tx)

proc w3AccessTuple*(ac: AccessPair): AccessTuple =
  AccessTuple(
    address: w3Addr ac.address,
    storageKeys: w3Hash(ac.storageKeys)
  )

proc w3AccessList*(list: openArray[AccessPair]): seq[AccessTuple] =
  result = newSeqOfCap[AccessTuple](list.len)
  for x in list:
    result.add w3AccessTuple(x)
