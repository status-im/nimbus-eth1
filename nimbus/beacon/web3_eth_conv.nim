# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  web3/primitives as web3types,
  web3/eth_api_types,
  web3/engine_api_types,
  web3/execution_types,
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

proc `$`*(x: Opt[common.Hash256]): string =
  if x.isNone: "none"
  else: x.get().data.toHex

proc `$`*(x: Opt[Web3Hash]): string =
  if x.isNone: "none"
  else: x.get().toHex

proc `$`*(x: Opt[PayloadID]): string =
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

func u64*(x: Opt[Web3Quantity]): Opt[uint64] =
  if x.isNone: Opt.none(uint64)
  else: Opt.some(uint64 x.get)

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

func ethHash*(x: Opt[Web3Hash]): Opt[common.Hash256] =
  if x.isNone: Opt.none(common.Hash256)
  else: Opt.some(ethHash x.get)

func ethHashes*(list: openArray[Web3Hash]): seq[common.Hash256] =
  for x in list:
    result.add ethHash(x)

func ethHashes*(list: Opt[seq[Web3Hash]]): Opt[seq[common.Hash256]] =
  if list.isNone: Opt.none(seq[common.Hash256])
  else: Opt.some ethHashes(list.get)

func ethAddr*(x: Web3Address): common.EthAddress =
  EthAddress x

func ethAddr*(x: Opt[Web3Address]): Opt[common.EthAddress] =
  if x.isNone: Opt.none(common.EthAddress)
  else: Opt.some(EthAddress x.get)

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

func ethWithdrawals*(x: Opt[seq[WithdrawalV1]]):
                       Opt[seq[common.Withdrawal]] =
  if x.isNone: Opt.none(seq[common.Withdrawal])
  else: Opt.some(ethWithdrawals x.get)

func ethTx*(x: Web3Tx): common.Transaction {.gcsafe, raises:[RlpError].} =
  result = rlp.decode(distinctBase x, common.Transaction)

func ethTxs*(list: openArray[Web3Tx]):
               seq[common.Transaction] {.gcsafe, raises:[RlpError].} =
  result = newSeqOfCap[common.Transaction](list.len)
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

func ethAccessList*(x: Opt[seq[AccessTuple]]): common.AccessList =
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

func w3Hashes*(z: Opt[seq[common.Hash256]]): Opt[seq[Web3Hash]] =
  if z.isNone: Opt.none(seq[Web3Hash])
  else:
    let list = z.get
    var v = newSeqOfCap[Web3Hash](list.len)
    for x in list:
      v.add Web3Hash x.data
    Opt.some(v)

func w3Hash*(x: Opt[common.Hash256]): Opt[BlockHash] =
  if x.isNone: Opt.none(BlockHash)
  else: Opt.some(BlockHash x.get.data)

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

func w3Qty*(x: Opt[uint64]): Opt[Web3Quantity] =
  if x.isNone: Opt.none(Web3Quantity)
  else: Opt.some(Web3Quantity x.get)

func w3Qty*(x: uint64): Web3Quantity =
  Web3Quantity(x)

func w3Qty*(x: int64): Web3Quantity =
  Web3Quantity(x)

func w3BlockNumber*(x: Opt[uint64]): Opt[Web3BlockNumber] =
  if x.isNone: Opt.none(Web3BlockNumber)
  else: Opt.some(Web3BlockNumber x.get)

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

func w3Withdrawals*(x: Opt[seq[common.Withdrawal]]):
                     Opt[seq[WithdrawalV1]] =
  if x.isNone: Opt.none(seq[WithdrawalV1])
  else: Opt.some(w3Withdrawals x.get)

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

func w3DepositRequest*(x: DepositRequest): DepositRequestV1 =
  DepositRequestV1(
    pubkey: FixedBytes[48](x.pubkey),
    withdrawalCredentials: FixedBytes[32](x.withdrawalCredentials),
    amount: w3Qty x.amount,
    signature: FixedBytes[96](x.signature),
    index: w3Qty x.index,
  )

func w3DepositRequests*(reqs: Opt[seq[Request]]): Opt[seq[DepositRequestV1]] =
  if reqs.isNone:
    return Opt.none(seq[DepositRequestV1])

  var res: seq[DepositRequestV1]
  for req in reqs.get:
    if req.requestType == DepositRequestType:
      res.add w3DepositRequest req.deposit

  ok(res)

func w3WithdrawalRequest*(x: WithdrawalRequest): WithdrawalRequestV1 =
  WithdrawalRequestV1(
    sourceAddress: w3Addr x.sourceAddress,
    validatorPubkey: FixedBytes[48](x.validatorPubkey),
    amount: w3Qty x.amount,
  )

func w3WithdrawalRequests*(reqs: Opt[seq[Request]]): Opt[seq[WithdrawalRequestV1]] =
  if reqs.isNone:
    return Opt.none(seq[WithdrawalRequestV1])

  var res: seq[WithdrawalRequestV1]
  for req in reqs.get:
    if req.requestType == WithdrawalRequestType:
      res.add w3WithdrawalRequest req.withdrawal

  ok(res)

func w3ConsolidationRequest*(x: ConsolidationRequest): ConsolidationRequestV1 =
  ConsolidationRequestV1(
    sourceAddress: w3Addr x.sourceAddress,
    sourcePubkey: FixedBytes[48](x.sourcePubkey),
    targetPubkey: FixedBytes[48](x.targetPubkey),
  )

func w3ConsolidationRequests*(reqs: Opt[seq[Request]]): Opt[seq[ConsolidationRequestV1]] =
  if reqs.isNone:
    return Opt.none(seq[ConsolidationRequestV1])

  var res: seq[ConsolidationRequestV1]
  for req in reqs.get:
    if req.requestType == ConsolidationRequestType:
      res.add w3ConsolidationRequest req.consolidation

  ok(res)

func ethRequest*(x: DepositRequestV1): Request =
  Request(
    requestType: DepositRequestType,
    deposit: DepositRequest(
      pubkey: x.pubkey.bytes,
      withdrawalCredentials: x.withdrawalCredentials.bytes,
      amount: uint64 x.amount,
      signature: x.signature.bytes,
      index: uint64 x.index,
    )
  )

func ethRequest*(x: WithdrawalRequestV1): Request =
  Request(
    requestType: WithdrawalRequestType,
    withdrawal: WithDrawalRequest(
      sourceAddress: ethAddr x.sourceAddress,
      validatorPubkey: x.validatorPubkey.bytes,
      amount: uint64 x.amount,
    )
  )

func ethRequest*(x: ConsolidationRequestV1): Request =
  Request(
    requestType: ConsolidationRequestType,
    consolidation: ConsolidationRequest(
      sourceAddress: ethAddr x.sourceAddress,
      sourcePubkey: x.sourcePubkey.bytes,
      targetPubkey: x.targetPubkey.bytes,
    )
  )

func ethRequests*(p: ExecutionPayload): Opt[seq[Request]] =
  if p.depositRequests.isNone and
     p.withdrawalRequests.isNone and
     p.consolidationRequests.isNone:
    return Opt.none(seq[Request])

  var res: seq[Request]
  if p.depositRequests.isSome:
    for x in p.depositRequests.get:
      res.add ethRequest(x)

  if p.withdrawalRequests.isSome:
    for x in p.withdrawalRequests.get:
      res.add ethRequest(x)

  if p.consolidationRequests.isSome:
    for x in p.consolidationRequests.get:
      res.add ethRequest(x)

  ok(res)
