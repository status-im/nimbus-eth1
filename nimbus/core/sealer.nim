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
  std/[sequtils, times, typetraits],
  pkg/[chronos,
    stew/results,
    chronicles,
    eth/keys,
    eth/rlp],
  ".."/[config,
    constants],
  "."/[
    chain,
    tx_pool,
    casper,
    validate],
  "."/clique/[
    clique_desc,
    clique_cfg,
    clique_sealer],
  ../utils/utils,
  ../common/[common, context]


from web3/ethtypes as web3types import nil, TypedTransaction, WithdrawalV1, ExecutionPayloadV1OrV2, toExecutionPayloadV1OrV2, toExecutionPayloadV1
from web3/engine_api_types import PayloadAttributesV1, ExecutionPayloadV1, PayloadAttributesV2, ExecutionPayloadV2

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
    chain*: ChainRef
    ctx: EthContext
    signer: EthAddress
    txPool: TxPoolRef

proc validateSealer*(conf: NimbusConf, ctx: EthContext, chain: ChainRef): Result[void, string] =
  if conf.engineSigner == ZERO_ADDRESS:
    return err("signer address should not zero, use --engine-signer to set signer address")

  let res = ctx.am.getAccount(conf.engineSigner)
  if res.isErr:
    return err("signer address not in registered accounts, use --import-key/account to register the account")

  let acc = res.get()
  if not acc.unlocked:
    return err("signer account not unlocked, please unlock it first via rpc/password file")

  let com = chain.com
  if com.consensus != ConsensusType.POA:
    return err("currently only PoA engine is supported")

  ok()

proc generateBlock(engine: SealingEngineRef,
                   outBlock: var EthBlock): Result[void, string] =

  outBlock = engine.txPool.ethBlock()
  if engine.chain.com.consensus == ConsensusType.POS:
    # Stop the block generator if we reach TTD
    engine.state = EnginePostMerge

  if engine.state != EnginePostMerge:
    # Post merge, Clique should not be executing
    let sealRes = engine.chain.clique.seal(outBlock)
    if sealRes.isErr:
      return err("error sealing block header: " & $sealRes.error)

  debug "generated block",
        blockNumber = outBlock.header.blockNumber,
        blockHash = blockHash(outBlock.header)

  ok()

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

proc toTypedTransaction(tx: Transaction): TypedTransaction =
  web3types.TypedTransaction(rlp.encode(tx))

proc generateExecutionPayload*(engine: SealingEngineRef,
                               payloadAttrs: PayloadAttributesV1 | PayloadAttributesV2): Result[ExecutionPayloadV1OrV2, string] =
  let
    headBlock = try: engine.chain.db.getCanonicalHead()
                except CatchableError: return err "No head block in database"
    pos = engine.chain.com.pos

  pos.prevRandao   = Hash256(data: distinctBase payloadAttrs.prevRandao)
  pos.timestamp    = fromUnix(payloadAttrs.timestamp.unsafeQuantityToInt64)
  pos.feeRecipient = EthAddress payloadAttrs.suggestedFeeRecipient

  if headBlock.blockHash != engine.txPool.head.blockHash:
    # reorg
    discard engine.txPool.smartHead(headBlock)

  var blk: EthBlock
  let res = engine.generateBlock(blk)
  if res.isErr:
    error "sealing engine generateBlock error", msg = res.error
    return err(res.error)

  # make sure both generated block header and payloadRes(ExecutionPayloadV2)
  # produce the same blockHash
  blk.header.fee = some(blk.header.fee.get(UInt256.zero)) # force it with some(UInt256)

  let blockHash = rlpHash(blk.header)
  if blk.header.extraData.len > 32:
    return err "extraData length should not exceed 32 bytes"

  let transactions = blk.txs.map(toTypedTransaction)

  let withdrawals =
    when payloadAttrs is PayloadAttributesV2:
      some(payloadAttrs.withdrawals)
    else:
      none[seq[WithdrawalV1]]()

  return ok(ExecutionPayloadV1OrV2(
    parentHash: Web3BlockHash blk.header.parentHash.data,
    feeRecipient: Web3Address blk.header.coinbase,
    stateRoot: Web3BlockHash blk.header.stateRoot.data,
    receiptsRoot: Web3BlockHash blk.header.receiptRoot.data,
    logsBloom: Web3Bloom blk.header.bloom,
    prevRandao: payloadAttrs.prevRandao,
    blockNumber: Web3Quantity blk.header.blockNumber.truncate(uint64),
    gasLimit: Web3Quantity blk.header.gasLimit,
    gasUsed: Web3Quantity blk.header.gasUsed,
    timestamp: payloadAttrs.timestamp,
    extraData: web3types.DynamicBytes[0, 32] blk.header.extraData,
    baseFeePerGas: blk.header.fee.get(UInt256.zero),
    blockHash: Web3BlockHash blockHash.data,
    transactions: transactions,
    withdrawals: withdrawals
  ))

proc generateExecutionPayloadV1*(engine: SealingEngineRef,
                                 payloadAttrs: PayloadAttributesV1): Result[ExecutionPayloadV1, string] =
  return generateExecutionPayload(engine, payloadAttrs).map(toExecutionPayloadV1)

proc new*(_: type SealingEngineRef,
          chain: ChainRef,
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
