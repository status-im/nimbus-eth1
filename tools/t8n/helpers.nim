import
  std/[json, strutils, tables],
  stew/byteutils,
  stint,
  eth/[common, rlp, keys],
  ../../nimbus/[chain_config, forks, transaction],
  ./types

func getChainConfig*(network: string): ChainConfig =
  let c = ChainConfig()
  const
    H = high(BlockNumber)
    Zero = 0.toBlockNumber
    Five = 5.toBlockNumber

  proc assignNumber(c: ChainConfig,
                    fork: Fork, n: BlockNumber) =
    var number: array[Fork, BlockNumber]
    var z = low(Fork)
    while z < fork:
      number[z] = Zero
      z = z.succ
    number[fork] = n
    z = high(Fork)
    while z > fork:
      number[z] = H
      z = z.pred

    c.homesteadBlock      = number[FkHomestead]
    c.daoForkBlock        = number[FkHomestead]
    c.eip150Block         = number[FkTangerine]
    c.eip155Block         = number[FkSpurious]
    c.eip158Block         = number[FkSpurious]
    c.byzantiumBlock      = number[FkByzantium]
    c.constantinopleBlock = number[FkConstantinople]
    c.petersburgBlock     = number[FkPetersburg]
    c.istanbulBlock       = number[FkIstanbul]
    c.muirGlacierBlock    = number[FkBerlin]
    c.berlinBlock         = number[FkBerlin]
    c.londonBlock         = number[FkLondon]
    c.arrowGlacierBlock   = number[FkLondon]
    c.grayGlacierBlock    = number[FkLondon]
    c.mergeForkBlock      = number[FkParis]
    c.shanghaiBlock       = number[FkShanghai]
    c.cancunBlock         = number[FkCancun]

  c.daoForkSupport = false
  c.chainId = 1.ChainId
  c.terminalTotalDifficulty = none(UInt256)

  case network
  of "Frontier":
    c.assignNumber(FkFrontier, Zero)
  of "Homestead":
    c.assignNumber(FkHomestead, Zero)
  of "EIP150":
    c.assignNumber(FkTangerine, Zero)
  of "EIP158":
    c.assignNumber(FkSpurious, Zero)
  of "Byzantium":
    c.assignNumber(FkByzantium, Zero)
  of "Constantinople":
    c.assignNumber(FkConstantinople, Zero)
  of "ConstantinopleFix":
    c.assignNumber(FkPetersburg, Zero)
  of "Istanbul":
    c.assignNumber(FkIstanbul, Zero)
  of "FrontierToHomesteadAt5":
    c.assignNumber(FkHomestead, Five)
  of "HomesteadToEIP150At5":
    c.assignNumber(FkTangerine, Five)
  of "HomesteadToDaoAt5":
    c.assignNumber(FkHomestead, Zero)
    c.daoForkBlock = Five
    c.daoForkSupport = true
  of "EIP158ToByzantiumAt5":
    c.assignNumber(FkByzantium, Five)
  of "ByzantiumToConstantinopleAt5":
    c.assignNumber(FkPetersburg, Five)
  of "ByzantiumToConstantinopleFixAt5":
    c.assignNumber(FkPetersburg, Five)
    c.constantinopleBlock = Five
  of "ConstantinopleFixToIstanbulAt5":
    c.assignNumber(FkIstanbul, Five)
  of "Berlin":
    c.assignNumber(FkBerlin, Zero)
  of "BerlinToLondonAt5":
    c.assignNumber(FkLondon, Five)
  of "London":
    c.assignNumber(FkLondon, Zero)
    c.arrowGlacierBlock = H
    c.grayGlacierBlock = H
  of "ArrowGlacier":
    c.assignNumber(FkLondon, Zero)
    c.grayGlacierBlock = H
  of "GrayGlacier":
    c.assignNumber(FkLondon, Zero)
    c.grayGlacierBlock = Zero
  of "Merged":
    c.assignNumber(FkParis, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  of "ArrowGlacierToMergeAtDiffC0000":
    c.assignNumber(FkParis, H)
    c.terminalTotalDifficulty = some(0xC0000.u256)
  of "Shanghai":
    c.assignNumber(FkShanghai, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  of "Cancun":
    c.assignNumber(FkCancun, Zero)
    c.terminalTotalDifficulty = some(0.u256)
  else:
    raise newError(ErrorConfig, "unsupported network " & network)

  result = c

proc parseHexOrInt[T](x: string): T =
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

template fromJson(T: type EthAddress, n: JsonNode, field: string): EthAddress =
  hexToByteArray(n[field].getStr(), sizeof(T))

template fromJson(T: type Blob, n: JsonNode, field: string): Blob =
  hexToSeqByte(n[field].getStr())

proc fromJson(T: type uint64, n: JsonNode, field: string): uint64 =
  if n[field].kind == JInt:
    n[field].getInt().uint64
  else:
    parseHexOrInt[AccountNonce](n[field].getStr())

template fromJson(T: type UInt256, n: JsonNode, field: string): UInt256 =
  parseHexOrInt[UInt256](n[field].getStr())

template fromJson(T: type GasInt, n: JsonNode, field: string): GasInt =
  parseHexOrInt[GasInt](n[field].getStr())

template fromJson(T: type ChainId, n: JsonNode, field: string): ChainId =
  parseHexOrInt[uint64](n[field].getStr()).ChainId

proc fromJson(T: type Hash256, n: JsonNode, field: string): Hash256 =
  var num = n[field].getStr()
  num.removePrefix("0x")
  if num.len < 64:
    num = repeat('0', 64 - num.len) & num
  Hash256(data: hexToByteArray(num, 32))

template fromJson(T: type EthTime, n: JsonNode, field: string): EthTime =
  fromUnix(parseHexOrInt[int64](n[field].getStr()))

proc fromJson(T: type AccessList, n: JsonNode, field: string): AccessList =
  let z = n[field]
  if z.kind == JNull:
    return

  for x in z:
    var ap = AccessPair(
      address: EthAddress.fromJson(x, "address")
    )
    let sks = x["storageKeys"]
    for sk in sks:
      ap.storageKeys.add hexToByteArray(sk.getStr(), 32)
    result.add ap

proc fromJson(T: type Ommer, n: JsonNode): Ommer =
  Ommer(
    delta: fromJson(uint64, n, "delta"),
    address: fromJson(EthAddress, n, "address")
  )

template `gas=`(tx: var Transaction, x: GasInt) =
  tx.gasLimit = x

template `input=`(tx: var Transaction, x: Blob) =
  tx.payload = x

template `v=`(tx: var Transaction, x: int64) =
  tx.V = x

template `r=`(tx: var Transaction, x: UInt256) =
  tx.R = x

template `s=`(tx: var Transaction, x: UInt256) =
  tx.S = x

template `maxPriorityFeePerGas=`(tx: var Transaction, x: GasInt) =
  tx.maxPriorityFee = x

template `maxFeePerGas=`(tx: var Transaction, x: GasInt) =
  tx.maxFee = x

template required(o: untyped, T: type, oField: untyped) =
  const fName = astToStr(oField)
  if not n.hasKey(fName):
    raise newError(ErrorJson, "missing required field '" & fName & "' in transaction")
  o.oField = T.fromJson(n, fName)

template omitZero(o: untyped, T: type, oField: untyped) =
  const fName = astToStr(oField)
  if n.hasKey(fName):
    o.oField = T.fromJson(n, fName)

template optional(o: untyped, T: type, oField: untyped) =
  const fName = astToStr(oField)
  if n.hasKey(fName) and n[fName].kind != JNull:
    o.oField = some(T.fromJson(n, fName))

proc parseAlloc*(ctx: var TransContext, n: JsonNode) =
  for accAddr, acc in n:
    let address = hexToByteArray[20](accAddr)
    var ga = GenesisAccount()
    if acc.hasKey("code"):
      ga.code = Blob.fromJson(acc, "code")
    if acc.hasKey("nonce"):
      ga.nonce = AccountNonce.fromJson(acc, "nonce")
    if acc.hasKey("balance"):
      ga.balance = UInt256.fromJson(acc, "balance")
    else:
      raise newError(ErrorJson, "GenesisAlloc: balance required")
    if acc.hasKey("storage"):
      let storage = acc["storage"]
      for k, v in storage:
        ga.storage[UInt256.fromHex(k)] = UInt256.fromHex(v.getStr())
    ctx.alloc[address] = ga

proc parseEnv*(ctx: var TransContext, n: JsonNode) =
  required(ctx.env, EthAddress, currentCoinbase)
  required(ctx.env, GasInt, currentGasLimit)
  required(ctx.env, BlockNumber, currentNumber)
  required(ctx.env, EthTime, currentTimestamp)
  optional(ctx.env, DifficultyInt, currentDifficulty)
  optional(ctx.env, Hash256, currentRandom)
  optional(ctx.env, DifficultyInt, parentDifficulty)
  omitZero(ctx.env, EthTime, parentTimestamp)
  optional(ctx.env, UInt256, currentBaseFee)
  omitZero(ctx.env, Hash256, parentUncleHash)

  if n.hasKey("blockHashes"):
    let w = n["blockHashes"]
    for k, v in w:
      ctx.env.blockHashes[fromHex[uint64](k)] = Hash256.fromHex(v.getStr())

  if n.hasKey("ommers"):
    let w = n["ommers"]
    for v in w:
      ctx.env.ommers.add Ommer.fromJson(v)

proc parseTx(n: JsonNode, chainId: ChainID): Transaction =
  var tx: Transaction
  if not n.hasKey("type"):
    tx.txType = TxLegacy
  else:
    tx.txType = int64.fromJson(n, "type").TxType

  required(tx, AccountNonce, nonce)
  required(tx, GasInt, gas)
  required(tx, UInt256, value)
  required(tx, Blob, input)
  required(tx, int64, v)
  required(tx, UInt256, r)
  required(tx, UInt256, s)

  if n.hasKey("to"):
    tx.to = some(EthAddress.fromJson(n, "to"))

  case tx.txType
  of TxLegacy:
    required(tx, GasInt, gasPrice)
  of TxEip2930:
    required(tx, GasInt, gasPrice)
    required(tx, ChainId, chainId)
    omitZero(tx, AccessList, accessList)
  of TxEip1559:
    required(tx, ChainId, chainId)
    required(tx, GasInt, maxPriorityFeePerGas)
    required(tx, GasInt, maxFeePerGas)
    omitZero(tx, AccessList, accessList)

  var eip155 = true
  if n.hasKey("protected"):
    eip155 = n["protected"].bval

  if n.hasKey("secretKey"):
    let data = Blob.fromJson(n, "secretKey")
    let secretKey = PrivateKey.fromRaw(data).tryGet
    signTransaction(tx, secretKey, chainId, eip155)
  else:
    tx

proc parseTxs*(ctx: var TransContext, txs: JsonNode, chainId: ChainID) =
  if txs.kind == JNull:
    return
  if txs.kind != JArray:
    raise newError(ErrorJson, "Transaction list should be a JSON array, got=" & $txs.kind)
  for n in txs:
    ctx.txs.add parseTx(n, chainId)

proc parseTxsRlp*(ctx: var TransContext, hexData: string) =
  let data = hexToSeqByte(hexData)
  ctx.txs = rlp.decode(data, seq[Transaction])

proc parseInputFromStdin*(ctx: var TransContext, chainConfig: ChainConfig) =
  let data = stdin.readAll()
  let n = json.parseJson(data)
  if n.hasKey("alloc"): ctx.parseAlloc(n["alloc"])
  if n.hasKey("env"): ctx.parseEnv(n["env"])
  if n.hasKey("txs"): ctx.parseTxs(n["txs"], chainConfig.chainId)
  if n.hasKey("txsRlp"): ctx.parseTxsRlp(n["txsRlp"].getStr())

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

proc `@@`(x: Hash256): JsonNode =
  %("0x" & x.data.toHex)

proc `@@`*(x: Blob): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: bool): JsonNode =
  %(if x: "0x1" else: "0x0")

proc `@@`(x: EthAddress): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: Topic): JsonNode =
  %("0x" & x.toHex)

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

proc `@@`(x: BloomFilter): JsonNode =
  %("0x" & toHex[256](x))

proc `@@`(x: Log): JsonNode =
  result = %{
    "address": @@(x.address),
    "topics" : @@(x.topics),
    "data"   : @@(x.data)
  }

proc `@@`(x: TxReceipt): JsonNode =
  result = %{
    "root"             : if x.root == Hash256(): %("0x") else: @@(x.root),
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
  result = %{
    "index": %(x.index),
    "error": %(x.error)
  }

proc `@@`[T](x: seq[T]): JsonNode =
  result = newJArray()
  for c in x:
    result.add @@(c)

proc `@@`[T](x: Option[T]): JsonNode =
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
    "logsBloom"   : @@(x.bloom),
    "receipts"    : @@(x.receipts),
    "currentDifficulty": @@(x.currentDifficulty),
    "gasUsed"     : @@(x.gasUsed)
  }
  if x.rejected.len > 0:
    result["rejected"] = @@(x.rejected)
