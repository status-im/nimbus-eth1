# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises:[].}

import
  stew/byteutils,
  eth/rlp,
  eth/common/eth_types_rlp, chronos,
  json_rpc/[rpcclient, errors],
  ../execution_chain/beacon/web3_eth_conv,
  ../execution_chain/core/pooled_txs_rlp,
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
  except JsonReaderError as ex:
    return err(ex.formatMsg("rpc"))
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
      payloadAttributes = Opt.none(PayloadAttributesV2)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV2(update, payloadAttributes)

proc forkchoiceUpdatedV3*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributesV3)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV3(update, payloadAttributes)

proc forkchoiceUpdatedV4*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = Opt.none(PayloadAttributesV4)):
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
  of Version.V2: return client.forkchoiceUpdatedV2(update, attr.V2)
  of Version.V3: return client.forkchoiceUpdatedV3(update, attr.V3)
  of Version.V4: return client.forkchoiceUpdatedV4(update, attr.V4)
  of Version.V5, Version.V6: discard

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

proc getPayloadV5*(client: RpcClient, payloadId: Bytes8): Result[GetPayloadV5Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV5(payloadId)

proc getPayloadV6*(client: RpcClient, payloadId: Bytes8): Result[GetPayloadV6Response, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV6(payloadId)

proc getPayload*(client: RpcClient,
                 version: Version,
                 payloadId: Bytes8): Result[GetPayloadResponse, string] =
  if version == Version.V6:
    let x = client.getPayloadV6(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: Opt.some(x.blockValue),
      blobsBundleV2: Opt.some(x.blobsBundle),
      shouldOverrideBuilder: Opt.some(x.shouldOverrideBuilder),
      executionRequests: Opt.some(x.executionRequests),
    ))
  elif version == Version.V5:
    let x = client.getPayloadV5(payloadId).valueOr:
      return err(error)
    ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: Opt.some(x.blockValue),
      blobsBundleV2: Opt.some(x.blobsBundle),
      shouldOverrideBuilder: Opt.some(x.shouldOverrideBuilder),
      executionRequests: Opt.some(x.executionRequests),
    ))
  elif version == Version.V4:
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
      executionRequests: seq[seq[byte]]):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV4(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests)

proc newPayloadV5*(client: RpcClient,
      payload: ExecutionPayloadV4,
      versionedHashes: seq[VersionedHash],
      parentBeaconBlockRoot: Hash32,
      executionRequests: seq[seq[byte]]):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV5(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests)

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
      executionRequests: Opt[seq[seq[byte]]]):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV4(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests)

proc newPayloadV5*(client: RpcClient,
      payload: ExecutionPayload,
      versionedHashes: Opt[seq[VersionedHash]],
      parentBeaconBlockRoot: Opt[Hash32],
      executionRequests: Opt[seq[seq[byte]]]):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV5(payload, versionedHashes,
      parentBeaconBlockRoot, executionRequests)

proc newPayload*(client: RpcClient,
                 version: Version,
                 payload: ExecutableData): Result[PayloadStatusV1, string] =
  case version
  of Version.V1:
    return client.newPayloadV1(payload.basePayload)
  of Version.V2:
    return client.newPayloadV2(payload.basePayload)
  of Version.V3:
    return client.newPayloadV3(payload.basePayload,
      payload.versionedHashes,
      payload.beaconRoot)
  of Version.V4:
    return client.newPayloadV4(payload.basePayload,
      payload.versionedHashes,
      payload.beaconRoot,
      payload.executionRequests)
  of Version.V5:
    return client.newPayloadV5(payload.basePayload,
      payload.versionedHashes,
      payload.beaconRoot,
      payload.executionRequests)
  of Version.V6: discard

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
  )

func vHashes(x: Opt[seq[Hash32]]): seq[VersionedHash] =
  if x.isNone: return
  else: x.get

func authList(x: Opt[seq[Authorization]]): seq[Authorization] =
  if x.isNone: return
  else: x.get

proc toTransaction(tx: TransactionObject): Transaction =
  Transaction(
    txType          : tx.`type`.get(0.Web3Quantity).TxType,
    chainId         : tx.chainId.get(0.u256),
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

type
  RPCReceipt* = object
    txHash*: Hash32
    txIndex*: uint64
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
    txIndex*: Opt[uint64]
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
    txIndex: rec.transactionIndex.uint64,
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
    txIndex: maybeU64(tx.transactionIndex),
    value: tx.value,
    v: tx.v.uint64,
    r: tx.r,
    s: tx.s,
    chainId: tx.chainId,
    accessList: tx.accessList,
    maxFeePerBlobGas: tx.maxFeePerBlobGas,
    versionedHashes: if tx.blobVersionedHashes.isSome:
      Opt.some(vHashes tx.blobVersionedHashes)
    else:
      Opt.none(seq[VersionedHash]),
    authorizationList: tx.authorizationList,
  )

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
      withdrawals: res.withdrawals,
    )
    return ok(output)

proc blockByNumber*(client: RpcClient, number: uint64): Result[Block, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(blockId(number), true)
    if res.isNil:
      return err("failed to get block " & $number)
    let output = Block(
      header: toBlockHeader(res),
      transactions: toTransactions(res.transactions),
      withdrawals: res.withdrawals,
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
    let txHash = computeRlpHash(tx)
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

proc getReceipt*(client: RpcClient, txHash: Hash32): Result[ReceiptObject, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionReceipt(txHash)
    if res.isNil:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(res)

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
