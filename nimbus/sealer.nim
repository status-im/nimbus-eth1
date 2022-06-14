# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[times, tables, typetraits, options],
  pkg/[chronos,
    stew/results,
    stew/byteutils,
    chronicles,
    eth/common,
    eth/keys,
    eth/rlp],
  "."/[config,
    db/db_chain,
    p2p/chain,
    constants,
    utils/header],
  "."/p2p/clique/[clique_defs,
    clique_desc,
    clique_cfg,
    clique_sealer],
  ./p2p/[gaslimit, validate],
  "."/[chain_config, utils, context],
  "."/utils/tx_pool

from web3/ethtypes as web3types import nil
from web3/engine_api_types import PayloadAttributesV1, ExecutionPayloadV1

type
  EngineState* = enum
    EngineStopped,
    EngineRunning,
    EnginePostMerge

  Web3BlockHash = web3types.BlockHash
  Web3Address = web3types.Address
  Web3Bloom = web3types.FixedBytes[256]
  Web3Quantity = web3types.Quantity

  SealingEngineRef* = ref SealingEngineObj
  SealingEngineObj = object of RootObj
    state: EngineState
    engineLoop: Future[void]
    chain*: Chain
    ctx: EthContext
    signer: EthAddress
    txPool: TxPoolRef

template asEthHash(hash: Web3BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

proc validateSealer*(conf: NimbusConf, ctx: EthContext, chain: Chain): Result[void, string] =
  if conf.engineSigner == ZERO_ADDRESS:
    return err("signer address should not zero, use --engine-signer to set signer address")

  let res = ctx.am.getAccount(conf.engineSigner)
  if res.isErr:
    return err("signer address not in registered accounts, use --import-key/account to register the account")

  let acc = res.get()
  if not acc.unlocked:
    return err("signer account not unlocked, please unlock it first via rpc/password file")

  let chainConf = chain.db.config
  if not chainConf.poaEngine:
    return err("currently only PoA engine is supported")

  ok()

proc isLondon(c: ChainConfig, number: BlockNumber): bool {.inline.} =
  number >= c.londonBlock

proc prepareBlock(engine: SealingEngineRef,
                   parent: BlockHeader,
                   time: Time,
                   prevRandao: Hash256): Result[EthBlock, string] =
  let timestamp = if parent.timestamp >= time:
                    parent.timestamp + 1.seconds
                  else:
                    time

  engine.txPool.prevRandao = prevRandao

  var blk = engine.txPool.ethBlock()

  # TODO: fix txPool GasLimit to match this GasLimit
  let conf = engine.chain.db.config
  if isLondon(conf, blk.header.blockNumber):
    var parentGasLimit = parent.gasLimit
    if not isLondon(conf, parent.blockNumber):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    # TODO: desiredLimit can be configured by user, gasCeil
    blk.header.gasLimit = calcGasLimit1559(parentGasLimit, desiredLimit = DEFAULT_GAS_LIMIT)
  else:
    blk.header.gasLimit = computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = DEFAULT_GAS_LIMIT,
      gasCeil = DEFAULT_GAS_LIMIT)

  if engine.chain.isBlockAfterTtd(blk.header):
    blk.header.difficulty = DifficultyInt.zero
    blk.header.mixDigest = prevRandao
    blk.header.nonce = default(BlockNonce)
    blk.header.extraData = @[] # TODO: probably this should be configurable by user?
    # Stop the block generator if we reach TTD
    engine.state = EnginePostMerge
  else:
    let res = engine.chain.clique.prepare(parent, blk.header)
    if res.isErr:
      return err($res.error)

  ok(blk)

proc generateBlock(engine: SealingEngineRef,
                   parentBlockHeader: BlockHeader,
                   outBlock: var EthBlock,
                   timestamp = getTime(),
                   prevRandao = Hash256()): Result[void, string] =
  # deviation from standard block generator
  # - no DAO hard fork
  # - no local and remote uncles inclusion

  let res = prepareBlock(engine, parentBlockHeader, timestamp, prevRandao)
  if res.isErr:
    return err("error prepare header")

  outBlock = res.get()
  if engine.state != EnginePostMerge:
    # Post merge, Clique should not be executing
    let sealRes = engine.chain.clique.seal(outBlock)
    if sealRes.isErr:
      return err("error sealing block header: " & $sealRes.error)

  debug "generated block",
        blockNumber = outBlock.header.blockNumber,
        blockHash = blockHash(outBlock.header)

  ok()

proc generateBlock(engine: SealingEngineRef,
                   parentHash: Hash256,
                   outBlock: var EthBlock,
                   timestamp = getTime(),
                   prevRandao = Hash256()): Result[void, string] =
  var parentBlockHeader: BlockHeader
  if engine.chain.db.getBlockHeader(parentHash, parentBlockHeader):
    generateBlock(engine, parentBlockHeader, outBlock, timestamp, prevRandao)
  else:
    # TODO:
    # This hack shouldn't be necessary if the database can find
    # the genesis block hash in `getBlockHeader`.
    let maybeGenesisBlock = engine.chain.currentBlock()
    if parentHash == maybeGenesisBlock.blockHash:
      generateBlock(engine, maybeGenesisBlock, outBlock, timestamp, prevRandao)
    else:
      return err "parent block not found"

proc generateBlock(engine: SealingEngineRef,
                   outBlock: var EthBlock,
                   timestamp = getTime(),
                   prevRandao = Hash256()): Result[void, string] =
  generateBlock(engine, engine.chain.currentBlock(),
                outBlock, timestamp, prevRandao)

proc sealingLoop(engine: SealingEngineRef): Future[void] {.async.} =
  let clique = engine.chain.clique

  proc signerFunc(signer: EthAddress, message: openArray[byte]):
                  Result[RawSignature, cstring] {.gcsafe.} =
    let
      hashData = keccakHash(message)
      ctx      = engine.ctx
      acc      = ctx.am.getAccount(signer).tryGet()
      rawSign  = sign(acc.privateKey, SkMessage(hashData.data)).toRaw

    ok(rawSign)

  clique.authorize(engine.signer, signerFunc)

  proc diffCalculator(timeStamp: EthTime, parent: BlockHeader): DifficultyInt {.gcsafe, raises:[].}  =
    # pesky Nim effect system
    try:
      discard timestamp
      let rc = clique.calcDifficulty(parent)
      if rc.isErr:
        return 0.u256
      rc.get()
    except:
      0.u256

  # switch to PoA difficulty calculator
  engine.txPool.calcDifficulty = diffCalculator

  # convert times.Duration to chronos.Duration
  let period = chronos.seconds(clique.cfg.period.inSeconds)

  while engine.state == EngineRunning:
    # the sealing engine will tick every `cliquePeriod` seconds
    await sleepAsync(period)

    if engine.state != EngineRunning:
      break

    # deviation from 'correct' sealing engine:
    # - no queue for chain reorgs
    # - no async lock/guard against race with sync algo
    var blk: EthBlock
    let blkRes = engine.generateBlock(blk)
    if blkRes.isErr:
      error "sealing engine generateBlock error", msg=blkRes.error
      break

    let res = engine.chain.persistBlocks([blk.header], [
      BlockBody(transactions: blk.txs, uncles: blk.uncles)
    ])

    if res == ValidationResult.Error:
      error "sealing engine: persistBlocks error"
      break

    discard engine.txPool.smartHead(blk.header) # add transactions update jobs
    info "block generated", number=blk.header.blockNumber

template unsafeQuantityToInt64(q: web3types.Quantity): int64 =
  int64 q

proc generateExecutionPayload*(engine: SealingEngineRef,
                               payloadAttrs: PayloadAttributesV1,
                               payloadRes: var ExecutionPayloadV1): Result[void, string] =
  let
    headBlock = try: engine.chain.db.getCanonicalHead()
                except CatchableError: return err "No head block in database"
    prevRandao = Hash256(data: distinctBase payloadAttrs.prevRandao)
    timestamp = fromUnix(payloadAttrs.timestamp.unsafeQuantityToInt64)
    coinbase = EthAddress payloadAttrs.suggestedFeeRecipient

  if headBlock.blockHash != engine.txPool.head.blockHash:
    # reorg
    discard engine.txPool.smartHead(headBlock)

  var blk: EthBlock
  engine.txPool.feeRecipient = coinbase

  let blkRes = engine.generateBlock(
    headBlock,
    blk,
    timestamp,
    prevRandao)

  if blkRes.isErr:
    error "sealing engine generateBlock error", msg = blkRes.error
    return blkRes

  # make sure both generated block header and payloadRes(ExecutionPayloadV1)
  # produce the same blockHash
  doAssert blk.header.coinbase == coinbase
  blk.header.timestamp = timestamp
  blk.header.prevRandao = prevRandao
  blk.header.fee = some(blk.header.fee.get(UInt256.zero)) # force it with some(UInt256)

  let res = engine.chain.persistBlocks([blk.header], [
    BlockBody(transactions: blk.txs, uncles: blk.uncles)
  ])

  let blockHash = rlpHash(blk.header)
  if res != ValidationResult.OK:
    return err("Error when validating generated block. hash=" & blockHash.data.toHex)

  if blk.header.extraData.len > 32:
    return err "extraData length should not exceed 32 bytes"

  discard engine.txPool.smartHead(blk.header) # add transactions update jobs

  payloadRes.parentHash = Web3BlockHash blk.header.parentHash.data
  payloadRes.feeRecipient = Web3Address blk.header.coinbase
  payloadRes.stateRoot = Web3BlockHash blk.header.stateRoot.data
  payloadRes.receiptsRoot = Web3BlockHash blk.header.receiptRoot.data
  payloadRes.logsBloom = Web3Bloom blk.header.bloom
  payloadRes.prevRandao = payloadAttrs.prevRandao
  payloadRes.blockNumber = Web3Quantity blk.header.blockNumber.truncate(uint64)
  payloadRes.gasLimit = Web3Quantity blk.header.gasLimit
  payloadRes.gasUsed = Web3Quantity blk.header.gasUsed
  payloadRes.timestamp = payloadAttrs.timestamp
  payloadRes.extraData = web3types.DynamicBytes[0, 32] blk.header.extraData
  payloadRes.baseFeePerGas = blk.header.fee.get(UInt256.zero)
  payloadRes.blockHash = Web3BlockHash blockHash.data

  for tx in blk.txs:
    let txData = rlp.encode(tx)
    payloadRes.transactions.add web3types.TypedTransaction(txData)

  return ok()

proc new*(_: type SealingEngineRef,
          chain: Chain,
          ctx: EthContext,
          signer: EthAddress,
          txPool: TxPoolRef,
          initialState: EngineState): SealingEngineRef =
  SealingEngineRef(
    chain: chain,
    ctx: ctx,
    signer: signer,
    txPool: txPool,
    state: initialState
  )

proc start*(engine: SealingEngineRef) =
  ## Starts sealing engine.
  if engine.state == EngineStopped:
    engine.state = EngineRunning
    engine.engineLoop = sealingLoop(engine)
    info "sealing engine started"

proc stop*(engine: SealingEngineRef) {.async.} =
  ## Stop sealing engine from producing more blocks.
  if engine.state == EngineRunning:
    engine.state = EngineStopped
    await engine.engineLoop.cancelAndWait()
    info "sealing engine stopped"
