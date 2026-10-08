# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/[monotimes, strformat, strutils, times],
  unittest2,
  stint,
  results,
  eth/common/[addresses, hashes, headers, transactions, block_access_lists_rlp],
  ../../execution_chain/common/[common, evmforks],
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/evm/[state, types],
  ../../execution_chain/evm/interpreter/op_codes,
  ../../execution_chain/core/executor/process_transaction,
  ../../execution_chain/block_access_list/bal_tracker

from ../../tools/common/helpers import getChainConfig

type
  Kind = enum
    Transfer
    Token
    CallChain
    Reverts
    Reads
    Storage
    CreateDestroy

  Asm = object
    code: seq[byte]

  Env = object
    com: CommonRef
    setupFrame: CoreDbTxRef
    parent: Header
    header: Header

  RunResult = object
    nanos: int64
    buildNanos: int64
    accounts: int
    hash: string

const
  numSenders = 64
  numRecipients = 256
  repeats = 7
  workloads = [
    (Transfer, "transfer", 2048),
    (Token, "token transfer", 2048),
    (CallChain, "4-deep calls", 1024),
    (Reverts, "reverted calls", 512),
    (Reads, "read heavy", 512),
    (Storage, "storage heavy", 512),
    (CreateDestroy, "create+destroy", 1024),
  ]

func makeAddress(tag: byte, i: int): Address =
  var input: array[9, byte]
  input[0] = tag
  for k in 0 ..< 8:
    input[1 + k] = byte((i shr (8 * k)) and 0xff)
  keccak256(input).to(Address)

func toSlot(a: Address): UInt256 =
  UInt256.fromBytesBE(a.to(Bytes32).data)

func op(a: var Asm, o: Op) =
  a.code.add byte(o)

func push(a: var Asm, v: int) =
  doAssert v >= 0 and v < 65536
  if v < 256:
    a.code.add byte(Op.Push1)
    a.code.add byte(v)
  else:
    a.code.add byte(Op.Push2)
    a.code.add byte(v shr 8)
    a.code.add byte(v and 0xff)

func push(a: var Asm, x: Address) =
  a.code.add byte(Op.Push20)
  a.code.add x.data

func push(a: var Asm, x: UInt256) =
  a.code.add byte(Op.Push32)
  a.code.add x.toBytesBE

func callTo(a: var Asm, target: Address) =
  for _ in 0 ..< 5:
    a.push 0
  a.push target
  a.op Gas
  a.op Call
  a.op Pop

let
  senders = block:
    var s: seq[Address]
    for i in 0 ..< numSenders:
      s.add makeAddress(1, i)
    s
  recipients = block:
    var s: seq[Address]
    for i in 0 ..< numRecipients:
      s.add makeAddress(2, i)
    s
  coinbaseAddr = makeAddress(3, 0)
  tokenAddr = makeAddress(4, 0)
  chainAddrs = [makeAddress(5, 0), makeAddress(5, 1), makeAddress(5, 2), makeAddress(5, 3)]
  revertParent = makeAddress(6, 0)
  revertChild = makeAddress(6, 1)
  readerAddr = makeAddress(7, 0)
  writerAddr = makeAddress(8, 0)
  factoryAddr = makeAddress(9, 0)

proc tokenCode(): seq[byte] =
  var a: Asm
  a.op Caller
  a.op Sload
  a.push 1
  a.op Swap1
  a.op Sub
  a.op Caller
  a.op Sstore
  a.push 0
  a.op CallDataLoad
  a.op Dup1
  a.op Sload
  a.push 1
  a.op Add
  a.op Swap1
  a.op Sstore
  a.push 0
  a.op CallDataLoad
  a.op Caller
  a.push UInt256.fromBytesBE(keccak256("Transfer(address,address,uint256)").data)
  a.push 0
  a.push 0
  a.op Log3
  a.op Stop
  a.code

proc chainCode(next: int): seq[byte] =
  var a: Asm
  a.push 0
  a.op Sload
  a.push 1
  a.op Add
  a.push 0
  a.op Sstore
  a.push 1
  a.op Sload
  a.op Pop
  if next < chainAddrs.len:
    a.callTo chainAddrs[next]
  a.op Stop
  a.code

proc revertChildCode(): seq[byte] =
  var a: Asm
  for k in 0 ..< 4:
    a.op Gas
    a.push 10 + k
    a.op Sstore
  a.push 20
  a.op Sload
  a.op Pop
  a.push 21
  a.op Sload
  a.op Pop
  a.push 0
  a.push 0
  a.op Revert
  a.code

proc revertParentCode(): seq[byte] =
  var a: Asm
  a.push 0
  a.op Sload
  a.push 1
  a.op Add
  a.push 0
  a.op Sstore
  for _ in 0 ..< 8:
    a.callTo revertChild
  a.op Stop
  a.code

proc readerCode(): seq[byte] =
  var a: Asm
  for s in 0 ..< 64:
    a.push s
    a.op Sload
    a.op Pop
  for i in 0 ..< 16:
    a.push recipients[i]
    a.op Balance
    a.op Pop
  for i in 0 ..< 16:
    a.push(if i mod 2 == 0: chainAddrs[i mod 4] else: recipients[16 + i])
    a.op ExtCodeHash
    a.op Pop
  a.op Stop
  a.code

proc writerCode(): seq[byte] =
  var a: Asm
  for s in 0 ..< 64:
    a.push 0
    a.op CallDataLoad
    a.push s
    a.op Add
    a.push s
    a.op Sstore
  a.push 200
  a.op Sload
  a.push 0
  a.op CallDataLoad
  a.push 200
  a.op Sstore
  a.push 200
  a.op Sstore
  a.push 201
  a.op Sload
  a.push 201
  a.op Sstore
  a.op Stop
  a.code

proc factoryCode(): seq[byte] =
  var a: Asm
  a.code.add byte(Op.Push7)
  a.code.add [byte(Op.Push1), 0x01, byte(Op.Push1), 0x00, byte(Op.Sstore),
    byte(Op.Caller), byte(Op.SelfDestruct)]
  a.push 0
  a.op Mstore
  a.push 7
  a.push 25
  a.push 0
  a.op Create
  a.op Pop
  a.op Stop
  a.code

proc initEnv(): Env =
  let
    config = getChainConfig("Amsterdam").expect("Amsterdam config")
    db = newCoreDbRef(DefaultDbMemory)
    com = CommonRef.new(db, config)
    setupFrame = db.baseTxFrame().txFrameBegin()
    ledger = LedgerRef.init(setupFrame)

  for s in senders:
    ledger.setBalance(s, 1.u256 shl 80)
    ledger.setStorage(tokenAddr, s.toSlot, 1_000_000_000.u256)
  for r in recipients:
    ledger.setBalance(r, 1.u256)
  ledger.setCode(tokenAddr, tokenCode())
  for i in 0 ..< chainAddrs.len:
    ledger.setCode(chainAddrs[i], chainCode(i + 1))
  ledger.setCode(revertParent, revertParentCode())
  ledger.setCode(revertChild, revertChildCode())
  ledger.setCode(readerAddr, readerCode())
  for s in 0 ..< 32:
    ledger.setStorage(readerAddr, s.u256, (s + 1).u256)
  ledger.setCode(writerAddr, writerCode())
  ledger.setStorage(writerAddr, 200.u256, 7.u256)
  ledger.setStorage(writerAddr, 201.u256, 9.u256)
  ledger.setCode(factoryAddr, factoryCode())
  ledger.persist()

  Env(
    com: com,
    setupFrame: setupFrame,
    parent: Header(number: 0, timestamp: EthTime(0), gasLimit: 1_000_000_000_000.GasInt),
    header: Header(
      number: 1,
      timestamp: EthTime(12),
      gasLimit: 1_000_000_000_000.GasInt,
      baseFeePerGas: Opt.some(7.u256),
      coinbase: coinbaseAddr,
      excessBlobGas: Opt.some(0'u64),
      slotNumber: Opt.some(1'u64),
    ),
  )

proc makeTxs(env: Env, kind: Kind, n: int): seq[Transaction] =
  for i in 0 ..< n:
    var tx = Transaction(
      txType: TxEip1559,
      chainId: env.com.chainId,
      nonce: AccountNonce(i div numSenders),
      maxPriorityFeePerGas: 1_000_000_000.GasInt,
      maxFeePerGas: 2_000_000_000.GasInt,
      gasLimit: 10_000_000.GasInt,
      R: 1.u256,
      S: 1.u256,
    )
    case kind
    of Transfer:
      tx.gasLimit = 100_000.GasInt
      tx.to = Opt.some(recipients[i mod numRecipients])
      tx.value = 1.u256
    of Token:
      tx.to = Opt.some(tokenAddr)
      tx.payload = @(recipients[i mod numRecipients].to(Bytes32).data)
    of CallChain:
      tx.to = Opt.some(chainAddrs[0])
    of Reverts:
      tx.to = Opt.some(revertParent)
    of Reads:
      tx.to = Opt.some(readerAddr)
    of Storage:
      tx.to = Opt.some(writerAddr)
      tx.payload = @((i + 1).u256.toBytesBE)
    of CreateDestroy:
      tx.to = Opt.some(factoryAddr)
    result.add tx

proc runBlock(env: Env, txs: seq[Transaction], withTracker: bool): RunResult =
  let
    frame = env.setupFrame.txFrameBegin()
    vmState = BaseVMState.new(
      env.parent, env.header, env.com, frame, enableBalTracker = withTracker)
  doAssert vmState.fork >= FkAmsterdam
  if withTracker:
    vmState.balTracker.builder[].ensureIndexCount(txs.len + 2, exact = true)

  let t0 = getMonoTime()
  for i, tx in txs:
    if withTracker:
      vmState.balTracker.setBlockAccessIndex(i + 1)
    let rc = vmState.processTransaction(tx, senders[i mod numSenders])
    doAssert rc.isOk, rc.error
  let t1 = getMonoTime()
  result.nanos = (t1 - t0).inNanoseconds

  if withTracker:
    let bal = vmState.balTracker.getBlockAccessList().get()
    result.buildNanos = (getMonoTime() - t1).inNanoseconds
    result.accounts = bal[].len
    result.hash = $bal[].computeBlockAccessListHash()

  vmState.dispose()
  frame.dispose()

suite "BlockAccessListTracker end-to-end benchmark":
  let env = initEnv()

  debugEcho ""
  debugEcho "  ", alignLeft("scenario", 16), " ", align("txs", 6), " ",
    align("off ns/tx", 11), " ", align("on ns/tx", 11), " ", align("tracker ns/tx", 14),
    " ", align("overhead", 9), " ", align("build ms", 9), " ", align("accts", 6), "  bal hash"

  for (kind, name, numTx) in workloads:
    test name:
      let txs = env.makeTxs(kind, numTx)
      discard env.runBlock(txs, false)
      discard env.runBlock(txs, true)

      var
        bestOff = int64.high
        bestOn = int64.high
        bestBuild = int64.high
        reference: RunResult
      for r in 0 ..< repeats:
        let off = env.runBlock(txs, false)
        bestOff = min(bestOff, off.nanos)
        let on = env.runBlock(txs, true)
        bestOn = min(bestOn, on.nanos)
        bestBuild = min(bestBuild, on.buildNanos)
        if r == 0:
          reference = on
        check on.hash == reference.hash

      let
        offPerTx = bestOff.float / numTx.float
        onPerTx = bestOn.float / numTx.float
      debugEcho "  ", alignLeft(name, 16), " ", align($numTx, 6), " ",
        align(fmt"{offPerTx:.0f}", 11), " ", align(fmt"{onPerTx:.0f}", 11), " ",
        align(fmt"{onPerTx - offPerTx:.0f}", 14), " ",
        align(fmt"{(onPerTx / offPerTx - 1.0) * 100.0:.1f}%", 9), " ",
        align(fmt"{bestBuild.float / 1e6:.2f}", 9), " ", align($reference.accounts, 6),
        "  ", reference.hash[0 ..< 18]
