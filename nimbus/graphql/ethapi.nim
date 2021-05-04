# nim-graphql
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils, times],
  stew/[results, byteutils], stint,
  eth/[common, rlp], chronos,
  graphql, graphql/graphql as context,
  graphql/common/types, graphql/httpserver,
  ../db/[db_chain, state_db], ../errors, ../utils,
  ../transaction, ../rpc/rpc_utils, ../vm_state, ../config,
  ../vm_computation, ../vm_state_transactions,
  ../transaction/call_evm

from eth/p2p import EthereumNode
export httpserver

type
  EthTypes = enum
    ethAccount      = "Account"
    ethLog          = "Log"
    ethTransaction  = "Transaction"
    ethBlock        = "Block"
    ethCallResult   = "CallResult"
    ethSyncState    = "SyncState"
    ethPending      = "Pending"
    ethQuery        = "Query"
    ethMutation     = "Mutation"

  HeaderNode = ref object
    node: NodeObj
    header: BlockHeader

  AccountNode = ref object
    node: NodeObj
    address: EthAddress
    account: Account
    db: ReadOnlyStateDB

  TxNode = ref object
    node: NodeObj
    tx: Transaction
    index: int
    blockNumber: BlockNumber
    receipt: Receipt
    gasUsed: GasInt

  LogNode = ref object
    node: NodeObj
    log: Log
    index: int
    tx: TxNode

  GraphqlContextRef = ref GraphqlContextObj
  GraphqlContextObj = object of Graphql
    ids: array[EthTypes, Name]
    chainDB: BaseChainDB
    ethNode: EthereumNode

proc toHash(n: Node): Hash256 =
  result.data = hexToByteArray[32](n.stringVal)

proc toBlockNumber(n: Node): BlockNumber =
  result = parse(n.intVal, UInt256, radix = 10)

proc headerNode(ctx: GraphqlContextRef, header: BlockHeader): Node =
  let n = HeaderNode(
    node: NodeObj(
      kind: nkMap,
      typeName: ctx.ids[ethBlock],
      pos: Pos()
    ),
    header: header
  )
  cast[Node](n)

proc headerNode(n: Node): HeaderNode =
  cast[HeaderNode](n)

proc accountNode(ctx: GraphqlContextRef, acc: Account, address: EthAddress, db: ReadOnlyStateDB): Node =
  let n = AccountNode(
    node: NodeObj(
      kind: nkMap,
      typeName: ctx.ids[ethAccount],
      pos: Pos()
    ),
    account: acc,
    address: address,
    db: db
  )
  cast[Node](n)

proc accountNode(n: Node): AccountNode =
  cast[AccountNode](n)

proc txNode(ctx: GraphqlContextRef, tx: Transaction, index: int, blockNumber: BlockNumber): Node =
  let n = TxNode(
    node: NodeObj(
      kind: nkMap,
      typeName: ctx.ids[ethTransaction],
      pos: Pos()
    ),
    tx: tx,
    index: index,
    blockNumber: blockNumber
  )
  cast[Node](n)

proc txNode(n: Node): TxNode =
  cast[TxNode](n)

proc logNode(ctx: GraphqlContextRef, log: Log, index: int, tx: TxNode): Node =
  let n = LogNode(
    node: NodeObj(
      kind: nkMap,
      typeName: ctx.ids[ethLog],
      pos: Pos()
    ),
    log: log,
    index: index,
    tx: tx
  )
  cast[Node](n)

proc logNode(n: Node): LogNode =
  cast[LogNode](n)

proc getAccountDb(chainDB: BaseChainDB, header: BlockHeader): ReadOnlyStateDB =
  ## Retrieves the account db from canonical head
  ## we don't use accounst_cache here because it's only read operations
  let ac = newAccountStateDB(chainDB.db, header.stateRoot, chainDB.pruneTrie)
  ReadOnlyStateDB(ac)

proc getBlockByNumber(ctx: GraphqlContextRef, number: Node): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, toBlockNumber(number))))
  except EVMError as e:
    err(e.msg)

proc getBlockByNumber(ctx: GraphqlContextRef, number: BlockNumber): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, number)))
  except EVMError as e:
    err(e.msg)

proc getBlockByHash(ctx: GraphqlContextRef, hash: Node): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, toHash(hash))))
  except EVMError as e:
    err(e.msg)

proc getBlockByHash(ctx: GraphqlContextRef, hash: Hash256): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, hash)))
  except EVMError as e:
    err(e.msg)

proc getLatestBlock(ctx: GraphqlContextRef): RespResult =
  try:
    ok(headerNode(ctx, getCanonicalHead(ctx.chainDB)))
  except EVMError as e:
    err("can't get latest block: " & e.msg)

proc getTxCount(ctx: GraphqlContextRef, txRoot: Hash256): RespResult =
  try:
    ok(resp(getTransactionCount(ctx.chainDB, txRoot)))
  except EVMError as e:
    err("can't get txcount: " & e.msg)
  except Exception as em:
    err("can't get txcount: " & em.msg)

proc longNode(val: uint64 | int64): RespResult =
  ok(Node(kind: nkInt, intVal: $val, pos: Pos()))

proc longNode(val: UInt256): RespResult =
  ok(Node(kind: nkInt, intVal: val.toString, pos: Pos()))

proc stripLeadingZeros(x: string): string =
  strip(x, leading = true, trailing = false, chars = {'0'})

proc bigIntNode(val: UInt256): RespResult =
  let hex = stripLeadingZeros(val.toHex)
  ok(Node(kind: nkString, stringVal: "0x" & hex, pos: Pos()))

proc bigIntNode(x: uint64 | int64): RespResult =
  # stdlib toHex is not suitable for hive
  const
    HexChars = "0123456789abcdef"
  var
    n = cast[uint64](x)
    r: array[2*sizeof(uint64), char]
    i = 0
  while n > 0:
    r[i] = HexChars[int(n and 0xF)]
    n = n shr 4
    inc i
  var hex = newString(i+2)
  hex[0] = '0'
  hex[1] = 'x'
  while i > 0:
    hex[hex.len-i] = r[i-1]
    dec i
  ok(Node(kind: nkString, stringVal: hex, pos: Pos()))

proc byte32Node(val: UInt256): RespResult =
  ok(Node(kind: nkString, stringVal: "0x" & val.dumpHex, pos: Pos()))

proc resp(hash: Hash256): RespResult =
  ok(resp("0x" & hash.data.toHex))

proc resp(data: openArray[byte]): RespResult =
  ok(resp("0x" & data.toHex))

proc getTotalDifficulty(ctx: GraphqlContextRef, blockHash: Hash256): RespResult =
  try:
    bigIntNode(getScore(ctx.chainDB, blockHash))
  except EVMError as e:
    err("can't get total difficulty: " & e.msg)

proc getOmmerCount(ctx: GraphqlContextRef, ommersHash: Hash256): RespResult =
  try:
    ok(resp(getUnclesCount(ctx.chainDB, ommersHash)))
  except EVMError as e:
    err("can't get ommers count: " & e.msg)
  except Exception as em:
    err("can't get ommers count: " & em.msg)

proc getOmmers(ctx: GraphqlContextRef, ommersHash: Hash256): RespResult =
  try:
    let uncles = getUncles(ctx.chainDB, ommersHash)
    if uncles.len == 0:
      return ok(respNull())
    var list = respList()
    for n in uncles:
      list.add headerNode(ctx, n)
    ok(list)
  except EVMError as e:
    err("can't get ommers: " & e.msg)

proc getOmmerAt(ctx: GraphqlContextRef, ommersHash: Hash256, index: int): RespResult =
  try:
    let uncles = getUncles(ctx.chainDB, ommersHash)
    if uncles.len == 0:
      return ok(respNull())
    if index < 0 or index >= uncles.len:
      return ok(respNull())
    ok(headerNode(ctx, uncles[index]))
  except EVMError as e:
    err("can't get ommer: " & e.msg)

proc getTxs(ctx: GraphqlContextRef, header: BlockHeader): RespResult =
  try:
    let txCount = getTransactionCount(ctx.chainDB, header.txRoot)
    if txCount == 0:
      return ok(respNull())
    var list = respList()
    var index = 0
    for n in getBlockTransactionData(ctx.chainDB, header.txRoot):
      let tx = rlp.decode(n, Transaction)
      list.add txNode(ctx, tx, index, header.blockNumber)
      inc index

    index = 0
    var prevUsed = 0.GasInt
    for r in getReceipts(ctx.chainDB, header.receiptRoot):
      let tx = txNode(list.sons[index])
      tx.receipt = r
      tx.gasUsed = r.cumulativeGasUsed - prevUsed
      prevUsed = r.cumulativeGasUsed
      inc index

    ok(list)
  except EVMError as e:
    err("can't get transactions: " & e.msg)
  except Exception as em:
    err("can't get transactions: " & em.msg)

proc getTxAt(ctx: GraphqlContextRef, header: BlockHeader, index: int): RespResult =
  try:
    var tx: Transaction
    if getTransaction(ctx.chainDB, header.txRoot, index, tx):
      let txn = txNode(ctx, tx, index, header.blockNumber)

      var i = 0
      var prevUsed = 0.GasInt
      for r in getReceipts(ctx.chainDB, header.receiptRoot):
        if i == index:
          let tx = txNode(txn)
          tx.receipt = r
          tx.gasUsed = r.cumulativeGasUsed - prevUsed
        prevUsed = r.cumulativeGasUsed
        inc i

      ok(txn)
    else:
      ok(respNull())
  except EVMError as e:
    err("can't get transaction by index '$1': $2" % [$index, e.msg])
  except Exception as em:
    err("can't get transaction by index '$1': $2" % [$index, em.msg])

proc getTxByHash(ctx: GraphqlContextRef, hash: Hash256): RespResult =
  try:
    let (blockNumber, index) = getTransactionKey(ctx.chainDB, hash)
    let header = getBlockHeader(ctx.chainDB, blockNumber)
    getTxAt(ctx, header, index)
  except EVMError as e:
    err("can't get transaction by hash '$1': $2" % [hash.data.toHex, e.msg])
  except Exception as em:
    err("can't get transaction by hash '$1': $2" % [hash.data.toHex, em.msg])

proc accountNode(ctx: GraphqlContextRef, header: BlockHeader, address: EthAddress): RespResult =
  let db = getAccountDb(ctx.chainDB, header)
  if not db.accountExists(address):
    return ok(respNull())
  let acc = db.getAccount(address)
  ok(accountNode(ctx, acc, address, db))

proc parseU64(node: Node): uint64 =
  for c in node.intVal:
    result = result * 10 + uint64(c.int - '0'.int)

{.pragma: apiPragma, cdecl, gcsafe, raises: [Defect, CatchableError], locks:0.}
{.push hint[XDeclaredButNotUsed]: off.}

proc validateHex(x: Node, minLen = 0): NodeResult =
  if x.stringVal.len < 2:
    return err("hex is too short")
  if x.stringVal.len != 2 + minLen * 2 and minLen != 0:
    return err("expect hex with len '$1', got '$2'" % [$(2 * minLen + 2), $x.stringVal.len])
  if x.stringVal.len mod 2 != 0:
    return err("hex must have even number of nibbles")
  if x.stringVal[0] != '0' or x.stringVal[1] != 'x':
    return err("hex should be prefixed by '0x'")
  for i in 2..<x.stringVal.len:
    if x.stringVal[i] notin HexDigits:
      return err("invalid chars in hex")
  ok(x)

proc validateFixedLenHex(x: Node, minLen: int, kind: string): NodeResult =
  if x.stringVal.len < 2:
    return err(kind & " hex is too short")

  var prefixLen = 0
  if x.stringVal[0] == '0' and x.stringVal[1] == 'x':
    prefixLen = 2

  let expectedLen = minLen * 2 + prefixLen
  if x.stringVal.len < expectedLen:
    return err("$1 len is too short: expect $2 got $3" %
      [kind, $expectedLen, $x.stringVal.len])

  for i in prefixLen..<x.stringVal.len:
    if x.stringVal[i] notin HexDigits:
      return err("invalid chars in $1 hex" % [kind])

  ok(x)

proc scalarBytes32(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, nosideEffect.} =
  ## Bytes32 is a 32 byte binary string,
  ## represented as 0x-prefixed hexadecimal.
  if node.kind != nkString:
    return err("expect hex string, but got '$1'" % [$node.kind])
  validateFixedLenHex(node, 32, "Bytes32")

proc scalarAddress(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, nosideEffect.} =
  ## Address is a 20 byte Ethereum address,
  ## represented as 0x-prefixed hexadecimal.
  if node.kind != nkString:
    return err("expect hex string, but got '$1'" % [$node.kind])
  validateFixedLenHex(node, 20, "Address")

proc scalarBytes(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, nosideEffect.} =
  ## Bytes is an arbitrary length binary string,
  ## represented as 0x-prefixed hexadecimal.
  ## An empty byte string is represented as '0x'.
  ## Byte strings must have an even number of hexadecimal nybbles.
  if node.kind != nkString:
    return err("expect hex string, but got '$1'" % [$node.kind])
  validateHex(node)

proc scalarBigInt(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, nosideEffect.} =
  ## BigInt is a large integer. Input is accepted as
  ## either a JSON number or as a string.
  ## Strings may be either decimal or 0x-prefixed hexadecimal.
  ## Output values are all 0x-prefixed hexadecimal.
  try:
    if node.kind == nkInt:
      # convert it into hex nkString node
      let val = parse(node.intVal, UInt256, radix = 10)
      ok(Node(kind: nkString, stringVal: "0x" & val.toHex, pos: node.pos))
    elif node.kind == nkString:
      if node.stringVal.len > 2 and node.stringVal[1] == 'x':
        if node.stringVal[0] != '0':
          return err("Big Int hex malformed")
        if node.stringVal.len > 66:
          # 256 bits = 32 bytes = 64 hex nibbles
          # 64 hex nibbles + '0x' prefix = 66 bytes
          return err("Big Int hex should not exceed 66 bytes")
        for i in 2..<node.stringVal.len:
          if node.stringVal[i] notin HexDigits:
            return err("invalid chars in BigInt hex")
        ok(node)
      elif HexDigits in node.stringVal:
        if node.stringVal.len > 64:
          return err("Big Int hex should not exceed 64 bytes")
        for i in 0..<node.stringVal.len:
          if node.stringVal[i] notin HexDigits:
            return err("invalid chars in BigInt hex")
        ok(node)
      else:
        # convert it into hex nkString node
        let val = parse(node.stringVal, UInt256, radix = 10)
        node.stringVal = "0x" & val.toHex
        ok(node)
    else:
      return err("expect hex/dec string or int, but got '$1'" % [$node.kind])
  except CatchableError as e:
    err("scalar BigInt error: " & e.msg)

proc scalarLong(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, nosideEffect.} =
  ## Long is a 64 bit unsigned integer.
  const maxU64 = uint64.high.u256
  try:
    case node.kind
    of nkString:
      if node.stringVal.len > 2 and node.stringVal[1] == 'x':
        let val = parse(node.stringVal, UInt256, radix = 16)
        if val > maxU64:
          return err("long value overflow")
        ok(Node(kind: nkInt, pos: node.pos, intVal: $val))
      else:
        let val = parse(node.stringVal, UInt256, radix = 10)
        if val > maxU64:
          return err("long value overflow")
        ok(Node(kind: nkInt, pos: node.pos, intVal: node.stringVal))
    of nkInt:
      let val = parse(node.intVal, UInt256, radix = 10)
      if val > maxU64:
        return err("long value overflow")
      ok(node)
    else:
      err("expect int, but got '$1'" % [$node.kind])
  except CatchableError as e:
    err("scalar Long error: " & e.msg)

proc accountAddress(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let acc = accountNode(parent)
  resp(acc.address)

proc accountBalance(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let acc = accountNode(parent)
  bigIntNode(acc.account.balance)

proc accountTxCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let acc = accountNode(parent)
  longNode(acc.account.nonce)

proc accountCode(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let acc = accountNode(parent)
  let code = acc.db.getCode(acc.address)
  resp(code)

proc accountStorage(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let acc = accountNode(parent)
  let slot = parse(params[0].val.stringVal, UInt256, radix = 16)
  let (val, _) = acc.db.getStorage(acc.address, slot)
  byte32Node(val)

const accountProcs = {
  "address": accountAddress,
  "balance": accountBalance,
  "transactionCount": accountTxCount,
  "code": accountCode,
  "storage": accountStorage
}

proc logIndex(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let log = logNode(parent)
  ok(resp(log.index))

proc logAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: with block param
  let ctx = GraphqlContextRef(ud)
  let log = logNode(parent)

  let hres = ctx.getBlockByNumber(log.tx.blockNumber)
  if hres.isErr:
    return hres
  let h = headerNode(hres.get())
  ctx.accountNode(h.header, log.log.address)

proc logTopics(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let log = logNode(parent)
  var list = respList()
  for n in log.log.topics:
    list.add resp("0x" & n.toHex)
  ok(list)

proc logData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let log = logNode(parent)
  resp(log.log.data)

proc logTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let log = logNode(parent)
  ok(cast[Node](log.tx))

const logProcs = {
  "account": logAccount,
  "index": logIndex,
  "topics": logTopics,
  "data": logData,
  "transaction": logTransaction
}

proc txHash(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let
    tx = txNode(parent)
    encodedTx = rlp.encode(tx.tx)
    txHash = keccakHash(encodedTx)
  resp(txHash)

proc txNonce(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  longNode(tx.tx.accountNonce)

proc txIndex(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  ok(resp(tx.index))

proc txFrom(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: with block param
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  var sender: EthAddress
  if not getSender(tx.tx, sender):
    return ok(respNull())
  let hres = ctx.getBlockByNumber(tx.blockNumber)
  if hres.isErr:
    return hres
  let h = headerNode(hres.get())
  ctx.accountNode(h.header, sender)

proc txTo(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: with block param
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  if tx.tx.isContractCreation:
    return ok(respNull())
  let hres = ctx.getBlockByNumber(tx.blockNumber)
  if hres.isErr:
    return hres
  let h = headerNode(hres.get())
  ctx.accountNode(h.header, tx.tx.to)

proc txValue(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  bigIntNode(tx.tx.value)

proc txGasPrice(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  bigIntNode(tx.tx.gasPrice)

proc txGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  longNode(tx.tx.gasLimit)

proc txInputData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  resp(tx.tx.payload)

proc txBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  ctx.getBlockByNumber(tx.blockNumber)

proc txStatus(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  if tx.receipt.hasStatus:
    longNode(tx.receipt.status().uint64)
  else:
    ok(respNull())

proc txGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  longNode(tx.gasUsed)

proc txCumulativeGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  longNode(tx.receipt.cumulativeGasUsed)

proc txCreatedContract(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  var sender: EthAddress
  if not getSender(tx.tx, sender):
    return ok(respNull())

  let hres = getBlockByNumber(ctx, tx.blockNumber)
  if hres.isErr:
    return hres
  let h = headerNode(hres.get())
  let db = getAccountDb(ctx.chainDB, h.header)
  let creationNonce = db.getNonce(sender)
  let contractAddress = generateAddress(sender, creationNonce)
  ctx.accountNode(h.header, contractAddress)

proc txLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = txNode(parent)
  var list = respList()
  for i, n in tx.receipt.logs:
    list.add logNode(ctx, n, i, tx)
  ok(list)

const txProcs = {
  "from": txFrom,
  "hash": txHash,
  "nonce": txNonce,
  "index": txIndex,
  "to": txTo,
  "value": txValue,
  "gasPrice": txGasPrice,
  "gas": txGas,
  "inputData": txInputData,
  "block": txBlock,
  "status": txStatus,
  "gasUsed": txGasUsed,
  "cumulativeGasUsed": txCumulativeGasUsed,
  "createdContract": txCreatedContract,
  "logs": txLogs
}

proc blockNumberImpl(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  longNode(h.header.blockNumber)

proc blockHashImpl(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let hash = blockHash(h.header)
  resp(hash)

proc blockParent(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  getBlockByHash(ctx, h.header.parentHash)

proc blockNonce(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  ok(resp("0x" & h.header.nonce.toHex))

proc blockTransactionsRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.txRoot)

proc blockTransactionCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  ctx.getTxCount(h.header.txRoot)

proc blockStateRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.stateRoot)

proc blockReceiptsRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.receiptRoot)

proc blockMiner(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  ctx.accountNode(h.header, h.header.coinbase)

proc blockExtraData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.extraData)

proc blockGasLimit(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  longNode(h.header.gasLimit)

proc blockGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  longNode(h.header.gasUsed)

proc blockTimestamp(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  bigIntNode(h.header.timestamp.toUnix.uint64)

proc blockLogsBloom(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.bloom)

proc blockMixHash(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.mixDigest)

proc blockDifficulty(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  bigIntNode(h.header.difficulty)

proc blockTotalDifficulty(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let hash = blockHash(h.header)
  getTotalDifficulty(ctx, hash)

proc blockOmmerCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  getOmmerCount(ctx, h.header.ommersHash)

proc blockOmmers(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  getOmmers(ctx, h.header.ommersHash)

proc blockOmmerAt(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let index = parseU64(params[0].val)
  getOmmerAt(ctx, h.header.ommersHash, index.int)

proc blockOmmerHash(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  resp(h.header.ommersHash)

proc blockTransactions(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  getTxs(ctx, h.header)

proc blockTransactionAt(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let index = parseU64(params[0].val)
  getTxAt(ctx, h.header, index.int)

proc blockLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc blockAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let address = hexToByteArray[20](params[0].val.stringVal)
  ctx.accountNode(h.header, address)

proc toCallData(n: Node): (RpcCallData, bool) =
  # phew, probably need to use macro here :)
  var cd: RpcCallData
  var gasLimit = false
  if n[0][1].kind != nkEmpty:
    cd.source = hextoByteArray[20](n[0][1].stringVal)

  if n[1][1].kind != nkEmpty:
    cd.to = hextoByteArray[20](n[1][1].stringVal)
  else:
    cd.contractCreation = true

  if n[2][1].kind != nkEmpty:
    cd.gas = parseU64(n[2][1]).GasInt
    gasLimit = true
  else:
    # TODO: this is globalGasCap in geth
    cd.gas = GasInt(high(uint64) div 2)

  if n[3][1].kind != nkEmpty:
    let gasPrice = parse(n[3][1].stringVal, UInt256, radix = 16)
    cd.gasPrice = gasPrice.truncate(GasInt)

  if n[4][1].kind != nkEmpty:
    cd.value = parse(n[4][1].stringVal, UInt256, radix = 16)

  if n[5][1].kind != nkEmpty:
    cd.data = hexToSeqByte(n[5][1].stringVal)

  (cd, gasLimit)

proc makeCall(ctx: GraphqlContextRef, callData: RpcCallData,
              header: BlockHeader, chainDB: BaseChainDB): RespResult =
  let (outputHex, gasUsed, isError) = rpcMakeCall(callData, header, chainDB)
  var map = respMap(ctx.ids[ethCallResult])
  map["data"]    = resp("0x" & outputHex)
  map["gasUsed"] = longNode(gasUsed).get()
  map["status"]  = longNode(if isError: 0 else: 1).get()
  ok(map)

proc blockCall(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let param = params[0].val
  try:
    let (callData, gasLimit) = toCallData(param)
    ctx.makeCall(callData, h.header, ctx.chainDB)
  except Exception as em:
    err("call error: " & em.msg)

proc blockEstimateGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = headerNode(parent)
  let param = params[0].val
  try:
    let (callData, gasLimit) = toCallData(param)
    let gasUsed = rpcEstimateGas(callData, h.header, ctx.chainDB, gasLimit)
    longNode(gasUsed)
  except Exception as em:
    err("estimateGas error: " & em.msg)

const blockProcs = {
  "parent": blockParent,
  "number": blockNumberImpl,
  "hash": blockHashImpl,
  "nonce": blockNonce,
  "transactionsRoot": blockTransactionsRoot,
  "transactionCount": blockTransactionCount,
  "stateRoot": blockStateRoot,
  "receiptsRoot": blockReceiptsRoot,
  "miner": blockMiner,
  "extraData": blockExtraData,
  "gasLimit": blockGasLimit,
  "gasUsed": blockGasUsed,
  "timestamp": blockTimestamp,
  "logsBloom": blockLogsBloom,
  "mixHash": blockMixHash,
  "difficulty": blockDifficulty,
  "totalDifficulty": blockTotalDifficulty,
  "ommerCount": blockOmmerCount,
  "ommers": blockOmmers,
  "ommerAt": blockOmmerAt,
  "ommerHash": blockOmmerHash,
  "transactions": blockTransactions,
  "transactionAt": blockTransactionAt,
  "logs": blockLogs,
  "account": blockAccount,
  "call": blockCall,
  "estimateGas": blockEstimateGas
}

proc callResultData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  ok(parent.map[0].val)

proc callResultGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  ok(parent.map[1].val)

proc callResultStatus(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  ok(parent.map[2].val)

const callResultProcs = {
  "data": callResultData,
  "gasUsed": callResultGasUsed,
  "status": callResultStatus
}

proc syncStateStartingBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.chainDB.startingBlock)

proc syncStateCurrentBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.chainDB.currentBlock)

proc syncStateHighestBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.chainDB.highestBlock)

proc syncStatePulledStates(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: what is this ?
  let ctx = GraphqlContextRef(ud)
  ok(respNull())

proc syncStateKnownStates(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: what is this ?
  let ctx = GraphqlContextRef(ud)
  ok(respNull())

const syncStateProcs = {
  "startingBlock": syncStateStartingBlock,
  "currentBlock":  syncStateCurrentBlock,
  "highestBlock":  syncStateHighestBlock,
  "pulledStates":  syncStatePulledStates,
  "knownStates":   syncStateKnownStates
}

proc pendingTransactionCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc pendingTransactions(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc pendingAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc pendingCall(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc pendingEstimateGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

const pendingProcs = {
  "transactionCount": pendingTransactionCount,
  "transactions": pendingTransactions,
  "account": pendingAccount,
  "call": pendingCall,
  "estimateGas": pendingEstimateGas
}

proc queryBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let number = params[0].val
  let hash = params[1].val
  if number.kind != nkEmpty and hash.kind != nkEmpty:
    err("only one param allowed, number or hash, not both")
  elif number.kind == nkInt:
    getBlockByNumber(ctx, number)
  elif hash.kind == nkString:
    getBlockByHash(ctx, hash)
  else:
    getLatestBlock(ctx)

proc queryBlocks(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let fromNumber = parseU64(params[0].val).toBlockNumber

  let to = params[1].val
  let toNumber = if to.kind == nkEmpty:
                   ctx.chainDB.highestBlock
                 else:
                   parseU64(to).toBlockNumber

  if fromNumber > toNumber:
    return err("from($1) is bigger than to($2)" % [fromNumber.toString, toNumber.toString])

  # TODO: what is the maximum number here?
  if toNumber - fromNumber > 32.toBlockNumber:
    return err("can't get more than 32 blocks at once")

  var list = respList()
  var number = fromNumber
  while number <= toNumber:
    let n = getBlockByNumber(ctx, number)
    if n.isErr:
      list.add respNull()
    else:
      list.add n.get()
    number += 1.toBlockNumber

  ok(list)

proc queryPending(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc queryTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let hash = toHash(params[0].val)
  getTxByHash(ctx, hash)

proc queryLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  # TODO: stub, missing impl
  err("not implemented")

proc queryGasPrice(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  try:
    bigIntNode(calculateMedianGasPrice(ctx.chainDB))
  except Exception as em:
    err("can't get gasPrice: " & em.msg)

proc queryProtocolVersion(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  for n in ctx.ethNode.capabilities:
    if n.name == "eth":
      return ok(resp(n.version))
  err("can't get protocol version")

proc querySyncing(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  ok(respMap(ctx.ids[ethSyncState]))

const queryProcs = {
  "block": queryBlock,
  "blocks": queryBlocks,
  "pending": queryPending,
  "transaction": queryTransaction,
  "logs": queryLogs,
  "gasPrice": queryGasPrice,
  "protocolVersion": queryProtocolVersion,
  "syncing": querySyncing
}

proc sendRawTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  try:
    let data   = hexToSeqByte(params[0].val.stringVal)
    let _      = rlp.decode(data, Transaction) # we want to know if it is a valid tx blob
    let txHash = keccakHash(data)
    resp(txHash)
  except Exception as em:
    return err("failed to process raw transaction")

const mutationProcs = {
  "sendRawTransaction": sendRawTransaction
}

{.pop.}

const
  ethSchema = staticRead("ethapi.ql")

proc initEthApi(ctx: GraphqlContextRef) =
  ctx.customScalar("Bytes32", scalarBytes32)
  ctx.customScalar("Address", scalarAddress)
  ctx.customScalar("Bytes", scalarBytes)
  ctx.customScalar("BigInt", scalarBigInt)
  ctx.customScalar("Long", scalarLong)

  for n in EthTypes:
    let name = ctx.createName($n)
    ctx.ids[n] = name

  ctx.addResolvers(ctx, ctx.ids[ethAccount    ], accountProcs)
  ctx.addResolvers(ctx, ctx.ids[ethLog        ], logProcs)
  ctx.addResolvers(ctx, ctx.ids[ethTransaction], txProcs)
  ctx.addResolvers(ctx, ctx.ids[ethBlock      ], blockProcs)
  ctx.addResolvers(ctx, ctx.ids[ethCallResult ], callResultProcs)
  ctx.addResolvers(ctx, ctx.ids[ethSyncState  ], syncStateProcs)
  ctx.addResolvers(ctx, ctx.ids[ethPending    ], pendingProcs)
  ctx.addResolvers(ctx, ctx.ids[ethQuery      ], queryProcs)
  ctx.addResolvers(ctx, ctx.ids[ethMutation   ], mutationProcs)

  let res = ctx.parseSchema(ethSchema)
  if res.isErr:
    echo res.error
    quit(QuitFailure)

proc setupGraphqlContext*(chainDB: BaseChainDB, ethNode: EthereumNode): GraphqlContextRef =
  let ctx = GraphqlContextRef(
    chainDB: chainDB,
    ethNode: ethNode
  )
  graphql.init(ctx)
  ctx.initEthApi()
  ctx

proc setupGraphqlHttpServer*(conf: NimbusConfiguration,
                             chainDB: BaseChainDB, ethNode: EthereumNode): GraphqlHttpServerRef =
  let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  let ctx = setupGraphqlContext(chainDB, ethNode)
  let sres = GraphqlHttpServerRef.new(ctx, conf.graphql.address, socketFlags = socketFlags)
  if sres.isErr():
    echo sres.error
    quit(QuitFailure)
  sres.get()
