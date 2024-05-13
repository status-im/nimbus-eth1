# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, options, os, strutils, typetraits],
  eth/common, httputils, nimcrypto/utils,
  results, stint, stew/byteutils

import ../nimbus/transaction, ../nimbus/utils/ec_recover

from stew/objects import checkedEnumAssign

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

func encodeQuantity(value: SomeUnsignedInt): string =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue.toLowerAscii

func hexToInt*(s: string, T: typedesc[SomeInteger]): T =
  var i = 0
  if s[i] == '0' and (s[i+1] in {'x', 'X'}): inc(i, 2)
  if s.len - i > sizeof(T) * 2:
    raise newException(ValueError, "input hex too big for destination int")
  while i < s.len:
    result = result shl 4 or readHexChar(s[i]).T
    inc(i)

proc prefixHex*(x: Hash256): string =
  "0x" & toLowerAscii($x)

proc prefixHex*(x: int64 | uint64 | byte | int): string =
  toLowerAscii(encodeQuantity(x.uint64))

proc prefixHex*(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc prefixHex*(x: UInt256): string =
  "0x" & stint.toHex(x)

proc prefixHex*(x: string): string =
  "0x" & toLowerAscii(x)

type
  SomeData* = EthAddress | BloomFilter | BlockNonce

proc fromJson*(n: JsonNode, name: string, x: var SomeData) =
  let node = n[name]
  if node.kind == JString:
    hexToByteArray(node.getStr(), x)
    doAssert(x.prefixHex == toLowerAscii(node.getStr()), name)
  else:
    hexToByteArray(node["value"].getStr(), x)
    doAssert(x.prefixHex == toLowerAscii(node["value"].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var Hash256) =
  let node = n[name]
  if node.kind == JString:
    hexToByteArray(node.getStr(), x.data)
    doAssert(x.prefixHex == toLowerAscii(node.getStr()), name)
  else:
    hexToByteArray(node["value"].getStr(), x.data)
    doAssert(x.prefixHex == toLowerAscii(node["value"].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var Blob) =
  x = hexToSeqByte(n[name].getStr())
  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var UInt256) =
  let node = n[name]
  if node.kind == JString:
    x = UInt256.fromHex(node.getStr())
    doAssert(x.prefixHex == toLowerAscii(node.getStr()), name)
  else:
    x = node.getInt().u256
    doAssert($x == $node.getInt, name)

proc fromJson*(n: JsonNode, name: string, x: var SomeInteger) =
  let node = n[name]
  if node.kind == JString:
    x = hexToInt(node.getStr(), type(x))
    doAssert(x.prefixHex == toLowerAscii(node.getStr()), name)
  else:
    type T = type x
    x = T(node.getInt)
    doAssert($x == $node.getInt, name)

func fromJson(n: JsonNode, name: string, x: var ChainId) =
  n.fromJson(name, distinctBase(x))

proc fromJson*(n: JsonNode, name: string, x: var EthTime) =
  x = EthTime(hexToInt(n[name].getStr(), uint64))
  doAssert(x.uint64.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*[T](n: JsonNode, name: string, x: var Option[T]) =
  if name in n and n[name].kind != JNull:
    var val: T
    n.fromJson(name, val)
    x = options.some(val)
  else:
    x = options.none(T)

func fromJson*[T](n: JsonNode, name: string, x: var Opt[T]) =
  if name in n and n[name].kind != JNull:
    var val: T
    n.fromJson(name, val)
    x.ok val
  else:
    x.err()

func fromJson*[E, N](n: JsonNode, name: string, x: var List[E, N]) =
  var v: seq[E]
  n.fromJson(name, v)
  if v.len > N:
    raise (ref ValueError)(msg:
      "List[" & $E & ", Limit " & $N & "] cannot fit " & $v.len & " items")
  x = List[E, N].init(v)

proc fromJson*(n: JsonNode, name: string, x: var TxType) =
  let node = n[name]
  if node.kind == JInt:
    x = TxType(node.getInt)
  else:
    x = hexToInt(node.getStr(), int).TxType

proc fromJson*(n: JsonNode, name: string, x: var seq[Hash256]) =
  let node = n[name]
  var h: Hash256
  x = newSeqOfCap[Hash256](node.len)
  for v in node:
    hexToByteArray(v.getStr(), h.data)
    x.add h

func fromJson*(n: JsonNode, name: string, x: var common.AccessList) =
  x.reset()
  let node = n[name]
  for innerNode in node:
    var entry: common.AccessPair
    innerNode.fromJson "address", entry.address
    for storageKeyVal in innerNode["storageKeys"]:
      var storageKey: common.StorageKey
      hexToByteArray(storageKeyVal.getStr(), storageKey)
      if not entry.storage_keys.add storageKey:
        raise (ref ValueError)(msg: "StorageKeys capacity exceeded")
    if not x.add entry:
      raise (ref ValueError)(msg: "AccessList capacity exceeded")

proc parseBlockHeader*(n: JsonNode): BlockHeader =
  n.fromJson "parentHash", result.parentHash
  n.fromJson "sha3Uncles", result.ommersHash
  n.fromJson "miner", result.coinbase
  n.fromJson "stateRoot", result.stateRoot
  n.fromJson "transactionsRoot", result.txRoot
  n.fromJson "receiptsRoot", result.receiptRoot
  n.fromJson "logsBloom", result.bloom
  n.fromJson "difficulty", result.difficulty
  n.fromJson "number", result.blockNumber
  n.fromJson "gasLimit", result.gasLimit
  n.fromJson "gasUsed", result.gasUsed
  n.fromJson "timestamp", result.timestamp
  n.fromJson "extraData", result.extraData
  n.fromJson "mixHash", result.mixDigest
  n.fromJson "nonce", result.nonce
  n.fromJson "baseFeePerGas", result.fee
  n.fromJson "withdrawalsRoot", result.withdrawalsRoot
  n.fromJson "blobGasUsed", result.blobGasUsed
  n.fromJson "excessBlobGas", result.excessBlobGas
  n.fromJson "parentBeaconBlockRoot", result.parentBeaconBlockRoot

  if result.baseFee == 0.u256:
    # probably geth bug
    result.fee = none(UInt256)

proc parseTransaction*(n: JsonNode, chain_id: ChainId): Transaction =
  var
    tx: TransactionPayload
    gasPrice: Opt[UInt256]
    txChainId: Opt[ChainId]
    v: UInt256
    r: UInt256
    s: UInt256
  n.fromJson "nonce", tx.nonce
  n.fromJson "gasPrice", gasPrice
  n.fromJson "gas", tx.gas
  n.fromJson "to", tx.to
  n.fromJson "value", tx.value
  n.fromJson "input", tx.input
  n.fromJson "v", v
  n.fromJson "r", r
  n.fromJson "s", s
  n.fromJson "chainId", txChainId
  n.fromJson "type", tx.tx_type
  n.fromJson "accessList", tx.access_list
  n.fromJson "maxPriorityFeePerGas", tx.max_priority_fee_per_gas
  n.fromJson "maxFeePerGas", tx.max_fee_per_gas
  n.fromJson "maxFeePerBlobGas", tx.max_fee_per_blob_gas
  n.fromJson "versionedHashes", tx.blob_versioned_hashes
  if gasPrice.get(tx.max_fee_per_gas) != tx.max_fee_per_gas:
    raise (ref ValueError)(msg: "`gasPrice` and `maxFeePerGas` don't match")
  if tx.tx_type.get(TxLegacy) != TxLegacy and txChainId.isNone:
    raise (ref ValueError)(msg: "`chainId` is required")
  if tx.tx_type == Opt.some(TxLegacy) and txChainId.isNone:
    tx.tx_type.reset()
  if txChainId.get(chain_id) != chain_id:
    raise (ref ValueError)(msg: "Unsupported `chainId`")
  if r >= SECP256K1N:
    raise (ref ValueError)(msg: "Invalid `r`")
  if s < UInt256.one or s >= SECP256K1N:
    raise (ref ValueError)(msg: "Invalid `s`")
  let anyTx = AnyTransactionPayload.fromOneOfBase(tx).valueOr:
    raise (ref ValueError)(msg: "Invalid combination of fields")
  withTxPayloadVariant(anyTx):
    let y_parity =
      when txKind == TransactionKind.Replayable:
        if v == 27.u256:
          false
        elif v == 28.u256:
          true
        else:
          raise (ref ValueError)(msg: "Invalid `v`")
      elif txKind == TransactionKind.Legacy:
        let
          res = v.isEven
          expected_v =
            distinctBase(chain_id).u256 * 2 + (if res: 36.u256 else: 35.u256)
        if v != expected_v:
          raise (ref ValueError)(msg: "Invalid `v`")
        res
      else:
        if v > UInt256.one:
          raise (ref ValueError)(msg: "Invalid `v`")
        v.isOdd
    var signature: TransactionSignature
    signature.ecdsa_signature = ecdsa_pack_signature(y_parity, r, s)
    signature.from_address = ecdsa_recover_from_address(
        signature.ecdsa_signature,
        txPayloadVariant.compute_sig_hash(chain_id)).valueOr:
      raise (ref ValueError)(msg: "Cannot compute `from` address")
    Transaction(payload: tx, signature: signature)

proc parseWithdrawal*(n: JsonNode): Withdrawal =
  n.fromJson "index", result.index
  n.fromJson "validatorIndex", result.validatorIndex
  n.fromJson "address", result.address
  n.fromJson "amount", result.amount

proc validateTxSenderAndHash*(n: JsonNode, tx: Transaction) =
  var sender = tx.getSender()
  var fromAddr: EthAddress
  n.fromJson "from", fromAddr
  doAssert sender.prefixHex == fromAddr.prefixHex
  doAssert n["hash"].getStr() == tx.rlpHash().prefixHex

proc parseLog(n: JsonNode): Log =
  n.fromJson "address", result.address
  n.fromJson "data", result.data
  let topics = n["topics"]
  result.topics = newSeqOfCap[Topic](n.len)
  var topicHash: Topic
  for tp in topics:
    hexToByteArray(tp.getStr(), topicHash)
    result.topics.add topicHash

proc parseLogs(n: JsonNode): seq[Log] =
  if n.len > 0:
    result = newSeqOfCap[Log](n.len)
    for log in n:
      result.add parseLog(log)
  else:
    result = @[]

proc parseReceipt*(n: JsonNode): Receipt =
  var recType: byte
  n.fromJson "type", recType
  var txVal: ReceiptType
  var rec =
    if checkedEnumAssign(txVal, recType):
      Receipt(receiptType: txVal)
    else:
      raise newException(ValueError, "Unknown receipt type")

  if n.hasKey("root"):
    var hash: Hash256
    n.fromJson "root", hash
    rec.isHash = true
    rec.hash = hash
  else:
    var status: int
    n.fromJson "status", status
    rec.isHash = false
    rec.status = status == 1

  n.fromJson "cumulativeGasUsed", rec.cumulativeGasUsed
  n.fromJson "logsBloom", rec.bloom
  rec.logs = parseLogs(n["logs"])
  rec

proc headerHash*(n: JsonNode): Hash256 =
  n.fromJson "hash", result

proc parseAccount*(n: JsonNode): Account =
  n.fromJson "nonce", result.nonce
  n.fromJson "balance", result.balance
  n.fromJson "storageRoot", result.storageRoot
  n.fromJson "codeHash", result.codeHash
