# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[times, json, strutils],
  stew/byteutils,
  eth/[common, common/eth_types, rlp], chronos,
  json_rpc/[rpcclient, errors, jsonmarshal],
  ../../../nimbus/beacon/web3_eth_conv,
  ./types

import
  web3/eth_api_types,
  web3/engine_api_types,
  web3/execution_types,
  web3/engine_api,
  web3/eth_api

export
  execution_types,
  rpcclient

type
  Hash256 = eth_types.Hash256
  VersionedHash = engine_api_types.VersionedHash

template wrapTry(body: untyped) =
  try:
    body
  except ValueError as e:
    return err(e.msg)
  except JsonRpcError as ex:
    return err(ex.msg)

template wrapTrySimpleRes(body: untyped) =
  wrapTry:
    let res = waitFor body
    return ok(res)

proc forkchoiceUpdatedV1*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = none(PayloadAttributesV1)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV1(update, payloadAttributes)

proc forkchoiceUpdatedV2*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = none(PayloadAttributes)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV2(update, payloadAttributes)

proc forkchoiceUpdatedV3*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = none(PayloadAttributes)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV3(update, payloadAttributes)

proc getPayloadV1*(client: RpcClient, payloadId: PayloadID): Result[ExecutionPayloadV1, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV1(payloadId)

proc getPayloadV2*(client: RpcClient, payloadId: PayloadID): Result[GetPayloadV2Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV2(payloadId)

proc getPayloadV3*(client: RpcClient, payloadId: PayloadID): Result[GetPayloadV3Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV3(payloadId)

proc getPayload*(client: RpcClient,
                 payloadId: PayloadID,
                 version: Version): Result[GetPayloadResponse, string] =
  if version == Version.V3:
    let x = client.getPayloadV3(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: some(x.blockValue),
      blobsBundle: some(x.blobsBundle),
      shouldOverrideBuilder: some(x.shouldOverrideBuilder),
    ))
  elif version == Version.V2:
    let x = client.getPayloadV2(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: some(x.blockValue)
    ))
  else:
    let x = client.getPayloadV1(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x),
    ))

proc forkchoiceUpdated*(client: RpcClient,
                        update: ForkchoiceStateV1,
                        attr: PayloadAttributes):
                          Result[ForkchoiceUpdatedResponse, string] =
  case attr.version
  of Version.V1: client.forkchoiceUpdatedV1(update, some attr.V1)
  of Version.V2: client.forkchoiceUpdatedV2(update, some attr)
  of Version.V3: client.forkchoiceUpdatedV3(update, some attr)

proc forkchoiceUpdated*(client: RpcClient,
                        version: Version,
                        update: ForkchoiceStateV1,
                        attr = none(PayloadAttributes)):
                          Result[ForkchoiceUpdatedResponse, string] =
  case version
  of Version.V1: client.forkchoiceUpdatedV1(update, attr.V1)
  of Version.V2: client.forkchoiceUpdatedV2(update, attr)
  of Version.V3: client.forkchoiceUpdatedV3(update, attr)

proc newPayloadV1*(client: RpcClient,
      payload: ExecutionPayloadV1):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV1(payload)

proc newPayloadV2*(client: RpcClient,
      payload: ExecutionPayloadV2):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV2(payload)

proc newPayloadV2*(client: RpcClient,
      payload: ExecutionPayloadV1OrV2):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV2(payload)

proc newPayloadV3*(client: RpcClient,
      payload: ExecutionPayloadV3,
      versionedHashes: seq[VersionedHash],
      parentBeaconBlockRoot: FixedBytes[32]
      ):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV3(payload, versionedHashes, parentBeaconBlockRoot)

proc newPayloadV1*(client: RpcClient,
      payload: ExecutionPayload):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV1(payload)

proc newPayloadV2*(client: RpcClient,
      payload: ExecutionPayload):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV2(payload)

proc newPayloadV3*(client: RpcClient,
      payload: ExecutionPayload,
      versionedHashes: Option[seq[VersionedHash]],
      parentBeaconBlockRoot: Option[FixedBytes[32]]
      ):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV3(payload, versionedHashes, parentBeaconBlockRoot)

proc collectBlobHashes(list: openArray[Web3Tx]): seq[Web3Hash] =
  for w3tx in list:
    let tx = ethTx(w3tx)
    for h in tx.versionedHashes:
      result.add w3Hash(h)

proc newPayload*(client: RpcClient,
                 payload: ExecutionPayload,
                 beaconRoot = none(common.Hash256)): Result[PayloadStatusV1, string] =
  case payload.version
  of Version.V1: return client.newPayloadV1(payload.V1)
  of Version.V2: return client.newPayloadV2(payload.V2)
  of Version.V3:
    if beaconRoot.isNone:
      # fallback
      return client.newPayloadV2(payload.V2)
    let versionedHashes = collectBlobHashes(payload.transactions)
    return client.newPayloadV3(payload.V3,
      versionedHashes,
      w3Hash beaconRoot.get)

proc newPayload*(client: RpcClient,
                 version: Version,
                 payload: ExecutableData): Result[PayloadStatusV1, string] =
  case version
  of Version.V1: return client.newPayloadV1(payload.basePayload)
  of Version.V2: return client.newPayloadV2(payload.basePayload)
  of Version.V3:
    return client.newPayloadV3(payload.basePayload,
      w3Hashes payload.versionedHashes,
      w3Hash payload.beaconRoot)

proc exchangeCapabilities*(client: RpcClient,
      methods: seq[string]):
        Result[seq[string], string] =
  wrapTrySimpleRes:
    client.engine_exchangeCapabilities(methods)

proc toBlockNumber(n: Quantity): common.BlockNumber =
  n.uint64.toBlockNumber

proc toBlockNonce(n: Option[FixedBytes[8]]): common.BlockNonce =
  if n.isNone:
    return default(BlockNonce)
  n.get.bytes

proc maybeU64(n: Option[Quantity]): Option[uint64] =
  if n.isNone:
    return none(uint64)
  some(n.get.uint64)

proc maybeBool(n: Option[Quantity]): Option[bool] =
  if n.isNone:
    return none(bool)
  some(n.get.bool)

proc maybeChainId(n: Option[Quantity]): Option[ChainId] =
  if n.isNone:
    return none(ChainId)
  some(n.get.ChainId)

proc maybeInt(n: Option[Quantity]): Option[int] =
  if n.isNone:
    return none(int)
  some(n.get.int)

proc toBlockHeader*(bc: BlockObject): common.BlockHeader =
  common.BlockHeader(
    blockNumber    : toBlockNumber(bc.number),
    parentHash     : ethHash bc.parentHash,
    nonce          : toBlockNonce(bc.nonce),
    ommersHash     : ethHash bc.sha3Uncles,
    bloom          : BloomFilter bc.logsBloom,
    txRoot         : ethHash bc.transactionsRoot,
    stateRoot      : ethHash bc.stateRoot,
    receiptRoot    : ethHash bc.receiptsRoot,
    coinbase       : ethAddr bc.miner,
    difficulty     : bc.difficulty,
    extraData      : bc.extraData.bytes,
    mixDigest      : ethHash bc.mixHash,
    gasLimit       : bc.gasLimit.GasInt,
    gasUsed        : bc.gasUsed.GasInt,
    timestamp      : EthTime bc.timestamp,
    fee            : bc.baseFeePerGas,
    withdrawalsRoot: ethHash bc.withdrawalsRoot,
    blobGasUsed    : maybeU64(bc.blobGasUsed),
    excessBlobGas  : maybeU64(bc.excessBlobGas),
    parentBeaconBlockRoot: ethHash bc.parentBeaconBlockRoot,
  )

func storageKeys(list: seq[FixedBytes[32]]): seq[StorageKey] =
  for x in list:
    result.add StorageKey(x)

func accessList(list: openArray[AccessTuple]): AccessList =
  for x in list:
    result.add AccessPair(
      address    : ethAddr x.address,
      storageKeys: storageKeys x.storageKeys,
    )

func accessList(x: Option[seq[AccessTuple]]): AccessList =
  if x.isNone: return
  else: accessList(x.get)

func vHashes(x: Option[seq[Web3Hash]]): seq[common.Hash256] =
  if x.isNone: return
  else: ethHashes(x.get)

proc toTransaction(tx: TransactionObject): Transaction =
  common.Transaction(
    txType          : tx.`type`.get(0.Web3Quantity).TxType,
    chainId         : tx.chainId.get(0.Web3Quantity).ChainId,
    nonce           : tx.nonce.AccountNonce,
    gasPrice        : tx.gasPrice.GasInt,
    maxPriorityFee  : tx.maxPriorityFeePerGas.get(0.Web3Quantity).GasInt,
    maxFee          : tx.maxFeePerGas.get(0.Web3Quantity).GasInt,
    gasLimit        : tx.gas.GasInt,
    to              : ethAddr tx.to,
    value           : tx.value,
    payload         : tx.input,
    accessList      : accessList(tx.accessList),
    maxFeePerBlobGas: tx.maxFeePerBlobGas.get(0.u256),
    versionedHashes : vHashes(tx.blobVersionedHashes),
    V               : tx.v.int64,
    R               : tx.r,
    S               : tx.s,
  )

proc toTransactions*(txs: openArray[TxOrHash]): seq[Transaction] =
  for x in txs:
    doAssert x.kind == tohTx
    result.add toTransaction(x.tx)

proc toWithdrawal(wd: WithdrawalObject): Withdrawal =
  Withdrawal(
    index: wd.index.uint64,
    validatorIndex: wd.validatorIndex.uint64,
    address: ethAddr wd.address,
    amount: wd.amount.uint64,
  )

proc toWithdrawals(list: seq[WithdrawalObject]): seq[Withdrawal] =
  result = newSeqOfCap[Withdrawal](list.len)
  for wd in list:
    result.add toWithdrawal(wd)

proc toWithdrawals*(list: Option[seq[WithdrawalObject]]): Option[seq[Withdrawal]] =
  if list.isNone:
    return none(seq[Withdrawal])
  some(toWithdrawals(list.get))

type
  RPCReceipt* = object
    txHash*: Hash256
    txIndex*: int
    blockHash*: Hash256
    blockNumber*: uint64
    sender*: EthAddress
    to*: Option[EthAddress]
    cumulativeGasUsed*: GasInt
    gasUsed*: GasInt
    contractAddress*: Option[EthAddress]
    logs*: seq[LogObject]
    logsBloom*: FixedBytes[256]
    recType*: ReceiptType
    stateRoot*: Option[Hash256]
    status*: Option[bool]
    effectiveGasPrice*: GasInt
    blobGasUsed*: Option[uint64]
    blobGasPrice*: Option[UInt256]

  RPCTx* = object
    txType*: TxType
    blockHash*: Option[Hash256] # none if pending
    blockNumber*: Option[uint64]
    sender*: EthAddress
    gasLimit*: GasInt
    gasPrice*: GasInt
    maxFeePerGas*: GasInt
    maxPriorityFeePerGas*: GasInt
    hash*: Hash256
    payload*: seq[byte]
    nonce*: AccountNonce
    to*: Option[EthAddress]
    txIndex*: Option[int]
    value*: UInt256
    v*: int64
    r*: UInt256
    s*: UInt256
    chainId*: Option[ChainId]
    accessList*: Option[seq[AccessTuple]]
    maxFeePerBlobGas*: Option[UInt256]
    versionedHashes*: Option[VersionedHashes]

proc toRPCReceipt(rec: ReceiptObject): RPCReceipt =
  RPCReceipt(
    txHash: ethHash rec.transactionHash,
    txIndex: rec.transactionIndex.int,
    blockHash: ethHash rec.blockHash,
    blockNumber: rec.blockNumber.uint64,
    sender: ethAddr rec.`from`,
    to: ethAddr rec.to,
    cumulativeGasUsed: rec.cumulativeGasUsed.GasInt,
    gasUsed: rec.gasUsed.GasInt,
    contractAddress: ethAddr rec.contractAddress,
    logs: rec.logs,
    logsBloom: rec.logsBloom,
    recType: rec.`type`.get(0.Web3Quantity).ReceiptType,
    stateRoot: ethHash rec.root,
    status: maybeBool(rec.status),
    effectiveGasPrice: rec.effectiveGasPrice.GasInt,
    blobGasUsed: maybeU64(rec.blobGasUsed),
    blobGasPrice: rec.blobGasPrice,
  )

proc toRPCTx(tx: eth_api.TransactionObject): RPCTx =
  RPCTx(
    txType: tx.`type`.get(0.Web3Quantity).TxType,
    blockHash: ethHash tx.blockHash,
    blockNumber: maybeU64 tx.blockNumber,
    sender: ethAddr tx.`from`,
    gasLimit: tx.gas.GasInt,
    gasPrice: tx.gasPrice.GasInt,
    maxFeePerGas: tx.maxFeePerGas.get(0.Web3Quantity).GasInt,
    maxPriorityFeePerGas: tx.maxPriorityFeePerGas.get(0.Web3Quantity).GasInt,
    hash: ethHash tx.hash,
    payload: tx.input,
    nonce: tx.nonce.AccountNonce,
    to: ethAddr tx.to,
    txIndex: maybeInt(tx.transactionIndex),
    value: tx.value,
    v: tx.v.int64,
    r: tx.r,
    s: tx.s,
    chainId: maybeChainId(tx.chainId),
    accessList: tx.accessList,
    maxFeePerBlobGas: tx.maxFeePerBlobGas,
    versionedHashes: ethHashes tx.blobVersionedHashes,
  )

proc waitForTTD*(client: RpcClient,
      ttd: DifficultyInt): Future[(common.BlockHeader, bool)] {.async.} =
  let period = chronos.seconds(5)
  var loop = 0
  var emptyHeader: common.BlockHeader
  while loop < 5:
    let bc = await client.eth_getBlockByNumber("latest", false)
    if bc.isNil:
      return (emptyHeader, false)
    if bc.totalDifficulty >= ttd:
      return (toBlockHeader(bc), true)

    await sleepAsync(period)
    inc loop

  return (emptyHeader, false)

proc blockNumber*(client: RpcClient): Result[uint64, string] =
  wrapTry:
    let res = waitFor client.eth_blockNumber()
    return ok(res.uint64)

proc headerByNumber*(client: RpcClient, number: uint64): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId(number), false)
    if res.isNil:
      return err("failed to get blockHeader: " & $number)
    return ok(res.toBlockHeader)

#proc blockByNumber*(client: RpcClient, number: uint64, output: var common.EthBlock): Result[void, string] =
#  wrapTry:
#    let res = waitFor client.eth_getBlockByNumber(blockId(number), true)
#    if res.isNil:
#      return err("failed to get block: " & $number)
#    output.header = toBlockHeader(res)
#    output.txs = toTransactions(res.transactions)
#    output.withdrawals = toWithdrawals(res.withdrawals)
#    return ok()

proc headerByHash*(client: RpcClient, hash: Hash256): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByHash(w3Hash hash, false)
    if res.isNil:
      return err("failed to get block: " & hash.data.toHex)
    return ok(res.toBlockHeader)

proc latestHeader*(client: RpcClient): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId("latest"), false)
    if res.isNil:
      return err("failed to get latest blockHeader")
    return ok(res.toBlockHeader)

proc latestBlock*(client: RpcClient): Result[common.EthBlock, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId("latest"), true)
    if res.isNil:
      return err("failed to get latest blockHeader")
    let output = EthBlock(
      header: toBlockHeader(res),
      txs: toTransactions(res.transactions),
      withdrawals: toWithdrawals(res.withdrawals),
    )
    return ok(output)

proc namedHeader*(client: RpcClient, name: string): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(name, false)
    if res.isNil:
      return err("failed to get named blockHeader")
    return ok(res.toBlockHeader)

proc sendTransaction*(client: RpcClient, tx: common.Transaction): Result[void, string] =
  wrapTry:
    let encodedTx = rlp.encode(tx)
    let res = waitFor client.eth_sendRawTransaction(encodedTx)
    let txHash = rlpHash(tx)
    let getHash = ethHash res
    if txHash != getHash:
      return err("sendTransaction: tx hash mismatch")
    return ok()

proc balanceAt*(client: RpcClient, address: EthAddress): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(w3Addr(address), blockId("latest"))
    return ok(res)

proc balanceAt*(client: RpcClient, address: EthAddress, number: UInt256): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(w3Addr(address), blockId(number.truncate(uint64)))
    return ok(res)

proc nonceAt*(client: RpcClient, address: EthAddress): Result[AccountNonce, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionCount(w3Addr(address), blockId("latest"))
    return ok(res.AccountNonce)

proc txReceipt*(client: RpcClient, txHash: Hash256): Result[RPCReceipt, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionReceipt(w3Hash txHash)
    if res.isNil:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(res.toRPCReceipt)

proc txByHash*(client: RpcClient, txHash: Hash256): Result[RPCTx, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionByHash(w3Hash txHash)
    if res.isNil:
      return err("failed to get transaction: " & txHash.data.toHex)
    return ok(res.toRPCTx)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256): Result[FixedBytes[32], string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(w3Addr(address), slot, blockId("latest"))
    return ok(res)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256, number: common.BlockNumber): Result[FixedBytes[32], string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(w3Addr(address), slot, blockId(number.truncate(uint64)))
    return ok(res)

proc verifyPoWProgress*(client: RpcClient, lastBlockHash: Hash256): Future[Result[void, string]] {.async.} =
  let res = await client.eth_getBlockByHash(w3Hash lastBlockHash, false)
  if res.isNil:
    return err("cannot get block by hash " & lastBlockHash.data.toHex)

  let header = res
  let number = toBlockNumber(header.number)

  let period = chronos.seconds(3)
  var loop = 0
  while loop < 5:
    let res = await client.eth_getBlockByNumber(blockId("latest"), false)
    if res.isNil:
      return err("cannot get latest block")

    # Chain has progressed, check that the next block is also PoW
    # Difficulty must NOT be zero
    let bc = res
    let diff = bc.difficulty
    if diff.isZero:
      return err("Expected PoW chain to progress in PoW mode, but following block difficulty: " & $diff)

    if toBlockNumber(bc.number) > number:
      return ok()

    await sleepAsync(period)
    inc loop

  return err("verify PoW Progress timeout")

type
  TraceOpts = object
    disableStorage: bool
    disableMemory: bool
    disableState: bool
    disableStateDiff: bool

TraceOpts.useDefaultSerializationIn JrpcConv

createRpcSigsFromNim(RpcClient):
  proc debug_traceTransaction(hash: TxHash, opts: TraceOpts): JsonNode

proc debugPrevRandaoTransaction*(client: RpcClient, tx: Transaction, expectedPrevRandao: Hash256): Result[void, string] =
  wrapTry:
    let hash = w3Hash tx.rlpHash
    # we only interested in stack, disable all other elems
    let opts = TraceOpts(
      disableStorage: true,
      disableMemory: true,
      disableState: true,
      disableStateDiff: true
    )

    let res = waitFor client.debug_traceTransaction(hash, opts)
    let structLogs = res["structLogs"]

    var prevRandaoFound = false
    for i, x in structLogs.elems:
      let op = x["op"].getStr
      if op != "DIFFICULTY": continue

      if i+1 >= structLogs.len:
        return err("No information after PREVRANDAO operation")

      prevRandaoFound = true
      let stack = structLogs[i+1]["stack"]
      if stack.len < 1:
        return err("Invalid stack after PREVRANDAO operation")

      let stackHash = Hash256(data: hextoByteArray[32](stack[0].getStr))
      if stackHash != expectedPrevRandao:
        return err("Invalid stack after PREVRANDAO operation $1 != $2" % [stackHash.data.toHex, expectedPrevRandao.data.toHex])

    if not prevRandaoFound:
      return err("PREVRANDAO opcode not found")

    return ok()

template expectBalanceEqual*(res: Result[UInt256, string], account: EthAddress,
                             expectedBalance: UInt256): auto =
  if res.isErr:
    return err(res.error)
  if res.get != expectedBalance:
    return err("invalid wd balance at $1, expect $2, get $3" % [
      account.toHex, $expectedBalance, $res.get])

template expectStorageEqual*(res: Result[FixedBytes[32], string], account: EthAddress,
                             expectedValue: FixedBytes[32]): auto =
  if res.isErr:
    return err(res.error)
  if res.get != expectedValue:
    return err("invalid wd storage at $1 is $2, expect $3" % [
    account.toHex, $res.get, $expectedValue])

proc setBlock*(client: RpcClient, blk: EthBlock, blockNumber: Web3Quantity, stateRoot: Web3Hash): bool =
  return true
