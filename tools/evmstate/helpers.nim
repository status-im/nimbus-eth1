import
  std/[options, json, strutils],
  eth/[common, keys],
  eth/trie/trie_defs,
  stint,
  stew/byteutils,
  ../../nimbus/[transaction, forks],
  ../../nimbus/db/accounts_cache

template fromJson(T: type EthAddress, n: JsonNode): EthAddress =
  hexToByteArray(n.getStr, sizeof(T))

proc fromJson(T: type UInt256, n: JsonNode): UInt256 =
  # stTransactionTest/ValueOverflow.json
  # prevent parsing exception and subtitute it with max uint256
  let hex = n.getStr
  if ':' in hex:
    high(UInt256)
  else:
    UInt256.fromHex(hex)

template fromJson*(T: type Hash256, n: JsonNode): Hash256 =
  Hash256(data: hexToByteArray(n.getStr, 32))

proc fromJson(T: type Blob, n: JsonNode): Blob =
  let hex = n.getStr
  if hex.len == 0:
    @[]
  else:
    hexToSeqByte(hex)

template fromJson(T: type GasInt, n: JsonNode): GasInt =
  fromHex[GasInt](n.getStr)

template fromJson(T: type AccountNonce, n: JsonNode): AccountNonce =
  fromHex[AccountNonce](n.getStr)

template fromJson(T: type EthTime, n: JsonNode): EthTime =
  fromUnix(fromHex[int64](n.getStr))

proc fromJson(T: type PrivateKey, n: JsonNode): PrivateKey =
  var secretKey = n.getStr
  removePrefix(secretKey, "0x")
  PrivateKey.fromHex(secretKey).tryGet()

proc fromJson(T: type AccessList, n: JsonNode): AccessList =
  if n.kind == JNull:
    return

  for x in n:
    var ap = AccessPair(
      address: EthAddress.fromJson(x["address"])
    )
    let sks = x["storageKeys"]
    for sk in sks:
      ap.storageKeys.add hexToByteArray(sk.getStr, 32)
    result.add ap

template required(T: type, nField: string): auto =
  fromJson(T, n[nField])

template required(T: type, nField: string, index: int): auto =
  fromJson(T, n[nField][index])

template omitZero(T: type, nField: string): auto =
  if n.hasKey(nField):
    fromJson(T, n[nField])
  else:
    default(T)

template omitZero(T: type, nField: string, index: int): auto =
  if n.hasKey(nField):
    fromJson(T, n[nField][index])
  else:
    default(T)

template optional(T: type, nField: string): auto =
  if n.hasKey(nField):
    some(T.fromJson(n[nField]))
  else:
    none(T)

proc txType(n: JsonNode): TxType =
  if "gasPrice" notin n:
    return TxEip1559
  if "accessLists" in n:
    return TxEip2930
  TxLegacy

proc parseHeader*(n: JsonNode): BlockHeader =
  BlockHeader(
    coinbase   : required(EthAddress, "currentCoinbase"),
    difficulty : required(DifficultyInt, "currentDifficulty"),
    blockNumber: required(BlockNumber, "currentNumber"),
    gasLimit   : required(GasInt, "currentGasLimit"),
    timestamp  : required(EthTime, "currentTimestamp"),
    stateRoot  : emptyRlpHash,
    mixDigest  : omitZero(Hash256, "currentRandom"),
    fee        : optional(UInt256, "currentBaseFee")
  )

proc parseTx*(n: JsonNode, dataIndex, gasIndex, valueIndex: int): Transaction =
  var tx = Transaction(
    txType  : txType(n),
    nonce   : required(AccountNonce, "nonce"),
    gasLimit: required(GasInt, "gasLimit", gasIndex),
    value   : required(UInt256, "value", valueIndex),
    payload : required(Blob, "data", dataIndex),
    chainId : ChainId(1),
    gasPrice: omitZero(GasInt, "gasPrice"),
    maxFee  : omitZero(GasInt, "maxFeePerGas"),
    accessList: omitZero(AccessList, "accessLists", dataIndex),
    maxPriorityFee: omitZero(GasInt, "maxPriorityFeePerGas")
  )

  let rawTo = n["to"].getStr
  if rawTo != "":
    tx.to = some(hexToByteArray(rawTo, 20))

  let secretKey = required(PrivateKey, "secretKey")
  signTransaction(tx, secretKey, tx.chainId, false)

proc setupStateDB*(wantedState: JsonNode, stateDB: AccountsCache) =
  for ac, accountData in wantedState:
    let account = hexToByteArray[20](ac)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    stateDB.setNonce(account, fromJson(AccountNonce, accountData["nonce"]))
    stateDB.setCode(account, fromJson(Blob, accountData["code"]))
    stateDB.setBalance(account, fromJson(UInt256, accountData["balance"]))

proc parseFork*(x: string): Option[Fork] =
  case x
  of "Frontier"         : some(FkFrontier)
  of "Homestead"        : some(FkHomestead)
  of "EIP150"           : some(FkTangerine)
  of "EIP158"           : some(FkSpurious)
  of "Byzantium"        : some(FkByzantium)
  of "Constantinople"   : some(FkConstantinople)
  of "ConstantinopleFix": some(FkPetersburg)
  of "Istanbul"         : some(FkIstanbul)
  of "Berlin"           : some(FkBerlin)
  of "London"           : some(FkLondon)
  of "Merge"            : some(FkParis)
  of "Shanghai"         : some(FkShanghai)
  of "Cancun"           : some(FkCancun)
  else: none(Fork)

proc toString*(x: Fork): string =
  case x
  of FkFrontier      : "Frontier"
  of FkHomestead     : "Homestead"
  of FkTangerine     : "EIP150"
  of FkSpurious      : "EIP158"
  of FkByzantium     : "Byzantium"
  of FkConstantinople: "Constantinople"
  of FkPetersburg    : "ConstantinopleFix"
  of FkIstanbul      : "Istanbul"
  of FkBerlin        : "Berlin"
  of FkLondon        : "London"
  of FkParis         : "Merge"
  of FkShanghai      : "Shanghai"
  of FkCancun        : "Cancun"
