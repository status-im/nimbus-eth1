import
  json, strutils, times, options, os,
  eth/[rlp, common], httputils, nimcrypto, chronicles,
  stint, stew/byteutils

import ../nimbus/transaction
from ../nimbus/rpc/hexstrings import encodeQuantity

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
  toLowerAscii(encodeQuantity(x.uint64).string)

proc prefixHex*(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc prefixHex*(x: UInt256): string =
  "0x" & stint.toHex(x)

proc prefixHex*(x: string): string =
  "0x" & toLowerAscii(x)

type
  SomeData* = EthAddress | BloomFilter | BlockNonce

proc fromJson*(n: JsonNode, name: string, x: var SomeData) =
  hexToByteArray(n[name].getStr(), x)
  if x.prefixHex != toLowerAscii(n[name].getStr()):
    debugEcho "name: ", name
    debugEcho "A: ", x.prefixHex
    debugEcho "B: ", toLowerAscii(n[name].getStr())
    quit(1)

  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var Hash256) =
  hexToByteArray(n[name].getStr(), x.data)
  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var Blob) =
  x = hexToSeqByte(n[name].getStr())
  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var UInt256) =
  x = UInt256.fromHex(n[name].getStr())
  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var SomeInteger) =
  x = hexToInt(n[name].getStr(), type(x))
  doAssert(x.prefixHex == toLowerAscii(n[name].getStr()), name)

proc fromJson*(n: JsonNode, name: string, x: var EthTime) =
  x = initTime(hexToInt(n[name].getStr(), int64), 0)
  doAssert(x.toUnix.prefixHex == toLowerAscii(n[name].getStr()), name)

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

proc parseTransaction*(n: JsonNode): Transaction =
  var tx: LegacyTx
  n.fromJson "nonce", tx.nonce
  n.fromJson "gasPrice", tx.gasPrice
  n.fromJson "gas", tx.gasLimit

  tx.isContractCreation = n["to"].kind == JNull
  if not tx.isContractCreation:
    n.fromJson "to", tx.to

  n.fromJson "value", tx.value
  n.fromJson "input", tx.payload
  n.fromJson "v", tx.V
  n.fromJson "r", tx.R
  n.fromJson "s", tx.S

  var sender = tx.getSender()
  doAssert sender.prefixHex == n["from"].getStr()
  doAssert n["hash"].getStr() == tx.rlpHash().prefixHex
  result = Transaction(txType: LegacyTxType, legacyTx: tx)

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
  var rec: LegacyReceipt
  if n.hasKey("root"):
    var hash: Hash256
    n.fromJson "root", hash
    rec.stateRootOrStatus = hashOrStatus(hash)
  else:
    var status: int
    n.fromJson "status", status
    rec.stateRootOrStatus = hashOrStatus(status == 1)

  n.fromJson "cumulativeGasUsed", rec.cumulativeGasUsed
  n.fromJson "logsBloom", rec.bloom
  rec.logs = parseLogs(n["logs"])
  Receipt(receiptType: LegacyReceiptType, legacyReceipt: rec)

proc headerHash*(n: JsonNode): Hash256 =
  n.fromJson "hash", result

proc parseAccount*(n: JsonNode): Account =
  n.fromJson "nonce", result.nonce
  n.fromJson "balance", result.balance
  n.fromJson "storageRoot", result.storageRoot
  n.fromJson "codeHash", result.codeHash
