# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises:[].}

import
  std/[times, json, strutils],
  stew/byteutils,
  eth/rlp,
  eth/common/eth_types_rlp, chronos,
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
  FixedBytes[N: static int] = engine_api_types.FixedBytes[N]

template wrapTry(body: untyped) =
  try:
    body
  except ValueError as e:
    return err(e.msg)
  except JsonRpcError as ex:
    return err(ex.msg)
  except CatchableError as ex:
    return err(ex.msg)

template wrapTrySimpleRes(body: untyped) =
  wrapTry:
    let res = waitFor body
    return ok(res)

proc forkchoiceUpdatedV1*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributesV1)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV1(update, payloadAttributes)

proc forkchoiceUpdatedV2*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributes)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV2(update, payloadAttributes)

proc forkchoiceUpdatedV3*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributes)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV3(update, payloadAttributes)

proc forkchoiceUpdatedV4*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributes)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV4(update, payloadAttributes)

proc forkchoiceUpdated*(client: RpcClient,
                        version: Version,
                        update: ForkchoiceStateV1,
                        attr = Opt.none(PayloadAttributes)):
                          Result[ForkchoiceUpdatedResponse, string] =
  case version
  of Version.V1: return client.forkchoiceUpdatedV1(update, attr.V1)
  of Version.V2: return client.forkchoiceUpdatedV2(update, attr)
  of Version.V3: return client.forkchoiceUpdatedV3(update, attr)
  of Version.V4: return client.forkchoiceUpdatedV4(update, attr)

proc getPayloadV1*(client: RpcClient, payloadId: Bytes8): Result[ExecutionPayloadV1, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV1(payloadId)

proc getPayloadV2*(client: RpcClient, payloadId: Bytes8): Result[GetPayloadV2Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV2(payloadId)

proc getPayloadV3*(client: RpcClient, payloadId: Bytes8): Result[GetPayloadV3Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV3(payloadId)

proc getPayloadV4*(client: RpcClient, payloadId: Bytes8): Result[GetPayloadV4Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV4(payloadId)

proc getPayload*(client: RpcClient,
                 version: Version,
                 payloadId: Bytes8): Result[GetPayloadResponse, string] =
  if version == Version.V4:
    let x = client.getPayloadV4(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: Opt.some(x.blockValue),
      blobsBundle: Opt.some(x.blobsBundle),
      shouldOverrideBuilder: Opt.some(x.shouldOverrideBuilder),
      executionRequests: Opt.some(x.executionRequests),
    ))
  elif version == Version.V3:
    let x = client.getPayloadV3(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: Opt.some(x.blockValue),
      blobsBundle: Opt.some(x.blobsBundle),
      shouldOverrideBuilder: Opt.some(x.shouldOverrideBuilder),
    ))
  elif version == Version.V2:
    let x = client.getPayloadV2(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: Opt.some(x.blockValue)
    ))
  else:
    let x = client.getPayloadV1(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x),
    ))

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
      parentBeaconBlockRoot: Hash32
      ):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV3(payload, versionedHashes, parentBeaconBlockRoot)

proc newPayloadV4*(client: RpcClient,
      payload: ExecutionPayloadV3,
      versionedHashes: seq[VersionedHash],
      parentBeaconBlockRoot: Hash32,
      executionRequests: array[3, seq[byte]],
      targetBlobsPerBlock: Quantity):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV4(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests, targetBlobsPerBlock)

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
      versionedHashes: Opt[seq[VersionedHash]],
      parentBeaconBlockRoot: Opt[Hash32]
      ):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV3(payload, versionedHashes, parentBeaconBlockRoot)

proc newPayloadV4*(client: RpcClient,
      payload: ExecutionPayload,
      versionedHashes: Opt[seq[VersionedHash]],
      parentBeaconBlockRoot: Opt[Hash32],
      executionRequests: Opt[array[3, seq[byte]]],
      targetBlobsPerBlock: Opt[Quantity]
      ): Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV4(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests, targetBlobsPerBlock)

proc newPayload*(client: RpcClient,
                 version: Version,
                 payload: ExecutableData): Result[PayloadStatusV1, string] =
  case version
  of Version.V1: return client.newPayloadV1(payload.basePayload)
  of Version.V2: return client.newPayloadV2(payload.basePayload)
  of Version.V3:
    return client.newPayloadV3(payload.basePayload,
      payload.versionedHashes,
      payload.beaconRoot)
  of Version.V4:
    return client.newPayloadV4(payload.basePayload,
      payload.versionedHashes,
      payload.beaconRoot,
      payload.executionRequests,
      payload.targetBlobsPerBlock)

proc exchangeCapabilities*(client: RpcClient,
      methods: seq[string]):
        Result[seq[string], string] =
  wrapTrySimpleRes:
    client.engine_exchangeCapabilities(methods)

proc toBlockNonce(n: Opt[FixedBytes[8]]): Bytes8 =
  if n.isNone:
    return default(Bytes8)
  Bytes8(n.get.data)

proc maybeU64(n: Opt[Quantity]): Opt[uint64] =
  if n.isNone:
    return Opt.none(uint64)
  Opt.some(n.get.uint64)

proc maybeBool(n: Opt[Quantity]): Opt[bool] =
  if n.isNone:
    return Opt.none(bool)
  Opt.some(n.get.bool)

proc maybeChainId(n: Opt[Quantity]): Opt[ChainId] =
  if n.isNone:
    return Opt.none(ChainId)
  Opt.some(n.get.ChainId)

proc maybeInt(n: Opt[Quantity]): Opt[int] =
  if n.isNone:
    return Opt.none(int)
  Opt.some(n.get.int)

proc toBlockHeader*(bc: BlockObject): Header =
  Header(
    number         : distinctBase(bc.number),
    parentHash     : bc.parentHash,
    nonce          : toBlockNonce(bc.nonce),
    ommersHash     : bc.sha3Uncles,
    logsBloom      : bc.logsBloom,
    transactionsRoot : bc.transactionsRoot,
    stateRoot      : bc.stateRoot,
    receiptsRoot   : bc.receiptsRoot,
    coinbase       : bc.miner,
    difficulty     : bc.difficulty,
    extraData      : bc.extraData.data,
    mixHash        : Bytes32 bc.mixHash,
    gasLimit       : bc.gasLimit.GasInt,
    gasUsed        : bc.gasUsed.GasInt,
    timestamp      : EthTime bc.timestamp,
    baseFeePerGas  : bc.baseFeePerGas,
    withdrawalsRoot: bc.withdrawalsRoot,
    blobGasUsed    : maybeU64(bc.blobGasUsed),
    excessBlobGas  : maybeU64(bc.excessBlobGas),
    parentBeaconBlockRoot: bc.parentBeaconBlockRoot,
    requestsHash   : bc.requestsHash,
    targetBlobsPerBlock: maybeU64(bc.targetBlobsPerBlock),
  )

func vHashes(x: Opt[seq[Hash32]]): seq[VersionedHash] =
  if x.isNone: return
  else: x.get

func authList(x: Opt[seq[AuthorizationObject]]): seq[Authorization] =
  if x.isNone: return
  else: ethAuthList x.get

proc toTransaction(tx: TransactionObject): Transaction =
  Transaction(
    txType          : tx.`type`.get(0.Web3Quantity).TxType,
    chainId         : tx.chainId.get(0.Web3Quantity).ChainId,
    nonce           : tx.nonce.AccountNonce,
    gasPrice        : tx.gasPrice.GasInt,
    maxPriorityFeePerGas: tx.maxPriorityFeePerGas.get(0.Web3Quantity).GasInt,
    maxFeePerGas    : tx.maxFeePerGas.get(0.Web3Quantity).GasInt,
    gasLimit        : tx.gas.GasInt,
    to              : tx.to,
    value           : tx.value,
    payload         : tx.input,
    accessList      : tx.accessList.get(@[]),
    maxFeePerBlobGas: tx.maxFeePerBlobGas.get(0.u256),
    versionedHashes : vHashes(tx.blobVersionedHashes),
    V               : tx.v.uint64,
    R               : tx.r,
    S               : tx.s,
    authorizationList: authList(tx.authorizationList),
  )

proc toTransactions*(txs: openArray[TxOrHash]): seq[Transaction] =
  for x in txs:
    doAssert x.kind == tohTx
    result.add toTransaction(x.tx)

proc toWithdrawal(wd: WithdrawalObject): Withdrawal =
  Withdrawal(
    index: wd.index.uint64,
    validatorIndex: wd.validatorIndex.uint64,
    address: wd.address,
    amount: wd.amount.uint64,
  )

proc toWithdrawals(list: seq[WithdrawalObject]): seq[Withdrawal] =
  result = newSeqOfCap[Withdrawal](list.len)
  for wd in list:
    result.add toWithdrawal(wd)

proc toWithdrawals*(list: Opt[seq[WithdrawalObject]]): Opt[seq[Withdrawal]] =
  if list.isNone:
    return Opt.none(seq[Withdrawal])
  Opt.some(toWithdrawals(list.get))

type
  RPCReceipt* = object
    txHash*: Hash32
    txIndex*: int
    blockHash*: Hash32
    blockNumber*: uint64
    sender*: Address
    to*: Opt[Address]
    cumulativeGasUsed*: GasInt
    gasUsed*: GasInt
    contractAddress*: Opt[Address]
    logs*: seq[LogObject]
    logsBloom*: FixedBytes[256]
    recType*: ReceiptType
    stateRoot*: Opt[Hash32]
    status*: Opt[bool]
    effectiveGasPrice*: GasInt
    blobGasUsed*: Opt[uint64]
    blobGasPrice*: Opt[UInt256]

  RPCTx* = object
    txType*: TxType
    blockHash*: Opt[Hash32] # none if pending
    blockNumber*: Opt[uint64]
    sender*: Address
    gasLimit*: GasInt
    gasPrice*: GasInt
    maxFeePerGas*: GasInt
    maxPriorityFeePerGas*: GasInt
    hash*: Hash32
    payload*: seq[byte]
    nonce*: AccountNonce
    to*: Opt[Address]
    txIndex*: Opt[int]
    value*: UInt256
    v*: uint64
    r*: UInt256
    s*: UInt256
    chainId*: Opt[ChainId]
    accessList*: Opt[seq[AccessPair]]
    maxFeePerBlobGas*: Opt[UInt256]
    versionedHashes*: Opt[seq[VersionedHash]]
    authorizationList*: Opt[seq[Authorization]]

proc toRPCReceipt(rec: ReceiptObject): RPCReceipt =
  RPCReceipt(
    txHash: rec.transactionHash,
    txIndex: rec.transactionIndex.int,
    blockHash: rec.blockHash,
    blockNumber: rec.blockNumber.uint64,
    sender: rec.`from`,
    to: rec.to,
    cumulativeGasUsed: rec.cumulativeGasUsed.GasInt,
    gasUsed: rec.gasUsed.GasInt,
    contractAddress: rec.contractAddress,
    logs: rec.logs,
    logsBloom: rec.logsBloom,
    recType: rec.`type`.get(0.Web3Quantity).ReceiptType,
    stateRoot: rec.root,
    status: maybeBool(rec.status),
    effectiveGasPrice: rec.effectiveGasPrice.GasInt,
    blobGasUsed: maybeU64(rec.blobGasUsed),
    blobGasPrice: rec.blobGasPrice,
  )

proc toRPCTx(tx: eth_api.TransactionObject): RPCTx =
  RPCTx(
    txType: tx.`type`.get(0.Web3Quantity).TxType,
    blockHash: tx.blockHash,
    blockNumber: maybeU64 tx.blockNumber,
    sender: tx.`from`,
    gasLimit: tx.gas.GasInt,
    gasPrice: tx.gasPrice.GasInt,
    maxFeePerGas: tx.maxFeePerGas.get(0.Web3Quantity).GasInt,
    maxPriorityFeePerGas: tx.maxPriorityFeePerGas.get(0.Web3Quantity).GasInt,
    hash: tx.hash,
    payload: tx.input,
    nonce: tx.nonce.AccountNonce,
    to: tx.to,
    txIndex: maybeInt(tx.transactionIndex),
    value: tx.value,
    v: tx.v.uint64,
    r: tx.r,
    s: tx.s,
    chainId: maybeChainId(tx.chainId),
    accessList: tx.accessList,
    maxFeePerBlobGas: tx.maxFeePerBlobGas,
    versionedHashes: if tx.blobVersionedHashes.isSome:
      Opt.some(vHashes tx.blobVersionedHashes)
    else:
      Opt.none(seq[VersionedHash]),
    authorizationList: ethAuthList(tx.authorizationList),
  )

proc waitForTTD*(client: RpcClient,
      ttd: DifficultyInt): Future[(Header, bool)] {.async.} =
  let period = chronos.seconds(5)
  var loop = 0
  var emptyHeader: Header
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

proc headerByNumber*(client: RpcClient, number: uint64): Result[Header, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId(number), false)
    if res.isNil:
      return err("failed to get blockHeader: " & $number)
    return ok(res.toBlockHeader)

proc headerByHash*(client: RpcClient, hash: Hash32): Result[Header, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByHash(hash, false)
    if res.isNil:
      return err("failed to get block: " & hash.data.toHex)
    return ok(res.toBlockHeader)

proc latestHeader*(client: RpcClient): Result[Header, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId("latest"), false)
    if res.isNil:
      return err("failed to get latest blockHeader")
    return ok(res.toBlockHeader)

proc latestBlock*(client: RpcClient): Result[Block, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId("latest"), true)
    if res.isNil:
      return err("failed to get latest blockHeader")
    let output = Block(
      header: toBlockHeader(res),
      transactions: toTransactions(res.transactions),
      withdrawals: toWithdrawals(res.withdrawals),
    )
    return ok(output)

proc namedHeader*(client: RpcClient, name: string): Result[Header, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(name, false)
    if res.isNil:
      return err("failed to get named blockHeader")
    return ok(res.toBlockHeader)

proc sendTransaction*(
    client: RpcClient, tx: PooledTransaction): Result[void, string] =
  wrapTry:
    let encodedTx = rlp.encode(tx)
    let res = waitFor client.eth_sendRawTransaction(encodedTx)
    let txHash = rlpHash(tx)
    let getHash = res
    if txHash != getHash:
      return err("sendTransaction: tx hash mismatch")
    return ok()

proc balanceAt*(client: RpcClient, address: Address): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(address, blockId("latest"))
    return ok(res)

proc balanceAt*(client: RpcClient, address: Address, number: eth_types.BlockNumber): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(address, blockId(number))
    return ok(res)

proc nonceAt*(client: RpcClient, address: Address): Result[AccountNonce, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionCount(address, blockId("latest"))
    return ok(res.AccountNonce)

proc txReceipt*(client: RpcClient, txHash: Hash32): Result[RPCReceipt, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionReceipt(txHash)
    if res.isNil:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(res.toRPCReceipt)

proc txByHash*(client: RpcClient, txHash: Hash32): Result[RPCTx, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionByHash(txHash)
    if res.isNil:
      return err("failed to get transaction: " & txHash.data.toHex)
    return ok(res.toRPCTx)

proc storageAt*(client: RpcClient, address: Address, slot: UInt256): Result[FixedBytes[32], string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(address, slot, blockId("latest"))
    return ok(res)

proc storageAt*(client: RpcClient, address: Address, slot: UInt256, number: eth_types.BlockNumber): Result[FixedBytes[32], string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(address, slot, blockId(number))
    return ok(res)

proc verifyPoWProgress*(client: RpcClient, lastBlockHash: Hash32): Future[Result[void, string]] {.async.} =
  let res = await client.eth_getBlockByHash(lastBlockHash, false)
  if res.isNil:
    return err("cannot get block by hash " & lastBlockHash.data.toHex)

  let header = res
  let number = header.number.u256

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

    if bc.number.u256 > number:
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
  proc debug_traceTransaction(hash: Hash32, opts: TraceOpts): JsonNode

proc debugPrevRandaoTransaction*(
    client: RpcClient,
    tx: PooledTransaction,
    expectedPrevRandao: Bytes32): Result[void, string] =
  wrapTry:
    let hash = tx.rlpHash
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

      let stackHash = Bytes32(hexToByteArray[32](stack[0].getStr))
      if stackHash != expectedPrevRandao:
        return err("Invalid stack after PREVRANDAO operation $1 != $2" % [stackHash.data.toHex, expectedPrevRandao.data.toHex])

    if not prevRandaoFound:
      return err("PREVRANDAO opcode not found")

    return ok()

template expectBalanceEqual*(res: Result[UInt256, string], account: Address,
                             expectedBalance: UInt256): auto =
  if res.isErr:
    return err(res.error)
  if res.get != expectedBalance:
    return err("invalid wd balance at $1, expect $2, get $3" % [
      account.toHex, $expectedBalance, $res.get])

template expectStorageEqual*(res: Result[FixedBytes[32], string], account: Address,
                             expectedValue: FixedBytes[32]): auto =
  if res.isErr:
    return err(res.error)
  if res.get != expectedValue:
    return err("invalid wd storage at $1 is $2, expect $3" % [
    account.toHex, $res.get, $expectedValue])
