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
  std/[times, tables, typetraits],
  pkg/[chronos, stew/results, chronicles, eth/common, eth/keys],
  "."/[config, db/db_chain, p2p/chain, constants, utils/header],
  "."/p2p/clique/[clique_defs,
    clique_desc,
    clique_cfg,
    clique_sealer],
  ./p2p/gaslimit,
  "."/[chain_config, utils, context],
  "."/utils/tx_pool

from web3/ethtypes as web3types import nil
from web3/engine_api_types import ExecutionPayload, PayloadAttributes

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

template asEthHash*(hash: Web3BlockHash): Hash256 =
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

proc prepareHeader(engine: SealingEngineRef,
                   coinbase: EthAddress,
                   parent: BlockHeader,
                   time: Time): Result[BlockHeader, string] =
  let timestamp = if parent.timestamp >= time:
                    parent.timestamp + 1.seconds
                  else:
                    time

  var header = BlockHeader(
    parentHash : parent.blockHash,
    blockNumber: parent.blockNumber + 1.toBlockNumber,
    # TODO: gasFloor and gasCeil can be configured by user
    gasLimit   : computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = DEFAULT_GAS_LIMIT,
      gasCeil = DEFAULT_GAS_LIMIT),
    # TODO: extraData can be configured via cli
    #extraData : engine.extra,
    coinbase   : coinbase,
    timestamp  : timestamp,
    ommersHash : EMPTY_UNCLE_HASH,
    stateRoot  : parent.stateRoot,
    txRoot     : BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH
  )

  # Set baseFee and GasLimit if we are on an EIP-1559 chain
  let conf = engine.chain.db.config
  if isLondon(conf, header.blockNumber):
    header.baseFee = calcEip1599BaseFee(conf, parent)
    var parentGasLimit = parent.gasLimit
    if not isLondon(conf, parent.blockNumber):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    # TODO: desiredLimit can be configured by user, gasCeil
    header.gasLimit = calcGasLimit1559(parentGasLimit, desiredLimit = DEFAULT_GAS_LIMIT)

  # TODO Post merge, clique should not be executing
  let clique = engine.chain.clique
  let res = clique.prepare(parent, header)
  if res.isErr:
    return err($res.error)

  if engine.chain.isBlockAfterTtd(header.blockNumber):
    header.difficulty = DifficultyInt.zero

  ok(header)

proc generateBlock(engine: SealingEngineRef,
                   coinbase: EthAddress,
                   parentBlockHeader: BlockHeader,
                   outBlock: var EthBlock): Result[void, string] =
  # deviation from standard block generator
  # - no local and remote transactions inclusion(need tx pool)
  # - no receipts from tx
  # - no DAO hard fork
  # - no local and remote uncles inclusion

  let clique = engine.chain.clique
  let time = getTime()
  let res = prepareHeader(engine, coinbase, parentBlockHeader, time)
  if res.isErr:
    return err("error prepare header")

  outBlock = EthBlock(
    header: res.get()
  )

  # TODO Post merge, Clique should not be executing
  let sealRes = clique.seal(outBlock)
  if sealRes.isErr:
    return err("error sealing block header: " & $sealRes.error)

  debug "generated block",
        blockNumber = outBlock.header.blockNumber,
        blockHash = blockHash(outBlock.header)

  ok()

proc generateBlock(engine: SealingEngineRef,
                   coinbase: EthAddress,
                   parentHash: Hash256,
                   outBlock: var EthBlock): Result[void, string] =
  var parentBlockHeader: BlockHeader
  if engine.chain.db.getBlockHeader(parentHash, parentBlockHeader):
    generateBlock(engine, coinbase, parentBlockHeader, outBlock)
  else:
    # TODO:
    # This hack shouldn't be necessary if the database can find
    # the genesis block hash in `getBlockHeader`.
    let maybeGenesisBlock = engine.chain.currentBlock()
    if parentHash == maybeGenesisBlock.blockHash:
      generateBlock(engine, coinbase, maybeGenesisBlock, outBlock)
    else:
      return err "parent block not found"

proc generateBlock(engine: SealingEngineRef,
                   coinbase: EthAddress,
                   outBlock: var EthBlock): Result[void, string] =
  generateBlock(engine, coinbase, engine.chain.currentBlock(), outBlock)

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

  # TODO: This should be configurable
  var coinbase: EthAddress

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
    let blkRes = engine.generateBlock(coinbase, blk)
    if blkRes.isErr:
      error "sealing engine generateBlock error", msg=blkRes.error
      break

    let res = engine.chain.persistBlocks([blk.header], [
      BlockBody(transactions: blk.txs, uncles: blk.uncles)
    ])

    if res == ValidationResult.Error:
      error "sealing engine: persistBlocks error"
      break

    info "block generated", number=blk.header.blockNumber

proc generateExecutionPayload*(engine: SealingEngineRef,
                               payloadAttrs: PayloadAttributes,
                               payloadRes: var ExecutionPayload): Result[void, string] =
  var blk: EthBlock
  let blkRes = engine.generateBlock(EthAddress payloadAttrs.feeRecipient,
                                    payloadAttrs.parentHash.asEthHash,
                                    blk)
  if blkRes.isErr:
    error "sealing engine generateBlock error", msg = blkRes.error
    return blkRes

  let res = engine.chain.persistBlocks([blk.header], [
    BlockBody(transactions: blk.txs, uncles: blk.uncles)
  ])

  payloadRes.parentHash = Web3BlockHash blk.header.parentHash.data
  payloadRes.coinbase = Web3Address blk.header.coinbase
  payloadRes.stateRoot = Web3BlockHash blk.header.stateRoot.data
  payloadRes.receiptRoot = Web3BlockHash blk.header.receiptRoot.data
  payloadRes.logsBloom = Web3Bloom blk.header.bloom
  payloadRes.random = web3types.FixedBytes[32](payloadAttrs.random)
  payloadRes.blockNumber = Web3Quantity blk.header.blockNumber.truncate(uint64)
  payloadRes.gasLimit = Web3Quantity blk.header.gasLimit
  payloadRes.gasUsed = Web3Quantity blk.header.gasUsed
  payloadRes.timestamp = payloadAttrs.timestamp
  # TODO
  # res.extraData
  payloadRes.baseFeePerGas = blk.header.fee.get(UInt256.zero)
  payloadRes.blockHash = Web3BlockHash rlpHash(blk.header).data
  # TODO
  # res.transactions*: seq[TypedTransaction]

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
