# nim-graphql
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils],
  stew/byteutils, stint,
  results,
  eth/common/eth_types_rlp, chronos,
  graphql, graphql/graphql as context,
  graphql/common/types, graphql/httpserver,
  graphql/instruments/query_complexity,
  ../db/[ledger],
  ../rpc/rpc_types,
  ../rpc/rpc_utils,
  ".."/[transaction, evm/state, config, constants],
  ../common/common,
  ../transaction/call_evm,
  ../core/[tx_pool, tx_pool/tx_item],
  ../utils/utils

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
    ethAccessTuple  = "AccessTuple"
    ethWithdrawal   = "Withdrawal"

  HeaderNode = ref object of Node
    header: common.BlockHeader

  AccountNode = ref object of Node
    address: EthAddress
    account: Account
    db: LedgerRef

  TxNode = ref object of Node
    tx: Transaction
    index: uint64
    blockNumber: common.BlockNumber
    receipt: Receipt
    gasUsed: GasInt
    baseFee: Opt[UInt256]

  LogNode = ref object of Node
    log: Log
    index: int
    tx: TxNode

  AclNode = ref object of Node
    acl: AccessPair

  WdNode = ref object of Node
    wd: Withdrawal

  GraphqlContextRef = ref GraphqlContextObj
  GraphqlContextObj = object of Graphql
    ids: array[EthTypes, Name]
    com: CommonRef
    chainDB: CoreDbRef
    ethNode: EthereumNode
    txPool: TxPoolRef

{.push gcsafe, raises: [].}
{.pragma: apiRaises, raises: [].}
{.pragma: apiPragma, cdecl, gcsafe, apiRaises.}

proc toHash(n: Node): common.Hash256 {.gcsafe, raises: [ValueError].} =
  common.Hash256.fromHex(n.stringVal)

proc toBlockNumber(n: Node): common.BlockNumber {.gcsafe, raises: [ValueError].} =
  if n.kind == nkInt:
    result = parse(n.intVal, UInt256, radix = 10).truncate(common.BlockNumber)
  elif n.kind == nkString:
    result = parse(n.stringVal, UInt256, radix = 16).truncate(common.BlockNumber)
  else:
    doAssert(false, "unknown node type: " & $n.kind)

proc headerNode(ctx: GraphqlContextRef, header: common.BlockHeader): Node =
  HeaderNode(
    kind: nkMap,
    typeName: ctx.ids[ethBlock],
    pos: Pos(),
    header: header
  )

proc accountNode(ctx: GraphqlContextRef, acc: Account, address: EthAddress, db: LedgerRef): Node =
  AccountNode(
    kind: nkMap,
    typeName: ctx.ids[ethAccount],
    pos: Pos(),
    account: acc,
    address: address,
    db: db
  )

proc txNode(ctx: GraphqlContextRef, tx: Transaction, index: uint64, blockNumber: common.BlockNumber, baseFee: Opt[UInt256]): Node =
  TxNode(
    kind: nkMap,
    typeName: ctx.ids[ethTransaction],
    pos: Pos(),
    tx: tx,
    index: index,
    blockNumber: blockNumber,
    baseFee: baseFee
  )

proc logNode(ctx: GraphqlContextRef, log: Log, index: int, tx: TxNode): Node =
  LogNode(
    kind: nkMap,
    typeName: ctx.ids[ethLog],
    pos: Pos(),
    log: log,
    index: index,
    tx: tx
  )

proc aclNode(ctx: GraphqlContextRef, accessPair: AccessPair): Node =
  AclNode(
    kind: nkMap,
    typeName: ctx.ids[ethAccessTuple],
    pos: Pos(),
    acl: accessPair
  )

proc wdNode(ctx: GraphqlContextRef, wd: Withdrawal): Node =
  WdNode(
    kind: nkMap,
    typeName: ctx.ids[ethWithdrawal],
    pos: Pos(),
    wd: wd
  )

proc getStateDB(com: CommonRef, header: common.BlockHeader): LedgerRef =
  ## Retrieves the account db from canonical head
  ## we don't use accounst_cache here because it's read only operations
  LedgerRef.init(com.db, header.stateRoot)

proc getBlockByNumber(ctx: GraphqlContextRef, number: Node): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, toBlockNumber(number))))
  except CatchableError as e:
    err(e.msg)

proc getBlockByNumber(ctx: GraphqlContextRef, number: common.BlockNumber): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, number)))
  except CatchableError as e:
    err(e.msg)

proc getBlockByHash(ctx: GraphqlContextRef, hash: Node): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, toHash(hash))))
  except CatchableError as e:
    err(e.msg)

proc getBlockByHash(ctx: GraphqlContextRef, hash: common.Hash256): RespResult =
  try:
    ok(headerNode(ctx, getBlockHeader(ctx.chainDB, hash)))
  except CatchableError as e:
    err(e.msg)

proc getLatestBlock(ctx: GraphqlContextRef): RespResult =
  try:
    ok(headerNode(ctx, getCanonicalHead(ctx.chainDB)))
  except CatchableError as e:
    err("can't get latest block: " & e.msg)

proc getTxCount(ctx: GraphqlContextRef, txRoot: common.Hash256): RespResult =
  try:
    ok(resp(getTransactionCount(ctx.chainDB, txRoot)))
  except CatchableError as e:
    err("can't get txcount: " & e.msg)

proc longNode(val: uint64 | int64): RespResult =
  ok(Node(kind: nkInt, intVal: $val, pos: Pos()))

proc longNode(val: UInt256): RespResult =
  ok(Node(kind: nkInt, intVal: val.toString, pos: Pos()))

proc stripLeadingZeros(x: string): string =
  strip(x, leading = true, trailing = false, chars = {'0'})

proc bigIntNode(val: UInt256): RespResult =
  if val == 0.u256:
    ok(Node(kind: nkString, stringVal: "0x0", pos: Pos()))
  else:
    let hex = stripLeadingZeros(val.toHex)
    ok(Node(kind: nkString, stringVal: "0x" & hex, pos: Pos()))

proc bigIntNode(x: uint64 | int64): RespResult =
  # stdlib toHex is not suitable for hive
  const
    HexChars = "0123456789abcdef"

  if x == 0:
    return ok(Node(kind: nkString, stringVal: "0x0", pos: Pos()))

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

proc resp(hash: common.Hash256): RespResult =
  ok(resp("0x" & hash.data.toHex))

proc resp(data: openArray[byte]): RespResult =
  ok(resp("0x" & data.toHex))

proc getTotalDifficulty(ctx: GraphqlContextRef, blockHash: common.Hash256): RespResult =
  let score = getScore(ctx.chainDB, blockHash).valueOr:
    return err("can't get total difficulty")

  bigIntNode(score)

proc getOmmerCount(ctx: GraphqlContextRef, ommersHash: common.Hash256): RespResult =
  try:
    ok(resp(getUnclesCount(ctx.chainDB, ommersHash)))
  except CatchableError as e:
    err("can't get ommers count: " & e.msg)

proc getOmmers(ctx: GraphqlContextRef, ommersHash: common.Hash256): RespResult =
  try:
    let uncles = getUncles(ctx.chainDB, ommersHash)
    when false:
      # EIP 1767 says no ommers == null
      # but hive test case want empty array []
      if uncles.len == 0:
        return ok(respNull())
    var list = respList()
    for n in uncles:
      list.add headerNode(ctx, n)
    ok(list)
  except CatchableError as e:
    err("can't get ommers: " & e.msg)

proc getOmmerAt(ctx: GraphqlContextRef, ommersHash: common.Hash256, index: int): RespResult =
  try:
    let uncles = getUncles(ctx.chainDB, ommersHash)
    if uncles.len == 0:
      return ok(respNull())
    if index < 0 or index >= uncles.len:
      return ok(respNull())
    ok(headerNode(ctx, uncles[index]))
  except CatchableError as e:
    err("can't get ommer: " & e.msg)

proc getTxs(ctx: GraphqlContextRef, header: common.BlockHeader): RespResult =
  try:
    let txCount = getTransactionCount(ctx.chainDB, header.txRoot)
    if txCount == 0:
      return ok(respNull())
    var list = respList()
    var index = 0'u64
    for n in getBlockTransactionData(ctx.chainDB, header.txRoot):
      let tx = decodeTx(n)
      list.add txNode(ctx, tx, index, header.number, header.baseFeePerGas)
      inc index

    index = 0'u64
    var prevUsed = 0.GasInt
    for r in getReceipts(ctx.chainDB, header.receiptsRoot):
      let tx = TxNode(list.sons[index])
      tx.receipt = r
      tx.gasUsed = r.cumulativeGasUsed - prevUsed
      prevUsed = r.cumulativeGasUsed
      inc index

    ok(list)
  except CatchableError as e:
    err("can't get transactions: " & e.msg)

proc getWithdrawals(ctx: GraphqlContextRef, header: common.BlockHeader): RespResult =
  try:
    if header.withdrawalsRoot.isSome:
      let wds = getWithdrawals(ctx.chainDB, header.withdrawalsRoot.get)
      var list = respList()
      for wd in wds:
        list.add wdNode(ctx, wd)
      ok(list)
    else:
      ok(respNull())
  except CatchableError as e:
    err("can't get transactions: " & e.msg)

proc getTxAt(ctx: GraphqlContextRef, header: common.BlockHeader, index: uint64): RespResult =
  try:
    var tx: Transaction
    if getTransactionByIndex(ctx.chainDB, header.txRoot, index.uint16, tx):
      let txn = txNode(ctx, tx, index, header.number, header.baseFeePerGas)

      var i = 0'u64
      var prevUsed = 0.GasInt
      for r in getReceipts(ctx.chainDB, header.receiptsRoot):
        if i == index:
          let tx = TxNode(txn)
          tx.receipt = r
          tx.gasUsed = r.cumulativeGasUsed - prevUsed
        prevUsed = r.cumulativeGasUsed
        inc i

      ok(txn)
    else:
      ok(respNull())
  except CatchableError as exc:
    err("can't get transaction by index '" & $index & "': " & exc.msg)
  except RlpError as exc:
    err("can't get transaction by index '" & $index & "': " & exc.msg)

proc getTxByHash(ctx: GraphqlContextRef, hash: common.Hash256): RespResult =
  try:
    let (blockNumber, index) = getTransactionKey(ctx.chainDB, hash)
    let header = getBlockHeader(ctx.chainDB, blockNumber)
    getTxAt(ctx, header, index)
  except CatchableError as e:
    err("can't get transaction by hash '" & hash.data.toHex & "': $2" & e.msg)

proc accountNode(ctx: GraphqlContextRef, header: common.BlockHeader, address: EthAddress): RespResult =
  try:
    let db = getStateDB(ctx.com, header)
    when false:
      # EIP 1767 unclear about non existent account
      # but hive test case demand something
      if not db.accountExists(address):
        return ok(respNull())
    let acc = db.getEthAccount(address)
    ok(accountNode(ctx, acc, address, db))
  except RlpError as ex:
    err(ex.msg)

func hexCharToInt(c: char): uint64 =
  case c
  of 'a'..'f': return c.uint64 - 'a'.uint64 + 10'u64
  of 'A'..'F': return c.uint64 - 'A'.uint64 + 10'u64
  of '0'..'9': return c.uint64 - '0'.uint64
  else: doAssert(false, "invalid hex digit: " & $c)

proc parseU64(node: Node): uint64 =
  if node.kind == nkString:
    if node.stringVal.len > 2 and node.stringVal[1] == 'x':
      for i in 2..<node.stringVal.len:
        let c = node.stringVal[i]
        result = result * 16 + hexCharToInt(c)
    else:
      for c in node.stringVal:
        result = result * 10 + (c.uint64 - '0'.uint64)
  else:
    for c in node.intVal:
      result = result * 10 + (c.uint64 - '0'.uint64)

proc validateHex(x: Node, minLen = 0): NodeResult =
  if x.stringVal.len < 2:
    return err("hex is too short")
  if x.stringVal.len != 2 + minLen * 2 and minLen != 0:
    return err("expect hex with len '" &
      $(2 * minLen + 2) & "', got '" & $x.stringVal.len & "'")
  if x.stringVal.len mod 2 != 0:
    return err("hex must have even number of nibbles")
  if x.stringVal[0] != '0' or x.stringVal[1] != 'x':
    return err("hex should be prefixed by '0x'")
  for i in 2..<x.stringVal.len:
    if x.stringVal[i] notin HexDigits:
      return err("invalid chars in hex")
  ok(x)

proc padBytes(n: Node, prefixLen, minLen: int) =
  let tmp = n.stringVal
  if prefixLen != 0:
    n.stringVal = newString(minLen + prefixLen)
    for i in 0..<prefixLen:
      n.stringVal[i] = tmp[i]
    let zeros = minLen - tmp.len + prefixLen
    for i in 0..<zeros:
      n.stringVal[i + prefixLen] = '0'
    for i in 2..<tmp.len:
      n.stringVal[i+zeros] = tmp[i]
  else:
    n.stringVal = newString(minLen)
    let zeros = minLen - tmp.len
    for i in 0..<zeros:
      n.stringVal[i] = '0'
    for i in 0..<tmp.len:
      n.stringVal[i+zeros] = tmp[i]

proc validateFixedLenHex(x: Node, minLen: int, kind: string, padding = false): NodeResult =
  if x.stringVal.len < 2:
    return err(kind & " hex is too short")

  try:
    var prefixLen = 0
    if x.stringVal[0] == '0' and x.stringVal[1] == 'x':
      prefixLen = 2

    let expectedLen = minLen * 2 + prefixLen
    if x.stringVal.len < expectedLen:
      if not padding:
        return err("$1 len is too short: expect $2 got $3" %
          [kind, $expectedLen, $x.stringVal.len])
      else:
        padBytes(x, prefixLen, minLen * 2)
    elif x.stringVal.len > expectedLen:
      return err("$1 len is too long: expect $2 got $3" %
        [kind, $expectedLen, $x.stringVal.len])

    for i in prefixLen..<x.stringVal.len:
      if x.stringVal[i] notin HexDigits:
        return err("invalid chars in $1 hex" % [kind])

    ok(x)
  except ValueError as exc:
    err(exc.msg)

proc scalarBytes32(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, noSideEffect, raises:[].} =
  ## Bytes32 is a 32 byte binary string,
  ## represented as 0x-prefixed hexadecimal.
  if node.kind != nkString:
    return err("expect hex string, but got '" & $node.kind & "'")
  validateFixedLenHex(node, 32, "Bytes32", padding = true)

proc scalarAddress(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, noSideEffect, raises:[].} =
  ## Address is a 20 byte Ethereum address,
  ## represented as 0x-prefixed hexadecimal.
  if node.kind != nkString:
    return err("expect hex string, but got '" & $node.kind & "'")
  validateFixedLenHex(node, 20, "Address")

proc scalarBytes(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, noSideEffect, raises:[].} =
  ## Bytes is an arbitrary length binary string,
  ## represented as 0x-prefixed hexadecimal.
  ## An empty byte string is represented as '0x'.
  ## Byte strings must have an even number of hexadecimal nybbles.
  if node.kind != nkString:
    return err("expect hex string, but got '" & $node.kind & "'")
  validateHex(node)

proc scalarBigInt(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, noSideEffect, raises:[].} =
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
      return err("expect hex/dec string or int, but got '" & $node.kind & "'")
  except CatchableError as e:
    err("scalar BigInt error: " & e.msg)

proc scalarLong(ctx: GraphqlRef, typeNode, node: Node): NodeResult {.cdecl, gcsafe, noSideEffect.} =
  ## Long is a 64 bit unsigned integer.
  const maxU64 = uint64.high.u256
  try:
    case node.kind
    of nkString:
      if node.stringVal.len > 2 and node.stringVal[1] == 'x':
        let val = parse(node.stringVal, UInt256, radix = 16)
        if val > maxU64:
          return err("long value overflow")
        ok(node)
      else:
        let val = parse(node.stringVal, UInt256, radix = 10)
        if val > maxU64:
          return err("long value overflow")
        ok(Node(kind: nkString, pos: node.pos, stringVal: "0x" & val.toHex))
    of nkInt:
      let val = parse(node.intVal, UInt256, radix = 10)
      if val > maxU64:
        return err("long value overflow")
      ok(Node(kind: nkString, pos: node.pos, stringVal: "0x" & val.toHex))
    else:
      err("expect int, but got '" & $node.kind & "'")
  except CatchableError as e:
    err("scalar Long error: " & e.msg)

proc accountAddress(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acc = AccountNode(parent)
  resp(acc.address.data)

proc accountBalance(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acc = AccountNode(parent)
  bigIntNode(acc.account.balance)

proc accountTxCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acc = AccountNode(parent)
  longNode(acc.account.nonce)

proc accountCode(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acc = AccountNode(parent)
  try:
    let code = acc.db.getCode(acc.address)
    resp(code.bytes())
  except RlpError as ex:
    err(ex.msg)

proc accountStorage(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acc = AccountNode(parent)
  try:
    let slot = parse(params[0].val.stringVal, UInt256, radix = 16)
    let val = acc.db.getStorage(acc.address, slot)
    byte32Node(val)
  except RlpError as ex:
    err(ex.msg)
  except ValueError as ex:
    err(ex.msg)

const accountProcs = {
  # Note: Need to define it as ResolverProc else a proc with noSideEffect is
  # assumed and this fails for accountCode and accountStorage.
  "address": ResolverProc accountAddress,
  "balance": accountBalance,
  "transactionCount": accountTxCount,
  "code": accountCode,
  "storage": accountStorage
}

proc logIndex(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let log = LogNode(parent)
  ok(resp(log.index))

proc logAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: with block param
  let ctx = GraphqlContextRef(ud)
  let log = LogNode(parent)

  let hres = ctx.getBlockByNumber(log.tx.blockNumber)
  if hres.isErr:
    return hres
  let h = HeaderNode(hres.get())
  ctx.accountNode(h.header, log.log.address)

proc logTopics(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let log = LogNode(parent)
  var list = respList()
  for n in log.log.topics:
    list.add resp("0x" & n.toHex)
  ok(list)

proc logData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let log = LogNode(parent)
  resp(log.log.data)

proc logTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let log = LogNode(parent)
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
    tx = TxNode(parent)
    txHash = rlpHash(tx.tx) # beware EIP-4844
  resp(txHash)

proc txNonce(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  longNode(tx.tx.nonce)

proc txIndex(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  ok(resp(tx.index.int))

proc txFrom(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)

  let blockNumber = if params[0].val.kind != nkEmpty:
    parseU64(params[0].val)
  else:
    tx.blockNumber

  var sender: EthAddress
  if not getSender(tx.tx, sender):
    return ok(respNull())
  let hres = ctx.getBlockByNumber(blockNumber)
  if hres.isErr:
    return hres
  let h = HeaderNode(hres.get())
  ctx.accountNode(h.header, sender)

proc txTo(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)

  let blockNumber = if params[0].val.kind != nkEmpty:
    parseU64(params[0].val)
  else:
    tx.blockNumber

  if tx.tx.contractCreation:
    return ok(respNull())
  let hres = ctx.getBlockByNumber(blockNumber)
  if hres.isErr:
    return hres
  let h = HeaderNode(hres.get())
  ctx.accountNode(h.header, tx.tx.to.get())

proc txValue(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  bigIntNode(tx.tx.value)

proc txGasPrice(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType >= TxEip1559:
    if tx.baseFee.isNone:
      return bigIntNode(tx.tx.gasPrice)

    let baseFee = tx.baseFee.get().truncate(GasInt)
    let priorityFee = min(tx.tx.maxPriorityFeePerGas, tx.tx.maxFeePerGas - baseFee)
    bigIntNode(priorityFee + baseFee)
  else:
    bigIntNode(tx.tx.gasPrice)

proc txMaxFeePerGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType >= TxEip1559:
    bigIntNode(tx.tx.maxFeePerGas)
  else:
    ok(respNull())

proc txMaxPriorityFeePerGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType >= TxEip1559:
    bigIntNode(tx.tx.maxPriorityFeePerGas)
  else:
    ok(respNull())

proc txEffectiveGasPrice(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.baseFee.isNone:
    return bigIntNode(tx.tx.gasPrice)

  let baseFee = tx.baseFee.get().truncate(GasInt)
  let priorityFee = min(tx.tx.maxPriorityFeePerGas, tx.tx.maxFeePerGas - baseFee)
  bigIntNode(priorityFee + baseFee)

proc txChainId(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType == TxLegacy:
    ok(respNull())
  else:
    longNode(tx.tx.chainId.uint64)

proc txGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  longNode(tx.tx.gasLimit)

proc txInputData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  resp(tx.tx.payload)

proc txBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)
  ctx.getBlockByNumber(tx.blockNumber)

proc txStatus(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.receipt.hasStatus:
    longNode(tx.receipt.status.uint64)
  else:
    ok(respNull())

proc txGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  longNode(tx.gasUsed)

proc txCumulativeGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  longNode(tx.receipt.cumulativeGasUsed)

proc txCreatedContract(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)
  var sender: EthAddress
  if not getSender(tx.tx, sender):
    return err("can't calculate sender")

  if not tx.tx.contractCreation:
    return ok(respNull())

  let hres = getBlockByNumber(ctx, tx.blockNumber)
  if hres.isErr:
    return hres
  let h = HeaderNode(hres.get())
  let contractAddress = generateAddress(sender, tx.tx.nonce)
  ctx.accountNode(h.header, contractAddress)

proc txLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)
  var list = respList()
  for i, n in tx.receipt.logs:
    list.add logNode(ctx, n, i, tx)
  ok(list)

proc txR(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  bigIntNode(tx.tx.R)

proc txS(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  bigIntNode(tx.tx.S)

proc txV(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  bigIntNode(tx.tx.V)

proc txType(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  let typ = resp(ord(tx.tx.txType))
  ok(typ)

proc txAccessList(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let tx = TxNode(parent)
  if tx.tx.txType == TxLegacy:
    ok(respNull())
  else:
    var list = respList()
    for x in tx.tx.accessList:
      list.add aclNode(ctx, x)
    ok(list)

proc txMaxFeePerBlobGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType < TxEIP4844:
    ok(respNull())
  else:
    longNode(tx.tx.maxFeePerBlobGas)

proc txVersionedHashes(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  if tx.tx.txType < TxEIP4844:
    ok(respNull())
  else:
    var list = respList()
    for hs in tx.tx.versionedHashes:
      list.add resp("0x" & hs.data.toHex)
    ok(list)

proc txRaw(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  let txBytes = rlp.encode(tx.tx)
  resp(txBytes)

proc txRawReceipt(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let tx = TxNode(parent)
  let recBytes = rlp.encode(tx.receipt)
  resp(recBytes)

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
  "logs": txLogs,
  "r": txR,
  "s": txS,
  "v": txV,
  "type": txType,
  "accessList": txAccessList,
  "maxFeePerGas": txMaxFeePerGas,
  "maxPriorityFeePerGas": txMaxPriorityFeePerGas,
  "effectiveGasPrice": txEffectiveGasPrice,
  "chainID": txChainId,
  "maxFeePerBlobGas": txMaxFeePerBlobGas,
  "versionedHashes": txVersionedHashes,
  "raw": txRaw,
  "rawReceipt": txRawReceipt
}

proc aclAddress(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acl = AclNode(parent)
  resp(acl.acl.address.data)

proc aclStorageKeys(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let acl = AclNode(parent)
  if acl.acl.storageKeys.len == 0:
    ok(respNull())
  else:
    var list = respList()
    for n in acl.acl.storageKeys:
      list.add resp(n.data).get()
    ok(list)

const aclProcs = {
  "address": aclAddress,
  "storageKeys": aclStorageKeys
}

proc wdIndex(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let w = WdNode(parent)
  longNode(w.wd.index)

proc wdValidator(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let w = WdNode(parent)
  longNode(w.wd.validatorIndex)

proc wdAddress(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let w = WdNode(parent)
  resp(w.wd.address.data)

proc wdAmount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let w = WdNode(parent)
  longNode(w.wd.amount)

const wdProcs = {
  "index": wdIndex,
  "validator": wdValidator,
  "address": wdAddress,
  "amount": wdAmount
}

proc blockNumberImpl(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  longNode(h.header.number)

proc blockHashImpl(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  let hash = blockHash(h.header)
  resp(hash)

proc blockParent(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  getBlockByHash(ctx, h.header.parentHash)

proc blockNonce(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  ok(resp("0x" & h.header.nonce.toHex))

proc blockTransactionsRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.txRoot)

proc blockTransactionCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  ctx.getTxCount(h.header.txRoot)

proc blockStateRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.stateRoot)

proc blockReceiptsRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.receiptsRoot)

proc blockMiner(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  ctx.accountNode(h.header, h.header.coinbase)

proc blockExtraData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.extraData)

proc blockGasLimit(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  longNode(h.header.gasLimit)

proc blockGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  longNode(h.header.gasUsed)

proc blockTimestamp(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  bigIntNode(h.header.timestamp.uint64)

proc blockLogsBloom(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.logsBloom.data)

proc blockMixHash(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.mixHash)

proc blockDifficulty(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  bigIntNode(h.header.difficulty)

proc blockTotalDifficulty(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  let hash = blockHash(h.header)
  getTotalDifficulty(ctx, hash)

proc blockOmmerCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  getOmmerCount(ctx, h.header.ommersHash)

proc blockOmmers(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  getOmmers(ctx, h.header.ommersHash)

proc blockOmmerAt(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  let index = parseU64(params[0].val)
  getOmmerAt(ctx, h.header.ommersHash, index.int)

proc blockOmmerHash(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  resp(h.header.ommersHash)

proc blockTransactions(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  {.cast(noSideEffect).}:
    getTxs(ctx, h.header)

proc blockTransactionAt(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  try:
    let index = parseU64(params[0].val)
    {.cast(noSideEffect).}:
      getTxAt(ctx, h.header, index)
  except ValueError as ex:
    err(ex.msg)

proc blockLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc blockAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  try:
    let address = EthAddress.fromHex(params[0].val.stringVal)
    ctx.accountNode(h.header, address)
  except ValueError as ex:
    err(ex.msg)

const
  fFrom     = 0
  fTo       = 1
  fGasLimit = 2
  fGasPrice = 3
  fMaxFee   = 4
  fMaxPriorityFee = 5
  fValue    = 6
  fData     = 7

template isSome(n: Node, field: int): bool =
  # [0] is the field's name node
  # [1] is the field's value node
  n[field][1].kind != nkEmpty

template fieldString(n: Node, field: int): string =
  n[field][1].stringVal

template optionalAddress(dstField: untyped, n: Node, field: int) =
  if isSome(n, field):
    let address = addresses.Address.fromHex(fieldString(n, field))
    dstField = Opt.some(primitives.Address address.data)

template optionalGasInt(dstField: untyped, n: Node, field: int) =
  if isSome(n, field):
    dstField = Opt.some(parseU64(n[field][1]).Quantity)

template optionalGasHex(dstField: untyped, n: Node, field: int) =
  if isSome(n, field):
    let gas = parse(fieldString(n, field), UInt256, radix = 16)
    dstField = Opt.some(gas.truncate(uint64).Quantity)

template optionalHexU256(dstField: untyped, n: Node, field: int) =
  if isSome(n, field):
    dstField = Opt.some(parse(fieldString(n, field), UInt256, radix = 16))

template optionalBytes(dstField: untyped, n: Node, field: int) =
  if isSome(n, field):
    dstField = Opt.some(hexToSeqByte(fieldString(n, field)))

proc toTxArgs(n: Node): TransactionArgs {.gcsafe, raises: [ValueError].} =
  optionalAddress(result.`from`, n, fFrom)
  optionalAddress(result.to, n, fTo)
  optionalGasInt(result.gas, n, fGasLimit)
  optionalGasHex(result.gasPrice, n, fGasPrice)
  optionalGasHex(result.maxFeePerGas, n, fMaxFee)
  optionalGasHex(result.maxPriorityFeePerGas, n, fMaxPriorityFee)
  optionalHexU256(result.value, n, fValue)
  optionalBytes(result.data, n, fData)

proc makeCall(ctx: GraphqlContextRef, args: TransactionArgs,
              header: common.BlockHeader): RespResult =
  let res = rpcCallEvm(args, header, ctx.com).valueOr:
              return err("Failed to call rpcCallEvm")
  var map = respMap(ctx.ids[ethCallResult])
  map["data"]    = resp("0x" & res.output.toHex)
  map["gasUsed"] = longNode(res.gasUsed).get()
  map["status"]  = longNode(if res.isError: 0 else: 1).get()
  ok(map)

proc blockCall(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  let param = params[0].val
  try:
    let args = toTxArgs(param)
    {.cast(noSideEffect).}:
      ctx.makeCall(args, h.header)
  except CatchableError as em:
    err("call error: " & em.msg)

proc blockEstimateGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  let param = params[0].val
  try:
    let args = toTxArgs(param)
    # TODO: DEFAULT_RPC_GAS_CAP should configurable
    {.cast(noSideEffect).}:
      let gasUsed = rpcEstimateGas(args, h.header, ctx.com, DEFAULT_RPC_GAS_CAP).valueOr:
                      return err("Failed to call rpcEstimateGas")
      longNode(gasUsed)
  except CatchableError as em:
    err("estimateGas error: " & em.msg)

proc blockBaseFeePerGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  if h.header.baseFeePerGas.isSome:
    bigIntNode(h.header.baseFeePerGas.get)
  else:
    ok(respNull())

proc blockWithdrawalsRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  if h.header.withdrawalsRoot.isSome:
    resp(h.header.withdrawalsRoot.get)
  else:
    ok(respNull())

proc blockWithdrawals(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let h = HeaderNode(parent)
  getWithdrawals(ctx, h.header)

proc blockBlobGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  if h.header.blobGasUsed.isSome:
    longNode(h.header.blobGasUsed.get)
  else:
    ok(respNull())

proc blockExcessBlobGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  if h.header.excessBlobGas.isSome:
    longNode(h.header.excessBlobGas.get)
  else:
    ok(respNull())

proc blockParentBeaconBlockRoot(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let h = HeaderNode(parent)
  if h.header.parentBeaconBlockRoot.isSome:
    resp(h.header.parentBeaconBlockRoot.get)
  else:
    ok(respNull())


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
  "estimateGas": blockEstimateGas,
  "baseFeePerGas": blockBaseFeePerGas,
  "withdrawalsRoot": blockWithdrawalsRoot,
  "withdrawals": blockWithdrawals,
  "blobGasUsed": blockBlobGasUsed,
  "excessBlobGas": blockExcessBlobGas,
  "parentBeaconBlockRoot": blockParentBeaconBlockRoot,
}

proc callResultData(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  ok(parent.map[0].val)

proc callResultGasUsed(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  ok(parent.map[1].val)

proc callResultStatus(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  ok(parent.map[2].val)

const callResultProcs = {
  "data": callResultData,
  "gasUsed": callResultGasUsed,
  "status": callResultStatus
}

proc syncStateStartingBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.com.syncStart)

proc syncStateCurrentBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.com.syncCurrent)

proc syncStateHighestBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.com.syncHighest)

proc syncStatePulledStates(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: what is this ?
  ok(respNull())

proc syncStateKnownStates(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: what is this ?
  ok(respNull())

const syncStateProcs = {
  "startingBlock": syncStateStartingBlock,
  "currentBlock":  syncStateCurrentBlock,
  "highestBlock":  syncStateHighestBlock,
  "pulledStates":  syncStatePulledStates,
  "knownStates":   syncStateKnownStates
}

proc pendingTransactionCount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc pendingTransactions(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc pendingAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc pendingCall(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc pendingEstimateGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

const pendingProcs = {
  "transactionCount": pendingTransactionCount,
  "transactions": pendingTransactions,
  "account": pendingAccount,
  "call": pendingCall,
  "estimateGas": pendingEstimateGas
}

proc pickBlockNumber(ctx: GraphqlContextRef, number: Node): common.BlockNumber =
  if number.kind == nkEmpty:
    ctx.com.syncCurrent
  else:
    parseU64(number)

proc queryAccount(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  try:
    let address = EthAddress.fromHex(params[0].val.stringVal)
    let blockNumber = pickBlockNumber(ctx, params[1].val)
    let hres = getBlockByNumber(ctx, blockNumber)
    if hres.isErr:
      return hres
    let h = HeaderNode(hres.get())
    accountNode(ctx, h.header, address)
  except ValueError as ex:
    err(ex.msg)

proc queryBlock(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let number = params[0].val
  let hash = params[1].val
  if number.kind != nkEmpty and hash.kind != nkEmpty:
    err("only one param allowed, number or hash, not both")
  elif number.kind == nkInt:
    getBlockByNumber(ctx, number)
  elif number.kind == nkString:
    try:
      let blockNumber = toBlockNumber(number)
      getBlockByNumber(ctx, blockNumber)
    except ValueError as ex:
      err(ex.msg)
  elif hash.kind == nkString:
    getBlockByHash(ctx, hash)
  else:
    getLatestBlock(ctx)

proc queryBlocks(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  let fromNumber = parseU64(params[0].val)

  let to = params[1].val
  let toNumber = pickBlockNumber(ctx, to)

  if fromNumber > toNumber:
    return err("from(" & $fromNumber &
      ") is bigger than to(" & $toNumber & ")")

  # TODO: what is the maximum number here?
  if toNumber - fromNumber > 32'u64:
    return err("can't get more than 32 blocks at once")

  var list = respList()
  var number = fromNumber
  while number <= toNumber:
    let n = getBlockByNumber(ctx, number)
    if n.isErr:
      list.add respNull()
    else:
      list.add n.get()
    number += 1'u64

  ok(list)

proc queryPending(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc queryTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  try:
    let hash = toHash(params[0].val)
    {.cast(noSideEffect).}:
      getTxByHash(ctx, hash)
  except ValueError as ex:
    err(ex.msg)

proc queryLogs(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc queryGasPrice(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  try:
    {.cast(noSideEffect).}:
      bigIntNode(calculateMedianGasPrice(ctx.chainDB))
  except CatchableError as em:
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

proc queryMaxPriorityFeePerGas(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # TODO: stub, missing impl
  err("not implemented")

proc queryChainId(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  let ctx = GraphqlContextRef(ud)
  longNode(ctx.com.chainId.uint64)

const queryProcs = {
  "account": queryAccount,
  "block": queryBlock,
  "blocks": queryBlocks,
  "pending": queryPending,
  "transaction": queryTransaction,
  "logs": queryLogs,
  "gasPrice": queryGasPrice,
  "protocolVersion": queryProtocolVersion,
  "syncing": querySyncing,
  "maxPriorityFeePerGas": queryMaxPriorityFeePerGas,
  "chainID": queryChainId
}

proc sendRawTransaction(ud: RootRef, params: Args, parent: Node): RespResult {.apiPragma.} =
  # if tx validation failed, the result will be null
  let ctx = GraphqlContextRef(ud)
  try:
    let data   = hexToSeqByte(params[0].val.stringVal)
    let tx     = decodePooledTx(data) # we want to know if it is a valid tx blob
    let txHash = rlpHash(tx)

    ctx.txPool.add(tx)

    let res = ctx.txPool.inPoolAndReason(txHash)
    if res.isOk:
      return resp(txHash)
    else:
      return err(res.error)

  except CatchableError as em:
    return err("failed to process raw transaction: " & em.msg)

const mutationProcs = {
  "sendRawTransaction": sendRawTransaction
}

const
  ethSchema = staticRead("ethapi.ql")

type
  QcNames = enum
    qcType   = "__Type"
    qcFields = "fields"
    qcBlock  = "block"
    qcTransaction = "Transaction"

  EthQueryComplexity = ref object of QueryComplexity
    names: array[QcNames, Name]

proc calcQC(qc: QueryComplexity, field: FieldRef): int {.cdecl,
            gcsafe, apiRaises.} =
  let qc = EthQueryComplexity(qc)
  if field.parentType.sym.name == qc.names[qcType] and
     field.field.name.name == qc.names[qcFields]:
    return 100
  elif field.parentType.sym.name == qc.names[qcTransaction] and
     field.field.name.name == qc.names[qcBlock]:
    return 100
  else:
    return 1

proc newQC(ctx: GraphqlContextRef): EthQueryComplexity =
  const MaxQueryComplexity = 200
  var qc = EthQueryComplexity()
  qc.init(calcQC, MaxQueryComplexity)
  for n in QcNames:
    let name = ctx.createName($n)
    qc.names[n] = name
  qc

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
  ctx.addResolvers(ctx, ctx.ids[ethAccessTuple], aclProcs)
  ctx.addResolvers(ctx, ctx.ids[ethWithdrawal ], wdProcs)

  var qc = newQC(ctx)
  ctx.addInstrument(qc)

  let res = ctx.parseSchema(ethSchema)
  if res.isErr:
    echo res.error
    quit(QuitFailure)

proc setupGraphqlContext*(com: CommonRef,
                          ethNode: EthereumNode,
                          txPool: TxPoolRef): GraphqlContextRef =
  let ctx = GraphqlContextRef(
    chainDB: com.db,
    com    : com,
    ethNode: ethNode,
    txPool : txPool
  )
  graphql.init(ctx)
  ctx.initEthApi()
  ctx

proc setupGraphqlHttpHandler*(com: CommonRef,
                              ethNode: EthereumNode,
                              txPool: TxPoolRef): GraphqlHttpHandlerRef =
  let ctx = setupGraphqlContext(com, ethNode, txPool)
  GraphqlHttpHandlerRef.new(ctx)

{.pop.}
