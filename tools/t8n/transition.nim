import
  std/[json, strutils, times, tables, options, os],
  eth/[common, rlp, trie, trie/db],
  stint, chronicles, stew/results,
  "."/[config, types, helpers],
  ../../nimbus/[chain_config, vm_types, vm_state, utils, transaction],
  ../../nimbus/db/[db_chain, accounts_cache],
  ../../nimbus/utils/difficulty,
  ../../nimbus/p2p/dao,
  ../../nimbus/p2p/executor/[process_transaction, executor_helpers]

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

  let body = @@(rlp.encode(ctx.txs))
  dis.dispatch(conf.outputBaseDir, conf.outputBody, "body", body)

  if dis.stdout.len > 0:
    stdout.write(dis.stdout.pretty)
    stdout.write("\n")

  if dis.stderr.len > 0:
    stderr.write(dis.stderr.pretty)
    stderr.write("\n")

proc envToHeader(env: EnvStruct): BlockHeader =
  BlockHeader(
    coinbase   : env.currentCoinbase,
    difficulty : env.currentDifficulty.get(0.u256),
    mixDigest  : env.currentRandom.get(Hash256()),
    blockNumber: env.currentNumber,
    gasLimit   : env.currentGasLimit,
    timestamp  : env.currentTimestamp,
    stateRoot  : emptyRlpHash,
    fee        : env.currentBaseFee
  )

proc postState(db: AccountsCache, alloc: var GenesisAlloc) =
  for accAddr in db.addresses():
    var acc = GenesisAccount(
      code: db.getCode(accAddr),
      balance: db.getBalance(accAddr),
      nonce: db.getNonce(accAddr)
    )

    for k, v in db.storage(accAddr):
      acc.storage[k] = v
    alloc[accAddr] = acc

proc genAddress(vmState: BaseVMState, tx: Transaction, sender: EthAddress): EthAddress =
  if tx.to.isNone:
    let creationNonce = vmState.readOnlyStateDB().getNonce(sender)
    result = generateAddress(sender, creationNonce)

proc toTxReceipt(vmState: BaseVMState,
                 rec: Receipt,
                 tx: Transaction,
                 sender: EthAddress,
                 txIndex: int,
                 gasUsed: GasInt): TxReceipt =

  let contractAddress = genAddress(vmState, tx, sender)
  TxReceipt(
    txType: tx.txType,
    root: if rec.isHash: rec.hash else: Hash256(),
    status: rec.status,
    cumulativeGasUsed: rec.cumulativeGasUsed,
    logsBloom: rec.bloom,
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

proc dumpTrace(txIndex: int, txHash: Hash256, traceResult: JsonNode) =
  let fName = "trace-$1-$2.jsonl" % [$txIndex, $txHash]
  writeFile(fName, traceResult.pretty)

proc exec(ctx: var TransContext,
          vmState: BaseVMState,
          stateReward: Option[UInt256],
          header: BlockHeader): ExecOutput =

  var
    receipts = newSeqOfCap[TxReceipt](ctx.txs.len)
    rejected = newSeq[RejectedTx]()
    includedTx = newSeq[Transaction]()

  if vmState.chainDB.config.daoForkSupport and
     vmState.chainDB.config.daoForkBlock == vmState.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  vmState.receipts = newSeqOfCap[Receipt](ctx.txs.len)
  vmState.cumulativeGasUsed = 0

  for txIndex, tx in ctx.txs:
    var sender: EthAddress
    if not tx.getSender(sender):
      rejected.add RejectedTx(
        index: txIndex,
        error: "Could not get sender"
      )
      continue

    let rc = vmState.processTransaction(tx, sender, header)

    if vmState.tracingEnabled:
      dumpTrace(txIndex, rlpHash(tx), vmState.getTracingResult)

    if rc.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: "processTransaction failed"
      )
      continue

    let gasUsed = rc.get()
    let rec = vmState.makeReceipt(tx.txType)
    vmState.receipts.add rec
    receipts.add toTxReceipt(
      vmState, rec,
      tx, sender, txIndex, gasUsed
    )
    includedTx.add tx

  if stateReward.isSome:
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
      db.persist(clearCache = false)

  let stateDB = vmState.stateDB
  stateDB.postState(result.alloc)
  result.result = ExecutionResult(
    stateRoot   : stateDB.rootHash,
    txRoot      : includedTx.calcTxRoot,
    receiptsRoot: calcReceiptRoot(vmState.receipts),
    logsHash    : calcLogsHash(vmState.receipts),
    bloom       : createBloom(vmState.receipts),
    receipts    : system.move(receipts),
    rejected    : system.move(rejected),
    # geth using both vmContext.Difficulty and vmContext.Random
    # therefore we cannot use vmState.difficulty
    currentDifficulty: ctx.env.currentDifficulty,
    gasUsed     : vmState.cumulativeGasUsed
  )

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

proc setupAlloc(stateDB: AccountsCache, alloc: GenesisAlloc) =
  for accAddr, acc in alloc:
    stateDB.setNonce(accAddr, acc.nonce)
    stateDB.setCode(accAddr, acc.code)
    stateDB.setBalance(accAddr, acc.balance)

    for slot, value in acc.storage:
      stateDB.setStorage(accAddr, slot, value)

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  # we can't raise exception here, it'll mess with EVM exception handler.
  # so, store the exception for later using `hashError`

  let num = blockNumber.truncate(uint64)
  var h = Hash256()
  if vmState.blockHashes.len == 0:
    vmState.hashError = "getAncestorHash($1) invoked, no blockhashes provided" % [$num]
    return h

  if not vmState.blockHashes.take(num, h):
    vmState.hashError = "getAncestorHash($1) invoked, blockhash for that block not provided" % [$num]

  return h

proc transitionAction*(ctx: var TransContext, conf: T8NConf) =
  wrapException:
    var tracerFlags = {
      TracerFlags.DisableMemory,
      TracerFlags.DisableStorage,
      TracerFlags.DisableState,
      TracerFlags.DisableStateDiff,
      TracerFlags.DisableReturnData
    }

    if conf.traceEnabled:
      tracerFlags.incl TracerFlags.EnableTracing
      if conf.traceMemory: tracerFlags.excl TracerFlags.DisableMemory
      if conf.traceNostack: tracerFlags.incl TracerFlags.DisableStack
      if conf.traceReturnData: tracerFlags.excl TracerFlags.DisableReturnData

    if conf.inputAlloc.len == 0 and conf.inputEnv.len == 0 and conf.inputTxs.len == 0:
      raise newError(ErrorConfig, "either one of input is needeed(alloc, txs, or env)")

    let chainConfig = getChainConfig(conf.stateFork)
    chainConfig.chainId = conf.stateChainId.ChainId

    # We need to load three things: alloc, env and transactions.
    # May be either in stdin input or in files.

    if conf.inputAlloc == stdinSelector or
       conf.inputEnv == stdinSelector or
       conf.inputTxs == stdinSelector:
      ctx.parseInputFromStdin(chainConfig)

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
        ctx.parseTxs(n, chainConfig.chainId)

    let uncleHash = if ctx.env.parentUncleHash == Hash256():
                      EMPTY_UNCLE_HASH
                    else:
                      ctx.env.parentUncleHash

    let parent = BlockHeader(
      stateRoot: emptyRlpHash,
      timestamp: ctx.env.parentTimestamp,
      difficulty: ctx.env.parentDifficulty.get(0.u256),
      ommersHash: uncleHash,
      blockNumber: ctx.env.currentNumber - 1.toBlockNumber
    )

    # Sanity check, to not `panic` in state_transition
    if chainConfig.isLondon(ctx.env.currentNumber):
      if ctx.env.currentBaseFee.isNone:
        raise newError(ErrorConfig, "EIP-1559 config but missing 'currentBaseFee' in env section")

    let isMerged = chainConfig.terminalTotalDifficulty.isSome and
                     chainConfig.terminalTotalDifficulty.get() == 0

    if isMerged:
      if ctx.env.currentRandom.isNone:
        raise newError(ErrorConfig, "post-merge requires currentRandom to be defined in env")

      if ctx.env.currentDifficulty.isSome and ctx.env.currentDifficulty.get() != 0:
        raise newError(ErrorConfig, "post-merge difficulty must be zero (or omitted) in env")
      ctx.env.currentDifficulty = none(DifficultyInt)

    elif ctx.env.currentDifficulty.isNone:
      if ctx.env.parentDifficulty.isNone:
        raise newError(ErrorConfig, "currentDifficulty was not provided, and cannot be calculated due to missing parentDifficulty")

      if ctx.env.currentNumber == 0.toBlockNumber:
        raise newError(ErrorConfig, "currentDifficulty needs to be provided for block number 0")

      if ctx.env.currentTimestamp <= ctx.env.parentTimestamp:
        raise newError(ErrorConfig,
          "currentDifficulty cannot be calculated -- currentTime ($1) needs to be after parent time ($2)" %
            [$ctx.env.currentTimestamp, $ctx.env.parentTimestamp])

      ctx.env.currentDifficulty = some(calcDifficulty(chainConfig,
        ctx.env.currentTimestamp, parent))

    let
      chainDB = newBaseChainDB(newMemoryDb(), chainConfig, pruneTrie = true)
      header  = envToHeader(ctx.env)

    # set parent total difficulty
    chainDB.setScore(parent.blockHash, 0.u256)

    let vmState = TestVMState(
      blockHashes: system.move(ctx.env.blockHashes),
      hashError: ""
    )

    vmState.init(
      parent      = parent,
      header      = header,
      chainDB     = chainDB,
      tracerFlags = (if conf.traceEnabled: tracerFlags else: {}),
      pruneTrie   = chainDB.pruneTrie
    )

    vmState.mutateStateDB:
      db.setupAlloc(ctx.alloc)
      db.persist(clearCache = false)

    let res = exec(ctx, vmState, conf.stateReward, header)

    if vmState.hashError.len > 0:
      raise newError(ErrorMissingBlockhash, vmState.hashError)

    ctx.dispatchOutput(conf, res)
