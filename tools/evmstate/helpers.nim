# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils],
  eth/common/[base, keys, headers, transactions],
  stint,
  stew/byteutils,
  ../../execution_chain/transaction,
  ../../execution_chain/db/ledger,
  ../../execution_chain/common/chain_config

template fromJson(T: type Address, n: JsonNode): Address =
  Address.fromHex(n.getStr)

proc fromJson(T: type UInt256, n: JsonNode): UInt256 =
  # stTransactionTest/ValueOverflow.json
  # prevent parsing exception and subtitute it with max uint256
  let hex = n.getStr
  if ':' in hex:
    high(UInt256)
  else:
    UInt256.fromHex(hex)

template fromJson*(T: type Bytes32, n: JsonNode): Bytes32 =
  Bytes32(hexToByteArray(n.getStr, 32))

template fromJson*(T: type Hash32, n: JsonNode): Hash32 =
  Hash32(hexToByteArray(n.getStr, 32))

proc fromJson(T: type seq[byte], n: JsonNode): T =
  let hex = n.getStr
  if hex.len == 0:
    @[]
  else:
    hexToSeqByte(hex)

template fromJson(T: type uint64, n: JsonNode): uint64 =
  fromHex[AccountNonce](n.getStr)

template fromJson(T: type EthTime, n: JsonNode): EthTime =
  EthTime(fromHex[uint64](n.getStr))

template fromJson(T: type ChainId, n: JsonNode): ChainId =
  ChainId(fromHex[uint64](n.getStr))

proc fromJson(T: type PrivateKey, n: JsonNode): PrivateKey =
  var secretKey = n.getStr
  removePrefix(secretKey, "0x")
  PrivateKey.fromHex(secretKey).tryGet()

proc fromJson(T: type transactions.AccessList, n: JsonNode): transactions.AccessList =
  if n.kind == JNull:
    return

  for x in n:
    var ap = AccessPair(
      address: Address.fromJson(x["address"])
    )
    let sks = x["storageKeys"]
    for sk in sks:
      ap.storageKeys.add Bytes32.fromHex(sk.getStr)
    result.add ap

proc fromJson(T: type seq[Hash32], list: JsonNode): T =
  for x in list:
    result.add Hash32.fromHex(x.getStr)

template required(T: type, nField: string): auto =
  fromJson(T, n[nField])

template required(T: type, nField: string, index: int): auto =
  fromJson(T, n[nField][index])

template defaultZero(T: type, nField: string): auto =
  if n.hasKey(nField):
    fromJson(T, n[nField])
  else:
    default(T)

template defaultZero(T: type, nField: string, index: int): auto =
  if n.hasKey(nField):
    fromJson(T, n[nField][index])
  else:
    default(T)

template optional(T: type, nField: string): auto =
  if n.hasKey(nField):
    Opt.some(T.fromJson(n[nField]))
  else:
    Opt.none(T)

proc fromJson(T: type Authorization, n: JsonNode): Authorization =
  Authorization(
    chainId: required(ChainId, "chainId"),
    address: required(Address, "address"),
    nonce: required(AccountNonce, "nonce"),
    v: required(uint64, "v"),
    r: required(UInt256, "r"),
    s: required(UInt256, "s"),
  )

proc fromJson(T: type seq[Authorization], list: JsonNode): T =
  for x in list:
    result.add Authorization.fromJson(x)

proc txType(n: JsonNode): TxType =
  if "authorizationList" in n:
    return TxEip7702
  if "blobVersionedHashes" in n:
    return TxEip4844
  if "gasPrice" notin n:
    return TxEip1559
  if "accessLists" in n:
    return TxEip2930
  TxLegacy

proc parseHeader*(n: JsonNode): Header =
  Header(
    coinbase   : required(Address, "currentCoinbase"),
    difficulty : required(DifficultyInt, "currentDifficulty"),
    number     : required(BlockNumber, "currentNumber"),
    gasLimit   : required(GasInt, "currentGasLimit"),
    timestamp  : required(EthTime, "currentTimestamp"),
    stateRoot  : emptyRoot,
    mixHash    : defaultZero(Bytes32, "currentRandom"),
    baseFeePerGas  : optional(UInt256, "currentBaseFee"),
    withdrawalsRoot: optional(Hash32, "currentWithdrawalsRoot"),
    excessBlobGas  : optional(uint64, "currentExcessBlobGas"),
    parentBeaconBlockRoot: optional(Hash32, "currentBeaconRoot"),
  )

proc parseParentHeader*(n: JsonNode): Header =
  Header(
    stateRoot: emptyRoot,
    excessBlobGas: optional(uint64, "parentExcessBlobGas"),
    blobGasUsed: optional(uint64, "parentBlobGasUsed"),
  )

proc parseTx*(n: JsonNode, dataIndex, gasIndex, valueIndex: int): Transaction =
  var tx = Transaction(
    txType  : txType(n),
    nonce   : required(AccountNonce, "nonce"),
    gasLimit: required(GasInt, "gasLimit", gasIndex),
    value   : required(UInt256, "value", valueIndex),
    payload : required(seq[byte], "data", dataIndex),
    chainId : ChainId(1),
    gasPrice: defaultZero(GasInt, "gasPrice"),
    maxFeePerGas        : defaultZero(GasInt, "maxFeePerGas"),
    accessList          : defaultZero(AccessList, "accessLists", dataIndex),
    maxPriorityFeePerGas: defaultZero(GasInt, "maxPriorityFeePerGas"),
    maxFeePerBlobGas    : defaultZero(UInt256, "maxFeePerBlobGas"),
    versionedHashes     : defaultZero(seq[Hash32], "blobVersionedHashes"),
    authorizationList   : defaultZero(seq[Authorization], "authorizationList"),
  )

  let rawTo = n["to"].getStr
  if rawTo != "":
    tx.to = Opt.some(Address.fromHex(rawTo))

  let secretKey = required(PrivateKey, "secretKey")
  signTransaction(tx, secretKey, false)

proc parseTx*(txData, index: JsonNode): Transaction =
  let
    dataIndex = index["data"].getInt
    gasIndex  = index["gas"].getInt
    valIndex  = index["value"].getInt
  parseTx(txData, dataIndex, gasIndex, valIndex)

proc setupLedger*(wantedState: JsonNode, ledger: LedgerRef) =
  for ac, accountData in wantedState:
    let account = Address.fromHex(ac)
    for slot, value in accountData{"storage"}:
      ledger.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    ledger.setNonce(account, fromJson(AccountNonce, accountData["nonce"]))
    ledger.setCode(account, fromJson(seq[byte], accountData["code"]))
    ledger.setBalance(account, fromJson(UInt256, accountData["balance"]))

iterator postState*(node: JsonNode): (Address, GenesisAccount) =
  for ac, accountData in node:
    let account = Address.fromHex(ac)
    var ga = GenesisAccount(
      nonce  : fromJson(AccountNonce, accountData["nonce"]),
      code   : fromJson(seq[byte], accountData["code"]),
      balance: fromJson(UInt256, accountData["balance"]),
    )

    for slot, value in accountData{"storage"}:
      ga.storage[fromHex(UInt256, slot)] = fromHex(UInt256, value.getStr)

    yield (account, ga)
