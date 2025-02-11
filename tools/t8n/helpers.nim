# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
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
  stew/byteutils,
  stint,
  json_serialization,
  json_serialization/stew/results,
  eth/common/eth_types_rlp,
  eth/common/keys,
  eth/common/blocks,
  ../../execution_chain/transaction,
  ../../execution_chain/common/chain_config,
  ../common/helpers,
  ./types

export
  helpers

createJsonFlavor T8Conv,
  automaticObjectSerialization = false,
  requireAllFields = false,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = true      # Skip optional fields==null in Reader

AccessPair.useDefaultSerializationIn T8Conv
Withdrawal.useDefaultSerializationIn T8Conv
Ommer.useDefaultSerializationIn T8Conv
Authorization.useDefaultSerializationIn T8Conv
TxObject.useDefaultSerializationIn T8Conv

template wrapValueError(body: untyped) =
  try:
    body
  except ValueError as exc:
    r.raiseUnexpectedValue(exc.msg)

proc parseHexOrInt[T](x: string): T {.raises: [ValueError].} =
  when T is UInt256:
    if x.startsWith("0x"):
      UInt256.fromHex(x)
    else:
      parse(x, UInt256, 10)
  else:
    if x.startsWith("0x"):
      fromHex[T](x)
    else:
      parseInt(x).T

proc parsePaddedHex[T](r: var JsonReader[T8Conv], val: var T)
       {.raises: [IOError, ValueError, JsonReaderError].} =
  var data = r.parseString()
  data.removePrefix("0x")
  const
    valLen = sizeof(T)
    hexLen = valLen*2
  if data.len < hexLen:
    data = repeat('0', hexLen - data.len) & data
  if data.len > hexLen:
    r.raiseUnexpectedValue("hex string is longer than expected: " & $hexLen & " get: " & $data.len)
  val = T(hexToByteArray(data, valLen))

proc readValue*(r: var JsonReader[T8Conv], val: var Address)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[T8Conv], val: var Bytes32)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[T8Conv], val: var Hash32)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    r.parsePaddedHex(val)

proc readValue*(r: var JsonReader[T8Conv], val: var UInt256)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = parseHexOrInt[UInt256](r.parseString())

proc readValue*(r: var JsonReader[T8Conv], val: var uint64)
       {.raises: [IOError, JsonReaderError].} =
  let tok = r.tokKind
  if tok == JsonValueKind.Number:
    val = r.parseInt(uint64)
  else:
    wrapValueError:
      val = parseHexOrInt[uint64](r.parseString())

proc readValue*(r: var JsonReader[T8Conv], val: var ChainId)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = parseHexOrInt[uint64](r.parseString()).ChainId

proc readValue*(r: var JsonReader[T8Conv], val: var EthTime)
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = parseHexOrInt[uint64](r.parseString()).EthTime

proc readValue*(r: var JsonReader[T8Conv], val: var seq[byte])
       {.raises: [IOError, JsonReaderError].} =
  wrapValueError:
    val = hexToSeqByte(r.parseString())

proc readValue*(r: var JsonReader[T8Conv], val: var GenesisStorage)
       {.raises: [IOError, SerializationError].} =
  r.parseObjectCustomKey:
    let slot = r.readValue(UInt256)
  do:
    val[slot] = r.readValue(UInt256)

proc readValue*(r: var JsonReader[T8Conv], val: var GenesisAccount)
       {.raises: [IOError, SerializationError].} =
  var balanceParsed = false
  r.parseObject(key):
    case key
    of "code"   : r.readValue(val.code)
    of "nonce"  : r.readValue(val.nonce)
    of "balance":
      r.readValue(val.balance)
      balanceParsed = true
    of "storage": r.readValue(val.storage)
    else: discard r.readValue(JsonString)
  if not balanceParsed:
    r.raiseUnexpectedValue("GenesisAccount: balance required")

proc readValue*(r: var JsonReader[T8Conv], val: var GenesisAlloc)
       {.raises: [IOError, SerializationError].} =
  r.parseObjectCustomKey:
    let address = r.readValue(Address)
  do:
    val[address] = r.readValue(GenesisAccount)

proc readValue*(r: var JsonReader[T8Conv], val: var Table[uint64, Hash32])
       {.raises: [IOError, SerializationError].} =
  wrapValueError:
    r.parseObjectCustomKey:
      let number = parseHexOrInt[uint64](r.parseString())
    do:
      val[number] = r.readValue(Hash32)

proc readValue*(r: var JsonReader[T8Conv], val: var EnvStruct)
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
    else: discard r.readValue(JsonString)

  if not currentCoinbaseParsed:
    r.raiseUnexpectedValue("env: currentCoinbase required")
  if not currentGasLimitParsed:
    r.raiseUnexpectedValue("env: currentGasLimit required")
  if not currentNumberParsed:
    r.raiseUnexpectedValue("env: currentNumber required")
  if not currentTimestampParsed:
    r.raiseUnexpectedValue("env: currentTimestamp required")

proc readValue*(r: var JsonReader[T8Conv], val: var TransContext)
       {.raises: [IOError, SerializationError].} =
  r.parseObject(key):
    case key
    of "alloc"  : r.readValue(val.alloc)
    of "env"    : r.readValue(val.env)
    of "txs"    : r.readValue(val.txsJson)
    of "txsRlp" : r.readValue(val.txsRlp)

proc parseTxJson(txo: TxObject, chainId: ChainId): Result[Transaction, string] =
  template required(field) =
    const fName = astToStr(oField)
    if txo.field.isNone:
      return err("missing required field '" & fName & "' in transaction")
    tx.field = txo.field.get

  template required(field, alias) =
    const fName = astToStr(oField)
    if txo.field.isNone:
      return err("missing required field '" & fName & "' in transaction")
    tx.alias = txo.field.get

  template optional(field) =
    if txo.field.isSome:
      tx.field = txo.field.get

  var tx: Transaction
  tx.txType = txo.`type`.get(0'u64).TxType
  required(nonce)
  required(gas, gasLimit)
  required(value)
  required(input, payload)
  tx.to = txo.to

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
    required(blobVersionedHashes, versionedHashes)
  of TxEip7702:
    required(chainId)
    required(maxPriorityFeePerGas)
    required(maxFeePerGas)
    optional(accessList)
    required(authorizationList)

  # Ignore chainId if txType == TxLegacy
  if tx.txType > TxLegacy and tx.chainId != chainId:
    return err("invalid chain id: have " & $tx.chainId & " want " & $chainId)

  let eip155 = txo.protected.get(true)
  if txo.secretKey.isSome:
    let secretKey = PrivateKey.fromRaw(txo.secretKey.get).valueOr:
      return err($error)
    ok(signTransaction(tx, secretKey, eip155))
  else:
    required(v, V)
    required(r, R)
    required(s, S)
    ok(tx)

proc readNestedTx(rlp: var Rlp, chainId: ChainId): Result[Transaction, string] =
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

proc parseTxs*(ctx: var TransContext, chainId: ChainId)
                {.raises: [T8NError, RlpError].} =
  var numTxs = ctx.txsJson.len
  var rlp: Rlp

  if ctx.txsRlp.len > 0:
    rlp = rlpFromBytes(ctx.txsRlp)
    if rlp.isList.not:
      raise newError(ErrorRlp, "RLP Transaction list should be a list")
    numTxs += rlp.listLen

  ctx.txList = newSeqOfCap[Result[Transaction, string]](numTxs)
  for tx in ctx.txsJson:
    ctx.txList.add parseTxJson(tx, chainId)

  if ctx.txsRlp.len > 0:
    for item in rlp:
      ctx.txList.add rlp.readNestedTx(chainId)

proc filterGoodTransactions*(ctx: TransContext): seq[Transaction] =
  for txRes in ctx.txList:
    if txRes.isOk:
      result.add txRes.get

template wrapException(body) =
  try:
    body
  except SerializationError as exc:
    raise newError(ErrorJson, exc.msg)
  except IOError as exc:
    raise newError(ErrorJson, exc.msg)

proc parseTxsJson*(ctx: var TransContext, jsonFile: string) {.raises: [T8NError].} =
  wrapException:
    ctx.txsJson = T8Conv.loadFile(jsonFile, seq[TxObject])

proc parseAlloc*(ctx: var TransContext, allocFile: string) {.raises: [T8NError].} =
  wrapException:
    ctx.alloc = T8Conv.loadFile(allocFile, GenesisAlloc)

proc parseEnv*(ctx: var TransContext, envFile: string) {.raises: [T8NError].} =
  wrapException:
    ctx.env = T8Conv.loadFile(envFile, EnvStruct)

proc parseTxsRlp*(ctx: var TransContext, hexData: string) {.raises: [ValueError].} =
  ctx.txsRlp = hexToSeqByte(hexData)

proc parseInputFromStdin*(ctx: var TransContext) {.raises: [T8NError].} =
  wrapException:
    let jsonData = stdin.readAll()
    ctx = T8Conv.decode(jsonData, TransContext)

import
  std/json

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc `@@`*[K, V](x: Table[K, V]): JsonNode
proc `@@`*[T](x: seq[T]): JsonNode

proc to0xHex(x: UInt256): string =
  "0x" & x.toHex

proc `@@`(x: uint64 | int64 | int): JsonNode =
  let hex = x.toHex.stripLeadingZeros
  %("0x" & hex.toLowerAscii)

proc `@@`(x: UInt256): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: Hash32): JsonNode =
  %("0x" & x.data.toHex)

proc `@@`*(x: seq[byte]): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: bool): JsonNode =
  %(if x: "0x1" else: "0x0")

proc `@@`(x: openArray[byte]): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: FixedBytes|Hash32|Address): JsonNode =
  @@(x.data)

proc toJson(x: Table[UInt256, UInt256]): JsonNode =
  # special case, we need to convert UInt256 into full 32 bytes
  # and not shorter
  result = newJObject()
  for k, v in x:
    result["0x" & k.dumpHex] = %("0x" & v.dumpHex)

proc `@@`(acc: GenesisAccount): JsonNode =
  result = newJObject()
  if acc.code.len > 0:
    result["code"] = @@(acc.code)
  result["balance"] = @@(acc.balance)
  if acc.nonce > 0:
    result["nonce"] = @@(acc.nonce)
  if acc.storage.len > 0:
    result["storage"] = toJson(acc.storage)

proc `@@`[K, V](x: Table[K, V]): JsonNode =
  result = newJObject()
  for k, v in x:
    result[k.to0xHex] = @@(v)

proc `@@`(x: Bloom): JsonNode =
  %("0x" & toHex(x))

proc `@@`(x: Log): JsonNode =
  %{
    "address": @@(x.address),
    "topics" : @@(x.topics),
    "data"   : @@(x.data)
  }

proc `@@`(x: TxReceipt): JsonNode =
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

proc `@@`(x: RejectedTx): JsonNode =
  %{
    "index": %(x.index),
    "error": %(x.error)
  }

proc `@@`[T](x: seq[T]): JsonNode =
  result = newJArray()
  for c in x:
    result.add @@(c)

proc `@@`[N, T](x: array[N, T]): JsonNode =
  result = newJArray()
  for c in x:
    result.add @@(c)

proc `@@`[T](x: Opt[T]): JsonNode =
  if x.isNone:
    newJNull()
  else:
    @@(x.get())

proc `@@`*(x: ExecutionResult): JsonNode =
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
