# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, tables, os, streams],
  eth/[rlp, trie, eip1559],
  stint, results,
  "."/[config, types, helpers],
  ../common/state_clearing,
  ../../nimbus/[evm/types, evm/state, transaction],
  ../../nimbus/common/common,
  ../../nimbus/db/ledger,
  ../../nimbus/utils/utils,
  ../../nimbus/core/pow/difficulty,
  ../../nimbus/core/dao,
  ../../nimbus/core/executor/[process_transaction, executor_helpers],
  ../../nimbus/core/eip4844,
  ../../nimbus/evm/tracer/json_tracer

const
  wrapExceptionEnabled* {.booldefine.} = true
  stdinSelector = "stdin"

type
  Dispatch = object
    stdout: JsonNode
    stderr: JsonNode

  ExecOutput = object
    result: ExecutionResult
    alloc: GenesisAlloc

  TestVMState = ref object of BaseVMState
    blockHashes: Table[uint64, Hash256]
    hashError: string

proc init(_: type Dispatch): Dispatch =
  result.stdout = newJObject()
  result.stderr = newJObject()

proc dispatch(dis: var Dispatch, baseDir, fName, name: string, obj: JsonNode) =
  case fName
  of "stdout":
    dis.stdout[name] = obj
  of "stderr":
    dis.stderr[name] = obj
  of "":
    # don't save
    discard
  else:
    # save to file
    let path = if baseDir.len > 0:
                 baseDir / fName
               else:
                 fName
    writeFile(path, obj.pretty)

proc dispatchOutput(ctx: var TransContext, conf: T8NConf, res: ExecOutput) =
  var dis = Dispatch.init()
  createDir(conf.outputBaseDir)

  dis.dispatch(conf.outputBaseDir, conf.outputAlloc, "alloc", @@(res.alloc))
  dis.dispatch(conf.outputBaseDir, conf.outputResult, "result", @@(res.result))

  let chainId = conf.stateChainId.ChainId
  let txList = ctx.txList(chainId)

  let body = @@(rlp.encode(txList))
  dis.dispatch(conf.outputBaseDir, conf.outputBody, "body", body)

  if dis.stdout.len > 0:
    stdout.write(dis.stdout.pretty)
    stdout.write("\n")

  if dis.stderr.len > 0:
    stderr.write(dis.stderr.pretty)
    stderr.write("\n")

proc calcWithdrawalsRoot(w: Opt[seq[Withdrawal]]): Opt[Hash256] =
  if w.isNone:
    return Opt.none(Hash256)
  Opt.some calcWithdrawalsRoot(w.get)

proc envToHeader(env: EnvStruct): BlockHeader =
  BlockHeader(
    coinbase   : env.currentCoinbase,
    difficulty : env.currentDifficulty.get(0.u256),
    mixHash    : env.currentRandom.get(Hash256()),
    number     : env.currentNumber,
    gasLimit   : env.currentGasLimit,
    timestamp  : env.currentTimestamp,
    stateRoot  : emptyRlpHash,
    baseFeePerGas  : env.currentBaseFee,
    withdrawalsRoot: env.withdrawals.calcWithdrawalsRoot(),
    blobGasUsed    : env.currentBlobGasUsed,
    excessBlobGas  : env.currentExcessBlobGas,
  )

proc postState(db: LedgerRef, alloc: var GenesisAlloc) =
  for accAddr in db.addresses():
    var acc = GenesisAccount(
      code: db.getCode(accAddr).bytes(),
      balance: db.getBalance(accAddr),
      nonce: db.getNonce(accAddr)
    )

    for k, v in db.storage(accAddr):
      acc.storage[k] = v
    alloc[accAddr] = acc

proc genAddress(tx: Transaction, sender: EthAddress): EthAddress =
  if tx.to.isNone:
    result = generateAddress(sender, tx.nonce)

proc toTxReceipt(rec: Receipt,
                 tx: Transaction,
                 sender: EthAddress,
                 txIndex: int,
                 gasUsed: GasInt): TxReceipt =

  let contractAddress = genAddress(tx, sender)
  TxReceipt(
    txType: tx.txType,
    root: if rec.isHash: rec.hash else: Hash256(),
    status: rec.status,
    cumulativeGasUsed: rec.cumulativeGasUsed,
    logsBloom: rec.logsBloom,
    logs: rec.logs,
    transactionHash: rlpHash(tx),
    contractAddress: contractAddress,
    gasUsed: gasUsed,
    blockHash: Hash256(),
    transactionIndex: txIndex
  )

proc calcLogsHash(receipts: openArray[Receipt]): Hash256 =
  var logs: seq[Log]
  for rec in receipts:
    logs.add rec.logs
  rlpHash(logs)

proc defaultTraceStreamFilename(conf: T8NConf,
                                txIndex: int,
                                txHash: Hash256): (string, string) =
  let
    txHash = "0x" & toLowerAscii($txHash)
    baseDir = if conf.outputBaseDir.len > 0:
                conf.outputBaseDir
              else:
                "."
    fName = "$1/trace-$2-$3.jsonl" % [baseDir, $txIndex, txHash]
  (baseDir, fName)

proc defaultTraceStream(conf: T8NConf, txIndex: int, txHash: Hash256): Stream =
  let (baseDir, fName) = defaultTraceStreamFilename(conf, txIndex, txHash)
  createDir(baseDir)
  newFileStream(fName, fmWrite)

proc traceToFileStream(path: string, txIndex: int): Stream =
  # replace whatever `.ext` to `-${txIndex}.jsonl`
  let
    file = path.splitFile
    fName = "$1/$2-$3.jsonl" % [file.dir, file.name, $txIndex]
  createDir(file.dir)
  newFileStream(fName, fmWrite)

proc setupTrace(conf: T8NConf, txIndex: int, txHash: Hash256, vmState: BaseVMState) =
  var tracerFlags = {
    TracerFlags.DisableMemory,
    TracerFlags.DisableStorage,
    TracerFlags.DisableState,
    TracerFlags.DisableStateDiff,
    TracerFlags.DisableReturnData
  }

  if conf.traceMemory: tracerFlags.excl TracerFlags.DisableMemory
  if conf.traceNostack: tracerFlags.incl TracerFlags.DisableStack
  if conf.traceReturnData: tracerFlags.excl TracerFlags.DisableReturnData

  let traceMode = conf.traceEnabled.get
  let stream = if traceMode == "stdout":
                 newFileStream(stdout)
               elif traceMode == "stderr":
                 newFileStream(stderr)
               elif traceMode.len > 0:
                 traceToFileStream(traceMode, txIndex)
               else:
                 defaultTraceStream(conf, txIndex, txHash)

  if stream.isNil:
    let traceLoc =
      if traceMode.len > 0:
        traceMode
      else:
        defaultTraceStreamFilename(conf, txIndex, txHash)[1]
    raise newError(ErrorConfig, "Unable to open tracer stream: " & traceLoc)

  vmState.tracer = newJsonTracer(stream, tracerFlags, false)

proc closeTrace(vmState: BaseVMState) =
  let tracer = JsonTracer(vmState.tracer)
  if tracer.isNil.not:
    tracer.close()

proc exec(ctx: var TransContext,
          vmState: BaseVMState,
          stateReward: Option[UInt256],
          header: BlockHeader,
          conf: T8NConf): ExecOutput =

  let txList = ctx.parseTxs(vmState.com.chainId)

  var
    receipts = newSeqOfCap[TxReceipt](txList.len)
    rejected = newSeq[RejectedTx]()
    includedTx = newSeq[Transaction]()

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == vmState.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  vmState.receipts = newSeqOfCap[Receipt](txList.len)
  vmState.cumulativeGasUsed = 0

  if ctx.env.parentBeaconBlockRoot.isSome:
    vmState.processBeaconBlockRoot(ctx.env.parentBeaconBlockRoot.get).isOkOr:
      raise newError(ErrorConfig, error)

  for txIndex, txRes in txList:
    if txRes.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: txRes.error
      )
      continue

    let tx = txRes.get
    var sender: EthAddress
    if not tx.getSender(sender):
      rejected.add RejectedTx(
        index: txIndex,
        error: "Could not get sender"
      )
      continue

    if conf.traceEnabled.isSome:
      setupTrace(conf, txIndex, rlpHash(tx), vmState)

    let rc = vmState.processTransaction(tx, sender, header)

    if conf.traceEnabled.isSome:
      closeTrace(vmState)

    if rc.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: rc.error
      )
      continue

    let gasUsed = rc.get()
    let rec = vmState.makeReceipt(tx.txType)
    vmState.receipts.add rec
    receipts.add toTxReceipt(
      rec, tx, sender, txIndex, gasUsed
    )
    includedTx.add tx

  # Add mining reward? (-1 means rewards are disabled)
  if stateReward.isSome and stateReward.get >= 0:
    # Add mining reward. The mining reward may be `0`, which only makes a difference in the cases
    # where
    # - the coinbase suicided, or
    # - there are only 'bad' transactions, which aren't executed. In those cases,
    #   the coinbase gets no txfee, so isn't created, and thus needs to be touched
    let blockReward = stateReward.get()
    var mainReward = blockReward
    for uncle in ctx.env.ommers:
      var uncleReward = 8.u256 - uncle.delta.u256
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      vmState.mutateStateDB:
        db.addBalance(uncle.address, uncleReward)
      mainReward += blockReward div 32.u256

    vmState.mutateStateDB:
      db.addBalance(ctx.env.currentCoinbase, mainReward)

  if ctx.env.withdrawals.isSome:
    for withdrawal in ctx.env.withdrawals.get:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)

  let miner = ctx.env.currentCoinbase
  let fork = vmState.com.toEVMFork
  coinbaseStateClearing(vmState, miner, fork, stateReward.isSome())

  let stateDB = vmState.stateDB
  stateDB.postState(result.alloc)
  result.result = ExecutionResult(
    stateRoot   : stateDB.rootHash,
    txRoot      : includedTx.calcTxRoot,
    receiptsRoot: calcReceiptsRoot(vmState.receipts),
    logsHash    : calcLogsHash(vmState.receipts),
    logsBloom   : createBloom(vmState.receipts),
    receipts    : system.move(receipts),
    rejected    : system.move(rejected),
    # geth using both vmContext.Difficulty and vmContext.Random
    # therefore we cannot use vmState.difficulty
    currentDifficulty: ctx.env.currentDifficulty,
    gasUsed          : vmState.cumulativeGasUsed,
    currentBaseFee   : ctx.env.currentBaseFee,
    withdrawalsRoot  : header.withdrawalsRoot
  )

  if fork >= FkCancun:
    result.result.blobGasUsed = Opt.some vmState.blobGasUsed
    if ctx.env.currentExcessBlobGas.isSome:
      result.result.currentExcessBlobGas = ctx.env.currentExcessBlobGas
    elif ctx.env.parentExcessBlobGas.isSome and ctx.env.parentBlobGasUsed.isSome:
      result.result.currentExcessBlobGas = Opt.some calcExcessBlobGas(vmState.parent)

template wrapException(body: untyped) =
  when wrapExceptionEnabled:
    try:
      body
    except IOError as e:
      raise newError(ErrorIO, e.msg)
    except RlpError as e:
      raise newError(ErrorRlp, e.msg)
    except ValueError as e:
      raise newError(ErrorJson, e.msg)
  else:
    body

proc setupAlloc(stateDB: LedgerRef, alloc: GenesisAlloc) =
  for accAddr, acc in alloc:
    stateDB.setNonce(accAddr, acc.nonce)
    stateDB.setCode(accAddr, acc.code)
    stateDB.setBalance(accAddr, acc.balance)

    for slot, value in acc.storage:
      stateDB.setStorage(accAddr, slot, value)

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash256 =
  # we can't raise exception here, it'll mess with EVM exception handler.
  # so, store the exception for later using `hashError`
  var h = Hash256()
  if vmState.blockHashes.len == 0:
    vmState.hashError = "getAncestorHash(" &
      $blockNumber & ") invoked, no blockhashes provided"
    return h

  vmState.blockHashes.withValue(blockNumber, val) do:
    h = val[]
  do:
    vmState.hashError = "getAncestorHash(" &
      $blockNumber & ") invoked, blockhash for that block not provided"

  return h

proc parseChainConfig(network: string): ChainConfig =
  try:
    result = getChainConfig(network)
  except ValueError as e:
    raise newError(ErrorConfig, e.msg)

proc calcBaseFee(env: EnvStruct): UInt256 =
  if env.parentGasUsed.isNone:
    raise newError(ErrorConfig,
      "'parentBaseFee' exists but missing 'parentGasUsed' in env section")

  if env.parentGasLimit.isNone:
    raise newError(ErrorConfig,
      "'parentBaseFee' exists but missing 'parentGasLimit' in env section")

  calcEip1599BaseFee(
    env.parentGasLimit.get,
    env.parentGasUsed.get,
    env.parentBaseFee.get)

proc transitionAction*(ctx: var TransContext, conf: T8NConf) =
  wrapException:
    if conf.inputAlloc.len == 0 and conf.inputEnv.len == 0 and conf.inputTxs.len == 0:
      raise newError(ErrorConfig, "either one of input is needeed(alloc, txs, or env)")

    let config = parseChainConfig(conf.stateFork)
    config.chainId = conf.stateChainId.ChainId

    let com = CommonRef.new(newCoreDbRef DefaultDbMemory, config)

    # We need to load three things: alloc, env and transactions.
    # May be either in stdin input or in files.

    if conf.inputAlloc == stdinSelector or
       conf.inputEnv == stdinSelector or
       conf.inputTxs == stdinSelector:
      ctx.parseInputFromStdin()

    if conf.inputAlloc != stdinSelector and conf.inputAlloc.len > 0:
      let n = json.parseFile(conf.inputAlloc)
      ctx.parseAlloc(n)

    if conf.inputEnv != stdinSelector and conf.inputEnv.len > 0:
      let n = json.parseFile(conf.inputEnv)
      ctx.parseEnv(n)

    if conf.inputTxs != stdinSelector and conf.inputTxs.len > 0:
      if conf.inputTxs.endsWith(".rlp"):
        let data = readFile(conf.inputTxs)
        ctx.parseTxsRlp(data.strip(chars={'"'}))
      else:
        let n = json.parseFile(conf.inputTxs)
        ctx.parseTxs(n)

    let uncleHash = if ctx.env.parentUncleHash == Hash256():
                      EMPTY_UNCLE_HASH
                    else:
                      ctx.env.parentUncleHash

    let parent = BlockHeader(
      stateRoot: emptyRlpHash,
      timestamp: ctx.env.parentTimestamp,
      difficulty: ctx.env.parentDifficulty.get(0.u256),
      ommersHash: uncleHash,
      number: ctx.env.currentNumber - 1'u64,
      blobGasUsed: ctx.env.parentBlobGasUsed,
      excessBlobGas: ctx.env.parentExcessBlobGas,
    )

    # Sanity check, to not `panic` in state_transition
    if com.isLondon(ctx.env.currentNumber):
      if ctx.env.currentBaseFee.isSome:
        # Already set, currentBaseFee has precedent over parentBaseFee.
        discard
      elif ctx.env.parentBaseFee.isSome:
        ctx.env.currentBaseFee = Opt.some(calcBaseFee(ctx.env))
      else:
        raise newError(ErrorConfig, "EIP-1559 config but missing 'currentBaseFee' in env section")

    if com.isShanghaiOrLater(ctx.env.currentTimestamp) and ctx.env.withdrawals.isNone:
      raise newError(ErrorConfig, "Shanghai config but missing 'withdrawals' in env section")

    if com.isCancunOrLater(ctx.env.currentTimestamp):
      if ctx.env.parentBeaconBlockRoot.isNone:
        raise newError(ErrorConfig, "Cancun config but missing 'parentBeaconBlockRoot' in env section")

      let res = loadKzgTrustedSetup()
      if res.isErr:
        raise newError(ErrorConfig, res.error)
    else:
      # un-set it if it has been set too early
      ctx.env.parentBeaconBlockRoot = Opt.none(Hash256)

    if com.forkGTE(MergeFork):
      if ctx.env.currentRandom.isNone:
        raise newError(ErrorConfig, "post-merge requires currentRandom to be defined in env")

      if ctx.env.currentDifficulty.isSome and ctx.env.currentDifficulty.get() != 0:
        raise newError(ErrorConfig, "post-merge difficulty must be zero (or omitted) in env")
      ctx.env.currentDifficulty = Opt.none(DifficultyInt)

    elif ctx.env.currentDifficulty.isNone:
      if ctx.env.parentDifficulty.isNone:
        raise newError(ErrorConfig, "currentDifficulty was not provided, and cannot be calculated due to missing parentDifficulty")

      if ctx.env.currentNumber == 0.BlockNumber:
        raise newError(ErrorConfig, "currentDifficulty needs to be provided for block number 0")

      if ctx.env.currentTimestamp <= ctx.env.parentTimestamp:
        raise newError(ErrorConfig,
          "currentDifficulty cannot be calculated -- currentTime ($1) needs to be after parent time ($2)" %
            [$ctx.env.currentTimestamp, $ctx.env.parentTimestamp])

      ctx.env.currentDifficulty = Opt.some(calcDifficulty(com,
        ctx.env.currentTimestamp, parent))

    let header  = envToHeader(ctx.env)

    let vmState = TestVMState(
      blockHashes: ctx.env.blockHashes,
      hashError: ""
    )

    vmState.init(
      parent      = parent,
      header      = header,
      com         = com
    )

    vmState.mutateStateDB:
      db.setupAlloc(ctx.alloc)
      db.persist(clearEmptyAccount = false)

    let res = exec(ctx, vmState, conf.stateReward, header, conf)

    if vmState.hashError.len > 0:
      raise newError(ErrorMissingBlockhash, vmState.hashError)

    ctx.dispatchOutput(conf, res)
