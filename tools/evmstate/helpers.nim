# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, json, strutils],
  eth/[common, keys],
  eth/trie/trie_defs,
  stint,
  stew/byteutils,
  ../../nimbus/transaction,
  ../../nimbus/db/accounts_cache,
  ../../nimbus/common/chain_config

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

proc fromJson(T: type VersionedHashes, list: JsonNode): VersionedHashes =
  for x in list:
    result.add Hash256.fromJson(x)

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
  if "blobVersionedHashes" in n:
    return TxEip4844
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
    fee        : optional(UInt256, "currentBaseFee"),
    excessBlobGas: optional(uint64, "excessBlobGas"),
    blobGasUsed: optional(uint64, "blobGasUsed")
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
    maxPriorityFee: omitZero(GasInt, "maxPriorityFeePerGas"),
    maxFeePerBlobGas: omitZero(GasInt, "maxFeePerBlobGas"),
    versionedHashes: omitZero(VersionedHashes, "blobVersionedHashes")
  )

  let rawTo = n["to"].getStr
  if rawTo != "":
    tx.to = some(hexToByteArray(rawTo, 20))

  let secretKey = required(PrivateKey, "secretKey")
  signTransaction(tx, secretKey, tx.chainId, false)

proc parseTx*(txData, index: JsonNode): Transaction =
  let
    dataIndex = index["data"].getInt
    gasIndex  = index["gas"].getInt
    valIndex  = index["value"].getInt
  parseTx(txData, dataIndex, gasIndex, valIndex)

proc setupStateDB*(wantedState: JsonNode, stateDB: AccountsCache) =
  for ac, accountData in wantedState:
    let account = hexToByteArray[20](ac)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    stateDB.setNonce(account, fromJson(AccountNonce, accountData["nonce"]))
    stateDB.setCode(account, fromJson(Blob, accountData["code"]))
    stateDB.setBalance(account, fromJson(UInt256, accountData["balance"]))

iterator postState*(node: JsonNode): (EthAddress, GenesisAccount) =
  for ac, accountData in node:
    let account = hexToByteArray[20](ac)
    var ga = GenesisAccount(
      nonce  : fromJson(AccountNonce, accountData["nonce"]),
      code   : fromJson(Blob, accountData["code"]),
      balance: fromJson(UInt256, accountData["balance"]),
    )

    for slot, value in accountData{"storage"}:
      ga.storage[fromHex(UInt256, slot)] = fromHex(UInt256, value.getStr)

    yield (account, ga)
