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
  eth/common/transaction_utils,
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
  ../../nimbus/core/eip6110,
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
    blockHashes: Table[uint64, Hash32]
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

proc dispatchOutput(ctx: TransContext, conf: T8NConf, res: ExecOutput) =
  var dis = Dispatch.init()
  createDir(conf.outputBaseDir)

  dis.dispatch(conf.outputBaseDir, conf.outputAlloc, "alloc", @@(res.alloc))
  dis.dispatch(conf.outputBaseDir, conf.outputResult, "result", @@(res.result))

  let txList = ctx.filterGoodTransactions()
  let body = @@(rlp.encode(txList))
  dis.dispatch(conf.outputBaseDir, conf.outputBody, "body", body)

  if dis.stdout.len > 0:
    stdout.write(dis.stdout.pretty)
    stdout.write("\n")

  if dis.stderr.len > 0:
    stderr.write(dis.stderr.pretty)
    stderr.write("\n")

proc calcWithdrawalsRoot(w: Opt[seq[Withdrawal]]): Opt[Hash32] =
  if w.isNone:
    return Opt.none(Hash32)
  Opt.some calcWithdrawalsRoot(w.get)

proc envToHeader(env: EnvStruct): Header =
  Header(
    coinbase   : env.currentCoinbase,
    difficulty : env.currentDifficulty.get(0.u256),
    mixHash    : env.currentRandom.get(default(Bytes32)),
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

proc genAddress(tx: Transaction, sender: Address): Address =
  if tx.to.isNone:
    result = generateAddress(sender, tx.nonce)

proc toTxReceipt(rec: Receipt,
                 tx: Transaction,
                 sender: Address,
                 txIndex: int,
                 gasUsed: GasInt): TxReceipt =

  let contractAddress = genAddress(tx, sender)
  TxReceipt(
    txType: tx.txType,
    root: if rec.isHash: rec.hash else: default(Hash32),
    status: rec.status,
    cumulativeGasUsed: rec.cumulativeGasUsed,
    logsBloom: rec.logsBloom,
    logs: rec.logs,
    transactionHash: rlpHash(tx),
    contractAddress: contractAddress,
    gasUsed: gasUsed,
    blockHash: default(Hash32),
    transactionIndex: txIndex
  )

proc calcLogsHash(receipts: openArray[Receipt]): Hash32 =
  var logs: seq[Log]
  for rec in receipts:
    logs.add rec.logs
  rlpHash(logs)

proc defaultTraceStreamFilename(conf: T8NConf,
                                txIndex: int,
                                txHash: Hash32): (string, string) =
  let
    txHash = toLowerAscii($txHash)
    baseDir = if conf.outputBaseDir.len > 0:
                conf.outputBaseDir
              else:
                "."
    fName = "$1/trace-$2-$3.jsonl" % [baseDir, $txIndex, txHash]
  (baseDir, fName)

proc defaultTraceStream(conf: T8NConf, txIndex: int, txHash: Hash32): Stream =
  let (baseDir, fName) = defaultTraceStreamFilename(conf, txIndex, txHash)
  createDir(baseDir)
  newFileStream(fName, fmWrite)

proc traceToFileStream(path: string, txIndex: int): Stream =
  # replace whatever `.ext` to `-${txIndex}.jsonl`
  let
    file = path.splitFile
    folder = if file.dir.len == 0: "." else: file.dir
    fName = "$1/$2-$3.jsonl" % [folder, file.name, $txIndex]
  if file.dir.len > 0: createDir(file.dir)
  newFileStream(fName, fmWrite)

proc setupTrace(conf: T8NConf, txIndex: int, txHash: Hash32, vmState: BaseVMState): bool =
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

  var closeStream = true
  let traceMode = conf.traceEnabled.get
  let stream = if traceMode == "stdout":
                 # don't close stdout or stderr
                 closeStream = false
                 newFileStream(stdout)
               elif traceMode == "stderr":
                 closeStream = false
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
  closeStream

proc closeTrace(vmState: BaseVMState, closeStream: bool) =
  let tracer = JsonTracer(vmState.tracer)
  if tracer.isNil.not and closeStream:
    tracer.close()

proc exec(ctx: TransContext,
          vmState: BaseVMState,
          stateReward: Option[UInt256],
          header: Header,
          conf: T8NConf): ExecOutput =

  var
    receipts = newSeqOfCap[TxReceipt](ctx.txList.len)
    rejected = newSeq[RejectedTx]()
    includedTx = newSeq[Transaction]()

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == vmState.blockNumber:
    vmState.mutateLedger:
      db.applyDAOHardFork()

  vmState.receipts = newSeqOfCap[Receipt](ctx.txList.len)
  vmState.cumulativeGasUsed = 0

  if ctx.env.parentBeaconBlockRoot.isSome:
    vmState.processBeaconBlockRoot(ctx.env.parentBeaconBlockRoot.get).isOkOr:
      raise newError(ErrorConfig, error)

  if vmState.com.isPragueOrLater(ctx.env.currentTimestamp) and
     ctx.env.blockHashes.len > 0:
    let
      prevNumber = ctx.env.currentNumber - 1
      prevHash = ctx.env.blockHashes.getOrDefault(prevNumber)

    if prevHash == static(default(Hash32)):
      raise newError(ErrorConfig, "previous block hash not found for block number: " & $prevNumber)

    vmState.processParentBlockHash(prevHash).isOkOr:
      raise newError(ErrorConfig, error)

  for txIndex, txRes in ctx.txList:
    if txRes.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: txRes.error
      )
      continue

    let tx = txRes.get
    let sender = tx.recoverSender().valueOr:
      rejected.add RejectedTx(
        index: txIndex,
        error: "Could not get sender"
      )
      continue

    var closeStream = true
    if conf.traceEnabled.isSome:
      closeStream = setupTrace(conf, txIndex, rlpHash(tx), vmState)

    let rc = vmState.processTransaction(tx, sender, header)

    if conf.traceEnabled.isSome:
      closeTrace(vmState, closeStream)

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
      vmState.mutateLedger:
        db.addBalance(uncle.address, uncleReward)
      mainReward += blockReward div 32.u256

    vmState.mutateLedger:
      db.addBalance(ctx.env.currentCoinbase, mainReward)

  if ctx.env.withdrawals.isSome:
    for withdrawal in ctx.env.withdrawals.get:
      vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)

  let miner = ctx.env.currentCoinbase
  coinbaseStateClearing(vmState, miner, stateReward.isSome())

  var
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]

  if vmState.com.isPragueOrLater(ctx.env.currentTimestamp):
    # Execute EIP-7002 and EIP-7251 before calculating stateRoot
    withdrawalReqs = processDequeueWithdrawalRequests(vmState)
    consolidationReqs = processDequeueConsolidationRequests(vmState)

  let ledger = vmState.ledger
  ledger.postState(result.alloc)
  result.result = ExecutionResult(
    stateRoot   : ledger.getStateRoot(),
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

  var excessBlobGas = Opt.none(GasInt)
  if ctx.env.currentExcessBlobGas.isSome:
    excessBlobGas = ctx.env.currentExcessBlobGas
  elif ctx.env.parentExcessBlobGas.isSome and ctx.env.parentBlobGasUsed.isSome:
    excessBlobGas = Opt.some calcExcessBlobGas(vmState.parent, vmState.fork >= FkPrague)

  if excessBlobGas.isSome:
    result.result.blobGasUsed = Opt.some vmState.blobGasUsed
    result.result.currentExcessBlobGas = excessBlobGas

  if vmState.com.isPragueOrLater(ctx.env.currentTimestamp):
    var allLogs: seq[Log]
    for rec in result.result.receipts:
      allLogs.add rec.logs
    var
      depositReqs = parseDepositLogs(allLogs, vmState.com.depositContractAddress).valueOr:
        raise newError(ErrorEVM, error)
      executionRequests: seq[seq[byte]]

    template append(dst, reqType, reqData) =
      if reqData.len > 0:
        reqData.insert(reqType)
        dst.add(move(reqData))

    executionRequests.append(DEPOSIT_REQUEST_TYPE, depositReqs)
    executionRequests.append(WITHDRAWAL_REQUEST_TYPE, withdrawalReqs)
    executionRequests.append(CONSOLIDATION_REQUEST_TYPE, consolidationReqs)

    let requestsHash = calcRequestsHash(executionRequests)
    result.result.requestsHash = Opt.some(requestsHash)
    result.result.requests = Opt.some(executionRequests)

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

proc setupAlloc(ledger: LedgerRef, alloc: GenesisAlloc) =
  for accAddr, acc in alloc:
    ledger.setNonce(accAddr, acc.nonce)
    ledger.setCode(accAddr, acc.code)
    ledger.setBalance(accAddr, acc.balance)

    for slot, value in acc.storage:
      ledger.setStorage(accAddr, slot, value)

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash32 =
  # we can't raise exception here, it'll mess with EVM exception handler.
  # so, store the exception for later using `hashError`
  var h = default(Hash32)
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

    # We need to load three things: alloc, env and transactions.
    # May be either in stdin input or in files.

    if conf.inputAlloc == stdinSelector or
       conf.inputEnv == stdinSelector or
       conf.inputTxs == stdinSelector:
      ctx.parseInputFromStdin()

    if conf.inputAlloc != stdinSelector and conf.inputAlloc.len > 0:
      ctx.parseAlloc(conf.inputAlloc)

    if conf.inputEnv != stdinSelector and conf.inputEnv.len > 0:
      ctx.parseEnv(conf.inputEnv)

    if conf.inputTxs != stdinSelector and conf.inputTxs.len > 0:
      if conf.inputTxs.endsWith(".rlp"):
        let data = readFile(conf.inputTxs)
        ctx.parseTxsRlp(data.strip(chars={'"', ' ', '\r', '\n', '\t'}))
      else:
        ctx.parseTxsJson(conf.inputTxs)

    let uncleHash = if ctx.env.parentUncleHash == default(Hash32):
                      EMPTY_UNCLE_HASH
                    else:
                      ctx.env.parentUncleHash

    let parent = Header(
      stateRoot: emptyRlpHash,
      timestamp: ctx.env.parentTimestamp,
      difficulty: ctx.env.parentDifficulty.get(0.u256),
      ommersHash: uncleHash,
      number: ctx.env.currentNumber - 1'u64,
      blobGasUsed: ctx.env.parentBlobGasUsed,
      excessBlobGas: ctx.env.parentExcessBlobGas,
    )

    let config = parseChainConfig(conf.stateFork)
    config.depositContractAddress = ctx.env.depositContractAddress
    config.chainId = conf.stateChainId.ChainId

    let com = CommonRef.new(newCoreDbRef DefaultDbMemory, Taskpool.new(), config)

    # Sanity check, to not `panic` in state_transition
    if com.isLondonOrLater(ctx.env.currentNumber):
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
      ctx.env.parentBeaconBlockRoot = Opt.none(Hash32)

    let isMerged = config.terminalTotalDifficulty.isSome and
                   config.terminalTotalDifficulty.value == 0.u256
    if isMerged:
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

    # Calculate the excessBlobGas
    if ctx.env.currentExcessBlobGas.isNone:
      # If it is not explicitly defined, but we have the parent values, we try
      # to calculate it ourselves.
      if parent.excessBlobGas.isSome and parent.blobGasUsed.isSome:
        ctx.env.currentExcessBlobGas = Opt.some calcExcessBlobGas(parent, com.isPragueOrLater(ctx.env.currentTimestamp))

    let header  = envToHeader(ctx.env)

    let vmState = TestVMState(
      blockHashes: ctx.env.blockHashes,
      hashError: ""
    )

    vmState.init(
      parent      = parent,
      header      = header,
      com         = com,
      storeSlotHash = true
    )

    vmState.mutateLedger:
      db.setupAlloc(ctx.alloc)
      db.persist(clearEmptyAccount = false)

    ctx.parseTxs(com.chainId)
    let res = exec(ctx, vmState, conf.stateReward, header, conf)

    if vmState.hashError.len > 0:
      raise newError(ErrorMissingBlockhash, vmState.hashError)

    ctx.dispatchOutput(conf, res)
