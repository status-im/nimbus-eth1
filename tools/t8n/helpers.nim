# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, tables],
  stew/[byteutils, assign2],
  stint,
  json_serialization,
  json_serialization/pkg/results,
  eth/common/eth_types_rlp,
  eth/common/keys,
  eth/common/blocks,
  ../../execution_chain/transaction,
  ../../execution_chain/common/chain_config,
  ../common/helpers,
  ../common/parsers,
   ./serialize_bal,
   ./types

export
  helpers,
  parsers

Withdrawal.useDefaultSerializationIn Fixture
Ommer.useDefaultSerializationIn Fixture
TxObject.useDefaultSerializationIn Fixture

proc readValue*(r: var JsonReader[Fixture], val: var EnvStruct)
       {.raises: [IOError, SerializationError].} =
  var
    currentCoinbaseParsed = false
    currentGasLimitParsed = false
    currentNumberParsed = false
    currentTimestampParsed = false

  r.parseObject(key):
    case key
    of "currentCoinbase":
      r.readValue(val.currentCoinbase)
      currentCoinbaseParsed = true
    of "currentGasLimit":
      r.readValue(val.currentGasLimit)
      currentGasLimitParsed = true
    of "currentNumber":
      r.readValue(val.currentNumber)
      currentNumberParsed = true
    of "currentTimestamp":
      r.readValue(val.currentTimestamp)
      currentTimestampParsed = true
    of "currentDifficulty": r.readValue(val.currentDifficulty)
    of "currentRandom": r.readValue(val.currentRandom)
    of "parentDifficulty": r.readValue(val.parentDifficulty)
    of "parentTimestamp": r.readValue(val.parentTimestamp)
    of "currentBaseFee": r.readValue(val.currentBaseFee)
    of "parentUncleHash": r.readValue(val.parentUncleHash)
    of "parentBaseFee": r.readValue(val.parentBaseFee)
    of "parentGasUsed": r.readValue(val.parentGasUsed)
    of "parentGasLimit": r.readValue(val.parentGasLimit)
    of "currentBlobGasUsed": r.readValue(val.currentBlobGasUsed)
    of "currentExcessBlobGas": r.readValue(val.currentExcessBlobGas)
    of "parentBlobGasUsed": r.readValue(val.parentBlobGasUsed)
    of "parentExcessBlobGas": r.readValue(val.parentExcessBlobGas)
    of "parentBeaconBlockRoot": r.readValue(val.parentBeaconBlockRoot)
    of "blockHashes": r.readValue(val.blockHashes)
    of "ommers": r.readValue(val.ommers)
    of "withdrawals": r.readValue(val.withdrawals)
    of "depositContractAddress": r.readValue(val.depositContractAddress)
    of "slotNumber": r.readValue(val.slotNumber)
    else: discard r.readValue(JsonString)

  if not currentCoinbaseParsed:
    r.raiseUnexpectedValue("env: currentCoinbase required")
  if not currentGasLimitParsed:
    r.raiseUnexpectedValue("env: currentGasLimit required")
  if not currentNumberParsed:
    r.raiseUnexpectedValue("env: currentNumber required")
  if not currentTimestampParsed:
    r.raiseUnexpectedValue("env: currentTimestamp required")

proc readValue*(r: var JsonReader[Fixture], val: var TransContext)
       {.raises: [IOError, SerializationError].} =
  r.parseObject(key):
    case key
    of "alloc"  : r.readValue(val.alloc)
    of "env"    : r.readValue(val.env)
    of "txs"    : r.readValue(val.txsJson)
    of "txsRlp" : r.readValue(val.txsRlp)

proc parseTxJson*(txo: TxObject, chainId: ChainId): Result[Transaction, string] =
  template required(field) =
    const fName = astToStr(field)
    if txo.field.isNone:
      return err("missing required field '" & fName & "' in transaction")
    tx.field = txo.field.get

  template required(field, src) =
    const srcName = astToStr(src)
    if txo.src.isNone:
      return err("missing required field '" & srcName & "' in transaction")
    tx.field = txo.src.get

  template required(field, src1, src2) =
    const
      src1Name = astToStr(src1)
      src2Name = astToStr(src2)
    if txo.src1.isNone and txo.src2.isNone:
      return err("missing required field '" & src1Name & "' or '" & src2Name & "' in transaction")
    if txo.src1.isSome:
      tx.field = txo.src1.value
    else:
      tx.field = txo.src2.value

  template optional(field) =
    if txo.field.isSome:
      tx.field = txo.field.get

  var tx: Transaction
  tx.txType = txo.`type`.get(0'u64).TxType
  required(nonce)

  if tx.txType != TxEip8141:
    required(gasLimit, gas, gasLimit)
    required(value)
    required(payload, input, data)
    if txo.to.isSome:
      if txo.to.value.len == 0:
        tx.to = Opt.none(Address)
      else:
        if txo.to.value.len != 20:
          return err("Invalid transaction 'to' address")
        var address {.noinit.}: Address
        assign(address.data, txo.to.value)
        tx.to = Opt.some(address)

  case tx.txType
  of TxLegacy:
    tx.chainId = chainId
    required(gasPrice)
  of TxEip2930:
    required(gasPrice)
    required(chainId)
    optional(accessList)
  of TxEip1559:
    required(chainId)
    required(maxPriorityFeePerGas)
    required(maxFeePerGas)
    optional(accessList)
  of TxEip4844:
    required(chainId)
    required(maxPriorityFeePerGas)
    required(maxFeePerGas)
    optional(accessList)
    required(maxFeePerBlobGas)
    required(versionedHashes, blobVersionedHashes)
  of TxEip7702:
    required(chainId)
    required(maxPriorityFeePerGas)
    required(maxFeePerGas)
    optional(accessList)
    required(authorizationList)
  of TxType5:
    return err("Unsupported tx type 5")
  of TxEip8141:
    required(chainId)
    required(sender)
    required(frames)
    required(signatures)
    required(maxPriorityFeePerGas)
    required(maxFeePerGas)
    required(maxFeePerBlobGas)
    required(versionedHashes, blobVersionedHashes)

  # Ignore chainId if txType == TxLegacy
  if tx.txType > TxLegacy and tx.chainId != chainId:
    return err("invalid chain id: have " & $tx.chainId & " want " & $chainId)

  if tx.txType == TxEip8141:
    return ok(tx)

  let eip155 = txo.protected.get(true)
  if txo.secretKey.isSome:
    let secretKey = PrivateKey.fromRaw(txo.secretKey.get).valueOr:
      return err($error)
    ok(signTransaction(tx, secretKey, eip155))
  else:
    required(V, v)
    required(R, r)
    required(S, s)
    ok(tx)

func readNestedTx(rlp: var Rlp, chainId: ChainId): Result[Transaction, string] =
  try:
    let tx = if rlp.isList:
      rlp.read(Transaction)
    else:
      var rr = rlpFromBytes(rlp.read(seq[byte]))
      rr.read(Transaction)
    # Ignore chainId if txType == TxLegacy
    if tx.txType > TxLegacy and tx.chainId != chainId:
      return err("invalid chain id: have " & $tx.chainId & " want " & $chainId)
    ok(tx)
  except RlpError as exc:
    err(exc.msg)

func parseTxs*(ctx: var TransContext, chainId: ChainId): Result[void, T8NErr] =
  var numTxs = ctx.txsJson.len
  var rlp: Rlp

  try:
    if ctx.txsRlp.len > 0:
      rlp = rlpFromBytes(ctx.txsRlp)
      if rlp.isList.not:
        return err(t8nerr(ErrorRlp, "RLP Transaction list should be a list"))
      numTxs += rlp.listLen

    ctx.txList = newSeqOfCap[Result[Transaction, string]](numTxs)
    for tx in ctx.txsJson:
      ctx.txList.add parseTxJson(tx, chainId)

    if ctx.txsRlp.len > 0:
      for item in rlp:
        ctx.txList.add rlp.readNestedTx(chainId)
  except RlpError as exc:
    return err(t8nerr(ErrorRlp, exc.msg))

  ok()

func filterGoodTransactions*(ctx: TransContext): seq[Transaction] =
  for txRes in ctx.txList:
    if txRes.isOk:
      result.add txRes.get

template wrapException(body): auto =
  try:
    body
    ok()
  except SerializationError as exc:
    err(t8nerr(ErrorJson, exc.msg))
  except IOError as exc:
    err(t8nerr(ErrorJson, exc.msg))

proc parseTxsJson*(ctx: var TransContext, jsonFile: string): Result[void, T8NErr] =
  wrapException:
    ctx.txsJson = Fixture.loadFile(jsonFile, seq[TxObject])

proc parseAlloc*(ctx: var TransContext, allocFile: string): Result[void, T8NErr] =
  wrapException:
    ctx.alloc = Fixture.loadFile(allocFile, GenesisAlloc)

proc parseEnv*(ctx: var TransContext, envFile: string): Result[void, T8NErr] =
  wrapException:
    ctx.env = Fixture.loadFile(envFile, EnvStruct)

func parseTxsRlp*(ctx: var TransContext, hexData: string): Result[void, T8NErr] =
  try:
    ctx.txsRlp = hexToSeqByte(hexData)
    ok()
  except ValueError as exc:
    err(t8nerr(ErrorValue, exc.msg))

proc parseInputFromStdin*(ctx: var TransContext): Result[void, T8NErr] =
  wrapException:
    let jsonData = stdin.readAll()
    ctx = Fixture.decode(jsonData, TransContext)

import
  std/json

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

func `@@`*[K, V](x: Table[K, V]): JsonNode
func `@@`*[T](x: seq[T]): JsonNode

func to0xHex(x: UInt256): string =
  "0x" & x.toHex

func `@@`(x: uint64 | int64 | int): JsonNode =
  let hex = x.toHex.stripLeadingZeros
  %("0x" & hex.toLowerAscii)

func `@@`(x: UInt256): JsonNode =
  %("0x" & x.toHex)

func `@@`(x: Hash32): JsonNode =
  %("0x" & x.data.toHex)

func `@@`*(x: seq[byte]): JsonNode =
  %("0x" & x.toHex)

func `@@`(x: bool): JsonNode =
  %(if x: "0x1" else: "0x0")

func `@@`(x: openArray[byte]): JsonNode =
  %("0x" & x.toHex)

func `@@`(x: FixedBytes|Hash32|Address): JsonNode =
  @@(x.data)

func toJson(x: Table[UInt256, UInt256]): JsonNode =
  # special case, we need to convert UInt256 into full 32 bytes
  # and not shorter
  result = newJObject()
  for k, v in x:
    result["0x" & k.dumpHex] = %("0x" & v.dumpHex)

func `@@`(acc: GenesisAccount): JsonNode =
  result = newJObject()
  if acc.code.len > 0:
    result["code"] = @@(acc.code)
  result["balance"] = @@(acc.balance)
  if acc.nonce > 0:
    result["nonce"] = @@(acc.nonce)
  if acc.storage.len > 0:
    result["storage"] = toJson(acc.storage)

func `@@`[K, V](x: Table[K, V]): JsonNode =
  result = newJObject()
  for k, v in x:
    result[k.to0xHex] = @@(v)

func `@@`(x: Bloom): JsonNode =
  %("0x" & toHex(x))

func `@@`(x: Log): JsonNode =
  %{
    "address": @@(x.address),
    "topics" : @@(x.topics),
    "data"   : @@(x.data)
  }

func `@@`(x: TxReceipt): JsonNode =
  result = %{
    "root"             : if x.root == default(Hash32): %("0x") else: @@(x.root),
    "status"           : @@(x.status),
    "cumulativeGasUsed": @@(x.cumulativeGasUsed),
    "logsBloom"        : @@(x.logsBloom),
    "logs"             : if x.logs.len == 0: newJNull() else: @@(x.logs),
    "transactionHash"  : @@(x.transactionHash),
    "contractAddress"  : @@(x.contractAddress),
    "gasUsed"          : @@(x.gasUsed),
    "blockHash"        : @@(x.blockHash),
    "transactionIndex" : @@(x.transactionIndex)
  }
  if x.txType > TxLegacy:
    result["type"] = %("0x" & toHex(x.txType.int, 1))

func `@@`(x: RejectedTx): JsonNode =
  %{
    "index": %(x.index),
    "error": %(x.error)
  }

func `@@`[T](x: seq[T]): JsonNode =
  result = newJArray()
  for c in x:
    result.add @@(c)

func `@@`[N, T](x: array[N, T]): JsonNode =
  result = newJArray()
  for c in x:
    result.add @@(c)

func `@@`*[T](x: Opt[T]): JsonNode =
  if x.isNone:
    newJNull()
  else:
    @@(x.value)

func `@@`*(x: ExecutionResult): JsonNode =
  result = %{
    "stateRoot"   : @@(x.stateRoot),
    "txRoot"      : @@(x.txRoot),
    "receiptsRoot": @@(x.receiptsRoot),
    "logsHash"    : @@(x.logsHash),
    "logsBloom"   : @@(x.logsBloom),
    "receipts"    : @@(x.receipts),
    "currentDifficulty": @@(x.currentDifficulty),
    "gasUsed"     : @@(x.gasUsed)
  }
  if x.rejected.len > 0:
    result["rejected"] = @@(x.rejected)
  if x.currentBaseFee.isSome:
    result["currentBaseFee"] = @@(x.currentBaseFee)
  if x.withdrawalsRoot.isSome:
    result["withdrawalsRoot"] = @@(x.withdrawalsRoot)
  if x.currentExcessBlobGas.isSome:
    result["currentExcessBlobGas"] = @@(x.currentExcessBlobGas)
  if x.blobGasUsed.isSome:
    result["blobGasUsed"] = @@(x.blobGasUsed)
  if x.requestsHash.isSome:
    result["requestsHash"] = @@(x.requestsHash)
  if x.requests.isSome:
    result["requests"] = @@(x.requests)
  if x.blockAccessListHash.isSome:
    result["blockAccessListHash"] = @@(x.blockAccessListHash)
  if x.blockAccessList.isSome:
    result["blockAccessList"] = @@(x.blockAccessList)
