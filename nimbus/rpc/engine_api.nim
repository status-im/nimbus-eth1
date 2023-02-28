# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, times, strutils, sequtils, sets],
  stew/[results, byteutils],
  json_rpc/rpcserver,
  web3/[conversions, engine_api_types],
  eth/rlp,
  eth/common/eth_types_rlp,
  ../common/common,
  ".."/core/chain/[chain_desc, persist_blocks],
  ../constants,
  ../core/[tx_pool, sealer],
  ./merge/[mergetypes, mergeutils],
  # put chronicles import last because Nim
  # compiler resolve `$` for logging
  # arguments differently on Windows vs posix
  # if chronicles import is in the middle
  chronicles

{.push raises: [].}


func toPayloadAttributesV1OrPayloadAttributesV2*(a: PayloadAttributesV1OrV2): Result[PayloadAttributesV1, PayloadAttributesV2] =
  if a.withdrawals.isNone:
    ok(
      PayloadAttributesV1(
        timestamp: a.timestamp,
        prevRandao: a.prevRandao,
        suggestedFeeRecipient: a.suggestedFeeRecipient
      )
    )
  else:
    err(
      PayloadAttributesV2(
        timestamp: a.timestamp,
        prevRandao: a.prevRandao,
        suggestedFeeRecipient: a.suggestedFeeRecipient,
        withdrawals: a.withdrawals.get
      )
    )

proc latestValidHash(db: ChainDBRef, parent: EthBlockHeader, ttd: DifficultyInt): Hash256
    {.gcsafe, raises: [RlpError].} =
  let ptd = db.getScore(parent.parentHash)
  if ptd >= ttd:
    parent.blockHash
  else:
    # If the most recent valid ancestor is a PoW block,
    # latestValidHash MUST be set to ZERO
    Hash256()

proc invalidFCU(com: CommonRef, header: EthBlockHeader): ForkchoiceUpdatedResponse
    {.gcsafe, raises: [RlpError].} =
  var parent: EthBlockHeader
  if not com.db.getBlockHeader(header.parentHash, parent):
    return invalidFCU(Hash256())

  let blockHash = latestValidHash(com.db, parent, com.ttd.get(high(common.BlockNumber)))
  invalidFCU(blockHash)

proc txPriorityFee(ttx: TypedTransaction): UInt256 =
  try:
    let tx = rlp.decode(distinctBase(ttx), Transaction)
    return u256(tx.gasPrice * tx.maxPriorityFee)
  except RlpError:
    doAssert(false, "found TypedTransaction that RLP failed to decode")

# AARDVARK: make sure I have the right units (wei/gwei)
proc sumOfBlockPriorityFees(payload: ExecutionPayloadV1OrV2): UInt256 =
  payload.transactions.foldl(a + txPriorityFee(b), UInt256.zero)

template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

# I created these handle_whatever procs to eliminate duplicated code
# between the V1 and V2 RPC endpoint implementations. (I believe
# they're meant to be implementable in that way. e.g. The V2 specs
# explicitly say "here's what to do if the `withdrawals` field is
# null.) --Adam

# https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md#engine_newpayloadv1
proc handle_newPayload(sealingEngine: SealingEngineRef, api: EngineApiRef, com: CommonRef, payload: ExecutionPayloadV1 | ExecutionPayloadV2): PayloadStatusV1 {.raises: [CatchableError].} =
  trace "Engine API request received",
    meth = "newPayload", number = $(distinctBase payload.blockNumber), hash = payload.blockHash

  if com.isShanghaiOrLater(fromUnix(payload.timestamp.unsafeQuantityToInt64)):
    when not(payload is ExecutionPayloadV2):
      raise invalidParams("if timestamp is Shanghai or later, payload must be ExecutionPayloadV2")
  else:
    when not(payload is ExecutionPayloadV1):
      raise invalidParams("if timestamp is earlier than Shanghai, payload must be ExecutionPayloadV1")
  
  var header = toBlockHeader(payload)
  let blockHash = payload.blockHash.asEthHash
  var res = header.validateBlockHash(blockHash)
  if res.isErr:
    return res.error

  let db = sealingEngine.chain.db

  # If we already have the block locally, ignore the entire execution and just
  # return a fake success.
  if db.getBlockHeader(blockHash, header):
    warn "Ignoring already known beacon payload",
      number = header.blockNumber, hash = blockHash
    return validStatus(blockHash)

  # If the parent is missing, we - in theory - could trigger a sync, but that
  # would also entail a reorg. That is problematic if multiple sibling blocks
  # are being fed to us, and even moreso, if some semi-distant uncle shortens
  # our live chain. As such, payload execution will not permit reorgs and thus
  # will not trigger a sync cycle. That is fine though, if we get a fork choice
  # update after legit payload executions.
  var parent: EthBlockHeader
  if not db.getBlockHeader(header.parentHash, parent):
    # Stash the block away for a potential forced forckchoice update to it
    # at a later time.
    api.put(blockHash, header)

    # Although we don't want to trigger a sync, if there is one already in
    # progress, try to extend if with the current payload request to relieve
    # some strain from the forkchoice update.
    #if err := api.eth.Downloader().BeaconExtend(api.eth.SyncMode(), block.Header()); err == nil {
    #  log.Debug("Payload accepted for sync extension", "number", params.Number, "hash", params.BlockHash)
    #  return beacon.PayloadStatusV1{Status: beacon.SYNCING}, nil

    # Either no beacon sync was started yet, or it rejected the delivered
    # payload as non-integratable on top of the existing sync. We'll just
    # have to rely on the beacon client to forcefully update the head with
    # a forkchoice update request.
    warn "Ignoring payload with missing parent",
      number = header.blockNumber,
      hash = blockHash,
      parent = header.parentHash
    return acceptedStatus()

  # We have an existing parent, do some sanity checks to avoid the beacon client
  # triggering too early
  let
    td  = db.getScore(header.parentHash)
    ttd = com.ttd.get(high(common.BlockNumber))

  if td < ttd:
    warn "Ignoring pre-merge payload",
      number = header.blockNumber, hash = blockHash, td, ttd
    return invalidStatus()

  if header.timestamp <= parent.timestamp:
    warn "Invalid timestamp",
      parent = header.timestamp, header = header.timestamp
    return invalidStatus(db.getHeadBlockHash(), "Invalid timestamp")

  if not db.haveBlockAndState(header.parentHash):
    api.put(blockHash, header)
    warn "State not available, ignoring new payload",
      hash = blockHash,
      number = header.blockNumber
    let blockHash = latestValidHash(db, parent, ttd)
    return acceptedStatus(blockHash)

  trace "Inserting block without sethead",
    hash = blockHash, number = header.blockNumber
  let body = toBlockBody(payload)
  let vres = sealingEngine.chain.insertBlockWithoutSetHead(header, body)
  if vres != ValidationResult.OK:
    let blockHash = latestValidHash(db, parent, ttd)
    return invalidStatus(blockHash, "Failed to insert block")

  # We've accepted a valid payload from the beacon client. Mark the local
  # chain transitions to notify other subsystems (e.g. downloader) of the
  # behavioral change.
  if not api.merger.ttdReached():
    api.merger.reachTTD()
    # TODO: cancel downloader

  return validStatus(blockHash)
    
# https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md#engine_getpayloadv1
proc handle_getPayload(api: EngineApiRef, payloadId: PayloadID): GetPayloadV2Response {.raises: [CatchableError].} =
  trace "Engine API request received",
    meth = "GetPayload", id = payloadId.toHex

  var payload: ExecutionPayloadV1OrV2
  if not api.get(payloadId, payload):
    raise unknownPayload("Unknown payload")

  let blockValue = Quantity(sumOfBlockPriorityFees(payload).truncate(uint64))
  
  return GetPayloadV2Response(
    executionPayload: payload,
    blockValue: blockValue
  )

# https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md#engine_exchangetransitionconfigurationv1
proc handle_exchangeTransitionConfiguration(sealingEngine: SealingEngineRef, com: CommonRef, conf: TransitionConfigurationV1): TransitionConfigurationV1 {.raises: [CatchableError].} =
  trace "Engine API request received",
    meth = "exchangeTransitionConfigurationV1",
    ttd = conf.terminalTotalDifficulty,
    number = uint64(conf.terminalBlockNumber),
    blockHash = conf.terminalBlockHash
  let db = sealingEngine.chain.db
  let ttd = com.ttd

  if ttd.isNone:
    raise newException(ValueError, "invalid ttd: EL (none) CL ($2)" % [$conf.terminalTotalDifficulty])

  if conf.terminalTotalDifficulty != ttd.get:
    raise newException(ValueError, "invalid ttd: EL ($1) CL ($2)" % [$ttd.get, $conf.terminalTotalDifficulty])

  let terminalBlockNumber = uint64(conf.terminalBlockNumber).toBlockNumber
  let terminalBlockHash = conf.terminalBlockHash.asEthHash

  if terminalBlockHash != Hash256():
    var headerHash: Hash256

    if not db.getBlockHash(terminalBlockNumber, headerHash):
      raise newException(ValueError, "cannot get terminal block hash, number $1" %
        [$terminalBlockNumber])

    if terminalBlockHash != headerHash:
      raise newException(ValueError, "invalid terminal block hash, got $1 want $2" %
        [$terminalBlockHash, $headerHash])

    var header: EthBlockHeader
    if not db.getBlockHeader(headerHash, header):
      raise newException(ValueError, "cannot get terminal block header, hash $1" %
        [$terminalBlockHash])

    return TransitionConfigurationV1(
      terminalTotalDifficulty: ttd.get,
      terminalBlockHash      : BlockHash headerHash.data,
      terminalBlockNumber    : Quantity header.blockNumber.truncate(uint64)
    )

  if terminalBlockNumber != 0:
    raise newException(ValueError, "invalid terminal block number: $1" % [$terminalBlockNumber])

  if terminalBlockHash != Hash256():
    raise newException(ValueError, "invalid terminal block hash, no terminal header set")

  return TransitionConfigurationV1(terminalTotalDifficulty: ttd.get)

# ForkchoiceUpdated has several responsibilities:
# If the method is called with an empty head block:
#     we return success, which can be used to check if the catalyst mode is enabled
# If the total difficulty was not reached:
#     we return INVALID
# If the finalizedBlockHash is set:
#     we check if we have the finalizedBlockHash in our db, if not we start a sync
# We try to set our blockchain to the headBlock
# If there are payloadAttributes:
#     we try to assemble a block with the payloadAttributes and return its payloadID
# https://github.com/ethereum/execution-apis/blob/main/src/engine/shanghai.md#engine_forkchoiceupdatedv2
proc handle_forkchoiceUpdated(sealingEngine: SealingEngineRef, com: CommonRef, api: EngineApiRef, update: ForkchoiceStateV1, payloadAttributes: Option[PayloadAttributesV1] | Option[PayloadAttributesV2]): ForkchoiceUpdatedResponse {.raises: [CatchableError].} =

  if payloadAttributes.isSome:
    if com.isShanghaiOrLater(fromUnix(payloadAttributes.get.timestamp.unsafeQuantityToInt64)):
      when not(payloadAttributes is Option[PayloadAttributesV2]):
        raise invalidParams("if timestamp is Shanghai or later, payloadAttributes must be PayloadAttributesV2")
    else:
      when not(payloadAttributes is Option[PayloadAttributesV1]):
        raise invalidParams("if timestamp is earlier than Shanghai, payloadAttributes must be PayloadAttributesV1")

  let
    chain = sealingEngine.chain
    db = chain.db
    blockHash = update.headBlockHash.asEthHash

  if blockHash == Hash256():
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadExecutionStatus.invalid)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  var header: EthBlockHeader
  if not db.getBlockHeader(blockHash, header):
    # If the head hash is unknown (was not given to us in a newPayload request),
    # we cannot resolve the header, so not much to do. This could be extended in
    # the future to resolve from the `eth` network, but it's an unexpected case
    # that should be fixed, not papered over.
    if not api.get(blockHash, header):
      warn "Forkchoice requested unknown head",
        hash = blockHash
      return simpleFCU(PayloadExecutionStatus.syncing)

    # Header advertised via a past newPayload request. Start syncing to it.
    # Before we do however, make sure any legacy sync in switched off so we
    # don't accidentally have 2 cycles running.
    if not api.merger.ttdReached():
      api.merger.reachTTD()
      # TODO: cancel downloader

    info "Forkchoice requested sync to new head",
      number = header.blockNumber,
      hash = blockHash

    # Update sync header (if any)
    com.syncReqNewHead(header)

    return simpleFCU(PayloadExecutionStatus.syncing)

  # Block is known locally, just sanity check that the beacon client does not
  # attempt to push us back to before the merge.
  let blockNumber = header.blockNumber.truncate(uint64)
  if header.difficulty > 0.u256 or blockNumber ==  0'u64:
    var
      td, ptd: DifficultyInt
      ttd = com.ttd.get(high(common.BlockNumber))

    if not db.getTd(blockHash, td) or (blockNumber > 0'u64 and not db.getTd(header.parentHash, ptd)):
      error "TDs unavailable for TTD check",
        number = blockNumber,
        hash = blockHash,
        td = td,
        parent = header.parentHash,
        ptd = ptd
      return simpleFCU(PayloadExecutionStatus.invalid, "TDs unavailable for TDD check")

    if td < ttd or (blockNumber > 0'u64 and ptd > ttd):
      error "Refusing beacon update to pre-merge",
        number = blockNumber,
        hash = blockHash,
        diff = header.difficulty,
        ptd = ptd,
        ttd = ttd

      return invalidFCU()

  # If the head block is already in our canonical chain, the beacon client is
  # probably resyncing. Ignore the update.
  var canonHash: Hash256
  if db.getBlockHash(header.blockNumber, canonHash) and canonHash == blockHash:
    # TODO should this be possible?
    # If we allow these types of reorgs, we will do lots and lots of reorgs during sync
    warn "Reorg to previous block"
    if chain.setCanonical(header) != ValidationResult.OK:
      return invalidFCU(com, header)
  elif chain.setCanonical(header) != ValidationResult.OK:
    return invalidFCU(com, header)

  # If the beacon client also advertised a finalized block, mark the local
  # chain final and completely in PoS mode.
  let finalizedBlockHash = update.finalizedBlockHash.asEthHash
  if finalizedBlockHash != Hash256():
    if not api.merger.posFinalized:
      api.merger.finalizePoS()

    # TODO: If the finalized block is not in our canonical tree, somethings wrong
    var finalBlock: EthBlockHeader
    if not db.getBlockHeader(finalizedBlockHash, finalBlock):
      warn "Final block not available in database",
        hash=finalizedBlockHash
      raise invalidParams("finalized block header not available")
    var finalHash: Hash256
    if not db.getBlockHash(finalBlock.blockNumber, finalHash):
      warn "Final block not in canonical chain",
        number=finalBlock.blockNumber,
        hash=finalizedBlockHash
      raise invalidParams("finalized block hash not available")
    if finalHash != finalizedBlockHash:
      warn "Final block not in canonical chain",
        number=finalBlock.blockNumber,
        expect=finalizedBlockHash,
        get=finalHash
      raise invalidParams("finalilized block not canonical")
    db.finalizedHeaderHash(finalizedBlockHash)

  let safeBlockHash = update.safeBlockHash.asEthHash
  if safeBlockHash != Hash256():
    var safeBlock: EthBlockHeader
    if not db.getBlockHeader(safeBlockHash, safeBlock):
      warn "Safe block not available in database",
        hash = safeBlockHash
      raise invalidParams("safe head not available")
    var safeHash: Hash256
    if not db.getBlockHash(safeBlock.blockNumber, safeHash):
      warn "Safe block hash not available in database",
        hash = safeHash
      raise invalidParams("safe block hash not available")
    if safeHash != safeBlockHash:
      warn "Safe block not in canonical chain",
        blockNumber=safeBlock.blockNumber,
        expect=safeBlockHash,
        get=safeHash
      raise invalidParams("safe head not canonical")
    db.safeHeaderHash(safeBlockHash)

  # If payload generation was requested, create a new block to be potentially
  # sealed by the beacon client. The payload will be requested later, and we
  # might replace it arbitrarilly many times in between.
  if payloadAttributes.isSome:
    let payloadAttrs = payloadAttributes.get()
    let res = sealingEngine.generateExecutionPayload(payloadAttrs)

    if res.isErr:
      error "Failed to create sealing payload", err = res.error
      raise invalidAttr(res.error)
    
    let payload = res.get

    let id = computePayloadId(blockHash, payloadAttrs)
    api.put(id, payload)

    info "Created payload for sealing",
      id = id.toHex,
      hash = payload.blockHash,
      number = payload.blockNumber.uint64

    return validFCU(some(id), blockHash)

  return validFCU(none(PayloadID), blockHash)

func toHash(value: array[32, byte]): Hash256 =
  result.data = value

proc handle_getPayloadBodiesByHash(sealingEngine: SealingEngineRef, hashes: seq[BlockHash]): seq[Option[ExecutionPayloadBodyV1]] {.raises: [CatchableError].} =
  let db = sealingEngine.chain.db
  var body: BlockBody
  for h in hashes:
    if db.getBlockBody(toHash(distinctBase(h)), body):
      var typedTransactions: seq[TypedTransaction]
      for tx in body.transactions:
        typedTransactions.add(tx.toTypedTransaction)
      var withdrawals: seq[WithdrawalV1]
      for w in body.withdrawals.get:
        withdrawals.add(w.toWithdrawalV1)
      result.add(
        some(ExecutionPayloadBodyV1(
          transactions: typedTransactions,
          withdrawals: withdrawals
        ))
      )
    else:
      result.add(none[ExecutionPayloadBodyV1]())

const supportedMethods: HashSet[string] =
  toHashSet([
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_exchangeTransitionConfigurationV1",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_getPayloadBodiesByHashV1"
  ])

# I'm trying to keep the handlers below very thin, and move the
# bodies up to the various procs above. Once we have multiple
# versions, they'll need to be able to share code.
proc setupEngineApi*(
    sealingEngine: SealingEngineRef,
    server: RpcServer,
    merger: MergerRef) =

  let
    api = EngineApiRef.new(merger)
    com = sealingEngine.chain.com

  server.rpc("engine_exchangeCapabilities") do(methods: seq[string]) -> seq[string]:
    return methods.filterIt(supportedMethods.contains(it))

  # cannot use `params` as param name. see https:#github.com/status-im/nim-json-rpc/issues/128
  server.rpc("engine_newPayloadV1") do(payload: ExecutionPayloadV1) -> PayloadStatusV1:
    return handle_newPayload(sealingEngine, api, com, payload)
  
  server.rpc("engine_newPayloadV2") do(payload: ExecutionPayloadV1OrV2) -> PayloadStatusV1:
    let p = payload.toExecutionPayloadV1OrExecutionPayloadV2
    if p.isOk:
      return handle_newPayload(sealingEngine, api, com, p.get)
    else:
      return handle_newPayload(sealingEngine, api, com, p.error)

  server.rpc("engine_getPayloadV1") do(payloadId: PayloadID) -> ExecutionPayloadV1:
    let r = handle_getPayload(api, payloadId)
    return r.executionPayload.toExecutionPayloadV1

  server.rpc("engine_getPayloadV2") do(payloadId: PayloadID) -> GetPayloadV2Response:
    return handle_getPayload(api, payloadId)

  server.rpc("engine_exchangeTransitionConfigurationV1") do(conf: TransitionConfigurationV1) -> TransitionConfigurationV1:
    return handle_exchangeTransitionConfiguration(sealingEngine, com, conf)

  server.rpc("engine_forkchoiceUpdatedV1") do(
      update: ForkchoiceStateV1,
      payloadAttributes: Option[PayloadAttributesV1]) -> ForkchoiceUpdatedResponse:
    return handle_forkchoiceUpdated(sealingEngine, com, api, update, payloadAttributes)

  server.rpc("engine_forkchoiceUpdatedV2") do(
      update: ForkchoiceStateV1,
      payloadAttributes: Option[PayloadAttributesV1OrV2]) -> ForkchoiceUpdatedResponse:
    if payloadAttributes.isNone:
      return handle_forkchoiceUpdated(sealingEngine, com, api, update, none[PayloadAttributesV2]())
    else:
      let a = payloadAttributes.get.toPayloadAttributesV1OrPayloadAttributesV2
      if a.isOk:
        return handle_forkchoiceUpdated(sealingEngine, com, api, update, some(a.get))
      else:
        return handle_forkchoiceUpdated(sealingEngine, com, api, update, some(a.error))

  server.rpc("engine_getPayloadBodiesByHashV1") do(
      hashes: seq[BlockHash]) -> seq[Option[ExecutionPayloadBodyV1]]:
    return handle_getPayloadBodiesByHash(sealingEngine, hashes)

