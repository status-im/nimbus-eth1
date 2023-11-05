# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
  web3/engine_api_types,
  json_rpc/[rpcclient, errors, jsonmarshal],
  ../../../tests/rpcclient/eth_api,
  ../../../premix/parser,
  ../../../nimbus/rpc/hexstrings,
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv,
  ./types

import web3/engine_api as web3_engine_api

export
  execution_types,
  rpcclient

type
  Hash256 = eth_types.Hash256
  VersionedHash = engine_api_types.VersionedHash

from os import DirSep, AltSep
const
  sourceDir = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

createRpcSigs(RpcClient, sourceDir & "/engine_callsigs.nim")

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
    let tx = ethTx(w3Tx)
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

proc toBlockNumber(n: Option[HexQuantityStr]): common.BlockNumber =
  if n.isNone:
    return 0.toBlockNumber
  toBlockNumber(hexToInt(string n.get, uint64))

proc toBlockNonce(n: Option[HexDataStr]): common.BlockNonce =
  if n.isNone:
    return default(BlockNonce)
  hexToByteArray(string n.get, result)

proc maybeU256(n: Option[HexQuantityStr]): Option[UInt256] =
  if n.isNone:
    return none(UInt256)
  some(UInt256.fromHex(string n.get))

proc maybeU64(n: Option[HexQuantityStr]): Option[uint64] =
  if n.isNone:
    return none(uint64)
  some(hexToInt(string n.get, uint64))

proc maybeBool(n: Option[HexQuantityStr]): Option[bool] =
  if n.isNone:
    return none(bool)
  some(hexToInt(string n.get, int).bool)

proc maybeChainId(n: Option[HexQuantityStr]): Option[ChainId] =
  if n.isNone:
    return none(ChainId)
  some(hexToInt(string n.get, int).ChainId)

proc maybeInt(n: Option[HexQuantityStr]): Option[int] =
  if n.isNone:
    return none(int)
  some(hexToInt(string n.get, int))

proc toBlockHeader(bc: eth_api.BlockObject): common.BlockHeader =
  common.BlockHeader(
    blockNumber    : toBlockNumber(bc.number),
    parentHash     : bc.parentHash,
    nonce          : toBlockNonce(bc.nonce),
    ommersHash     : bc.sha3Uncles,
    bloom          : BloomFilter bc.logsBloom,
    txRoot         : bc.transactionsRoot,
    stateRoot      : bc.stateRoot,
    receiptRoot    : bc.receiptsRoot,
    coinbase       : bc.miner,
    difficulty     : UInt256.fromHex(string bc.difficulty),
    extraData      : hexToSeqByte(string bc.extraData),
    mixDigest      : bc.mixHash,
    gasLimit       : hexToInt(string bc.gasLimit, GasInt),
    gasUsed        : hexToInt(string bc.gasUsed, GasInt),
    timestamp      : EthTime hexToInt(string bc.timestamp, uint64),
    fee            : maybeU256(bc.baseFeePerGas),
    withdrawalsRoot: bc.withdrawalsRoot,
    blobGasUsed    : maybeU64(bc.blobGasUsed),
    excessBlobGas  : maybeU64(bc.excessBlobGas),
    parentBeaconBlockRoot: bc.parentBeaconBlockRoot,
  )

proc toTransactions(txs: openArray[JsonNode]): seq[Transaction] =
  for x in txs:
    result.add parseTransaction(x)

proc toWithdrawal(wd: rpc_types.WithdrawalObject): Withdrawal =
  Withdrawal(
    index: hexToInt(string wd.index, uint64),
    validatorIndex: hexToInt(string wd.validatorIndex, uint64),
    address: wd.address,
    amount: hexToInt(string wd.amount, uint64),
  )

proc toWithdrawals(list: seq[rpc_types.WithdrawalObject]): seq[Withdrawal] =
  result = newSeqOfCap[Withdrawal](list.len)
  for wd in list:
    result.add toWithdrawal(wd)

proc toWithdrawals(list: Option[seq[rpc_types.WithdrawalObject]]): Option[seq[Withdrawal]] =
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
    logs*: seq[FilterLog]
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
    accessList*: Option[seq[rpc_types.AccessTuple]]
    maxFeePerBlobGas*: Option[UInt256]
    versionedHashes*: Option[VersionedHashes]

proc toRPCReceipt(rec: eth_api.ReceiptObject): RPCReceipt =
  RPCReceipt(
    txHash: rec.transactionHash,
    txIndex: hexToInt(string rec.transactionIndex, int),
    blockHash: rec.blockHash,
    blockNumber: hexToInt(string rec.blockNumber, uint64),
    sender: rec.`from`,
    to: rec.to,
    cumulativeGasUsed: hexToInt(string rec.cumulativeGasUsed, GasInt),
    gasUsed: hexToInt(string rec.gasUsed, GasInt),
    contractAddress: rec.contractAddress,
    logs: rec.logs,
    logsBloom: rec.logsBloom,
    recType: hexToInt(string rec.`type`, int).ReceiptType,
    stateRoot: rec.root,
    status: maybeBool(rec.status),
    effectiveGasPrice: hexToInt(string rec.effectiveGasPrice, GasInt),
    blobGasUsed: maybeU64(rec.blobGasUsed),
    blobGasPrice: maybeU256(rec.blobGasPrice),
  )

proc toRPCTx(tx: eth_api.TransactionObject): RPCTx =
  RPCTx(
    txType: hexToInt(string tx.`type`, int).TxType,
    blockHash: tx.blockHash,
    blockNumber: maybeU64 tx.blockNumber,
    sender: tx.`from`,
    gasLimit: hexToInt(string tx.gas, GasInt),
    gasPrice: hexToInt(string tx.gasPrice, GasInt),
    maxFeePerGas: hexToInt(string tx.maxFeePerGas, GasInt),
    maxPriorityFeePerGas: hexToInt(string tx.maxPriorityFeePerGas, GasInt),
    hash: tx.hash,
    payload: tx.input,
    nonce: hexToInt(string tx.nonce, AccountNonce),
    to: tx.to,
    txIndex: maybeInt(tx.transactionIndex),
    value: UInt256.fromHex(string tx.value),
    v: hexToInt(string tx.v, int64),
    r: UInt256.fromHex(string tx.r),
    s: UInt256.fromHex(string tx.s),
    chainId: maybeChainId(tx.chainId),
    accessList: tx.accessList,
    maxFeePerBlobGas: maybeU256(tx.maxFeePerBlobGas),
    versionedHashes: tx.versionedHashes,
  )

proc waitForTTD*(client: RpcClient,
      ttd: DifficultyInt): Future[(common.BlockHeader, bool)] {.async.} =
  let period = chronos.seconds(5)
  var loop = 0
  var emptyHeader: common.BlockHeader
  while loop < 5:
    let res = await client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return (emptyHeader, false)
    let bc = res.get()
    if hexToInt(string bc.totalDifficulty, int64).u256 >= ttd:
      return (toBlockHeader(bc), true)

    await sleepAsync(period)
    inc loop

  return (emptyHeader, false)

proc blockNumber*(client: RpcClient): Result[uint64, string] =
  wrapTry:
    let res = waitFor client.eth_blockNumber()
    return ok(hexToInt(string res, uint64))

proc headerByNumber*(client: RpcClient, number: uint64): Result[common.BlockHeader, string] =
  wrapTry:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, false)
    if res.isNone:
      return err("failed to get blockHeader: " & $number)
    return ok(res.get.toBlockHeader)

proc blockByNumber*(client: RpcClient, number: uint64, output: var common.EthBlock): Result[void, string] =
  wrapTry:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, true)
    if res.isNone:
      return err("failed to get block: " & $number)
    let blk = res.get()
    output.header = toBlockHeader(blk)
    output.txs = toTransactions(blk.transactions)
    output.withdrawals = toWithdrawals(blk.withdrawals)
    return ok()

proc headerByHash*(client: RpcClient, hash: Hash256): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByHash(hash, false)
    if res.isNone:
      return err("failed to get block: " & hash.data.toHex)
    return ok(res.get.toBlockHeader)

proc latestHeader*(client: RpcClient): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return err("failed to get latest blockHeader")
    return ok(res.get.toBlockHeader)

proc latestBlock*(client: RpcClient): Result[common.EthBlock, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber("latest", true)
    if res.isNone:
      return err("failed to get latest blockHeader")
    let blk = res.get()
    let output = EthBlock(
      header: toBlockHeader(blk),
      txs: toTransactions(blk.transactions),
      withdrawals: toWithdrawals(blk.withdrawals),
    )
    return ok(output)

proc namedHeader*(client: RpcClient, name: string): Result[common.BlockHeader, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(name, false)
    if res.isNone:
      return err("failed to get named blockHeader")
    return ok(res.get.toBlockHeader)

proc sendTransaction*(client: RpcClient, tx: common.Transaction): Result[void, string] =
  wrapTry:
    let encodedTx = rlp.encode(tx)
    let res = waitFor client.eth_sendRawTransaction(hexDataStr(encodedTx))
    let txHash = rlpHash(tx)
    let getHash = Hash256(data: hexToByteArray[32](string res))
    if txHash != getHash:
      return err("sendTransaction: tx hash mismatch")
    return ok()

proc balanceAt*(client: RpcClient, address: EthAddress): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(ethAddressStr(address), "latest")
    return ok(UInt256.fromHex(res.string))

proc balanceAt*(client: RpcClient, address: EthAddress, blockNumber: UInt256): Result[UInt256, string] =
  wrapTry:
    let qty = encodeQuantity(blockNumber)
    let res = waitFor client.eth_getBalance(ethAddressStr(address), qty.string)
    return ok(UInt256.fromHex(res.string))

proc nonceAt*(client: RpcClient, address: EthAddress): Result[AccountNonce, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionCount(ethAddressStr(address), "latest")
    return ok(fromHex[AccountNonce](res.string))

proc txReceipt*(client: RpcClient, txHash: Hash256): Result[RPCReceipt, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionReceipt(txHash)
    if res.isNone:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(toRPCReceipt res.get)

proc txByHash*(client: RpcClient, txHash: Hash256): Result[RPCTx, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionByHash(txHash)
    if res.isNone:
      return err("failed to get transaction: " & txHash.data.toHex)
    return ok(toRPCTx res.get)

proc toDataStr(slot: UInt256): HexDataStr =
  let hex = slot.toHex
  let prefix = if hex.len mod 2 == 0: "0x" else: "0x0"
  HexDataStr(prefix & hex)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), toDataStr(slot), "latest")
    return ok(UInt256.fromHex(res.string))

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256, number: common.BlockNumber): Result[UInt256, string] =
  wrapTry:
    let tag = encodeQuantity(number)
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), toDataStr(slot), tag.string)
    return ok(UInt256.fromHex(res.string))

proc verifyPoWProgress*(client: RpcClient, lastBlockHash: Hash256): Future[Result[void, string]] {.async.} =
  let res = await client.eth_getBlockByHash(lastBlockHash, false)
  if res.isNone:
    return err("cannot get block by hash " & lastBlockHash.data.toHex)

  let header = res.get()
  let number = toBlockNumber(header.number)

  let period = chronos.seconds(3)
  var loop = 0
  while loop < 5:
    let res = await client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return err("cannot get latest block")

    # Chain has progressed, check that the next block is also PoW
    # Difficulty must NOT be zero
    let bc = res.get()
    let diff = hexToInt(string bc.difficulty, int64)
    if diff == 0:
      return err("Expected PoW chain to progress in PoW mode, but following block difficulty: " & $diff)

    if toBlockNumber(bc.number) > number:
      return ok()

    await sleepAsync(period)
    inc loop

  return err("verify PoW Progress timeout")


proc debugPrevRandaoTransaction*(client: RpcClient, tx: Transaction, expectedPrevRandao: Hash256): Result[void, string] =
  wrapTry:
    let hash = tx.rlpHash
    # we only interested in stack, disable all other elems
    let opts = %* {
      "disableStorage": true,
      "disableMemory": true,
      "disableState": true,
      "disableStateDiff": true
    }

    let res = waitFor client.call("debug_traceTransaction", %[%hash, opts])
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

template expectStorageEqual*(res: Result[UInt256, string], account: EthAddress,
                             expectedValue: UInt256): auto =
  if res.isErr:
    return err(res.error)
  if res.get != expectedValue:
    return err("invalid wd storage at $1 is $2, expect $3" % [
    account.toHex, $res.get, $expectedValue])

proc setBlock*(client: RpcClient, blk: EthBlock, blockNumber: Web3Quantity, stateRoot: Web3Hash): bool =
  return true
