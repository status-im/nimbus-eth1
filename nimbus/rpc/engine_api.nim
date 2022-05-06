# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, times, strutils],
  stew/[objects, results, byteutils],
  json_rpc/[rpcserver, errors],
  web3/[conversions, engine_api_types], chronicles,
  eth/[rlp, common],
  ".."/db/db_chain,
  ".."/p2p/chain/[chain_desc, persist_blocks],
  ".."/[sealer, constants],
  ".."/merge/[mergetypes, mergeutils]

import eth/common/eth_types except BlockHeader

proc setupEngineAPI*(
    sealingEngine: SealingEngineRef,
    server: RpcServer) =

  # TODO: put it somewhere else singleton
  let api = EngineAPI.new(sealingEngine.chain.db)

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.7/src/engine/specification.md#engine_newpayloadv1
  # cannot use `params` as param name. see https:#github.com/status-im/nim-json-rpc/issues/128
  server.rpc("engine_newPayloadV1") do(payload: ExecutionPayloadV1) -> PayloadStatusV1:
    trace "Engine API request received",
      meth = "newPayloadV1", number = $(distinctBase payload.blockNumber), hash = payload.blockHash.toHex

    var header = toBlockHeader(payload)
    let blockHash = payload.blockHash.asEthHash
    var res = header.validate(blockHash)
    if res.isErr:
      return PayloadStatusV1(status: PayloadExecutionStatus.invalid_block_hash, validationError: some(res.error))

    let db = sealingEngine.chain.db

    # If we already have the block locally, ignore the entire execution and just
    # return a fake success.
    if db.getBlockHeader(blockHash, header):
      warn "Ignoring already known beacon payload",
        number = header.blockNumber, hash = blockHash.data.toHex
      return PayloadStatusV1(status: PayloadExecutionStatus.valid, latestValidHash: validHash(blockHash))

    # If the parent is missing, we - in theory - could trigger a sync, but that
    # would also entail a reorg. That is problematic if multiple sibling blocks
    # are being fed to us, and even moreso, if some semi-distant uncle shortens
    # our live chain. As such, payload execution will not permit reorgs and thus
    # will not trigger a sync cycle. That is fine though, if we get a fork choice
    # update after legit payload executions.
    var parent: eth_types.BlockHeader
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
        number = header.blockNumber, hash = blockHash.data.toHex, parent = header.parentHash.data.toHex
      return PayloadStatusV1(status: PayloadExecutionStatus.accepted)

    # We have an existing parent, do some sanity checks to avoid the beacon client
    # triggering too early
    let
      td  = db.getScore(header.parentHash)
      ttd = db.ttd()

    if td < ttd:
      warn "Ignoring pre-merge payload",
        number = header.blockNumber, hash = blockHash.data.toHex, td, ttd
      return PayloadStatusV1(status: PayloadExecutionStatus.invalid_terminal_block)

    if header.timestamp <= parent.timestamp:
      warn "Invalid timestamp",
        parent = header.timestamp, header = header.timestamp
      return invalidStatus(db.getCurrentBlockHash(), "Invalid timestamp")

    trace "Inserting block without sethead",
      hash = blockHash.data.toHex, number = header.blockNumber
    let body = toBlockBody(payload)
    let vres = sealingEngine.chain.insertBlockWithoutSetHead(header, body)
    if vres != ValidationResult.OK:
      return invalidStatus(db.getCurrentBlockHash(), "Failed to insert block")

    # We've accepted a valid payload from the beacon client. Mark the local
    # chain transitions to notify other subsystems (e.g. downloader) of the
    # behavioral change.
    if not api.merger.ttdReached():
      api.merger.reachTTD()
      # TODO: cancel downloader

    return PayloadStatusV1(status: PayloadExecutionStatus.valid, latestValidHash: validHash(blockHash))

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.7/src/engine/specification.md#engine_getpayloadv1
  server.rpc("engine_getPayloadV1") do(payloadId: PayloadID) -> ExecutionPayloadV1:
    trace "Engine API request received",
      meth = "GetPayload", id = payloadId.toHex

    var payload: ExecutionPayloadV1
    if not api.get(payloadId, payload):
      raise (ref InvalidRequest)(code: engineApiUnknownPayload, msg: "Unknown payload")
    return payload

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.7/src/engine/specification.md#engine_exchangeTransitionConfigurationV1
  server.rpc("engine_exchangeTransitionConfigurationV1") do(conf: TransitionConfigurationV1) -> TransitionConfigurationV1:
    trace "Engine API request received",
      meth = "exchangeTransitionConfigurationV1",
      ttd = conf.terminalTotalDifficulty,
      number = uint64(conf.terminalBlockNumber),
      blockHash = conf.terminalBlockHash.toHex

    let db = sealingEngine.chain.db
    let ttd = db.ttd()

    if conf.terminalTotalDifficulty != ttd:
      raise newException(ValueError, "invalid ttd: EL $1 CL $2" % [$ttd, $conf.terminalTotalDifficulty])

    var header: EthBlockHeader
    let terminalBlockNumber = uint64(conf.terminalBlockNumber)
    let terminalBlockHash = conf.terminalBlockHash.asEthHash
    if db.currentTerminalHeader(header):
      let headerHash = header.blockHash

      if terminalBlockNumber != 0'u64 and terminalBlockNumber != header.blockNumber.truncate(uint64):
        raise newException(ValueError, "invalid terminal block number, got $1 want $2" % [$terminalBlockNumber, $header.blockNumber])

      if terminalBlockHash != Hash256() and terminalBlockHash != headerHash:
        raise newException(ValueError, "invalid terminal block hash, got $1 want $2" % [terminalBlockHash.toHex, headerHash.data.toHex])

      return TransitionConfigurationV1(
        terminalTotalDifficulty: ttd,
        terminalBlockHash      : BlockHash headerHash.data,
        terminalBlockNumber    : Quantity header.blockNumber.truncate(uint64)
      )

    if terminalBlockNumber != 0:
      raise newException(ValueError, "invalid terminal block number: $1" % [$terminalBlockNumber])

    if terminalBlockHash != Hash256():
      raise newException(ValueError, "invalid terminal block hash, no terminal header set")

    return TransitionConfigurationV1(terminalTotalDifficulty: ttd)

  # ForkchoiceUpdatedV1 has several responsibilities:
  # If the method is called with an empty head block:
  #     we return success, which can be used to check if the catalyst mode is enabled
  # If the total difficulty was not reached:
  #     we return INVALID
  # If the finalizedBlockHash is set:
  #     we check if we have the finalizedBlockHash in our db, if not we start a sync
  # We try to set our blockchain to the headBlock
  # If there are payloadAttributes:
  #     we try to assemble a block with the payloadAttributes and return its payloadID
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-alpha.7/src/engine/specification.md#engine_forkchoiceupdatedv1
  server.rpc("engine_forkchoiceUpdatedV1") do(
      update: ForkchoiceStateV1,
      payloadAttributes: Option[PayloadAttributesV1]) -> ForkchoiceUpdatedResponse:
    let
      db = sealingEngine.chain.db
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
          hash = blockHash.data.toHex
        return simpleFCU(PayloadExecutionStatus.syncing)

      # Header advertised via a past newPayload request. Start syncing to it.
      # Before we do however, make sure any legacy sync in switched off so we
      # don't accidentally have 2 cycles running.
      if not api.merger.ttdReached():
        api.merger.reachTTD()
        # TODO: cancel downloader

      info "Forkchoice requested sync to new head",
        number = header.blockNumber,
        hash = blockHash.data.toHex

      return simpleFCU(PayloadExecutionStatus.syncing)

    # Block is known locally, just sanity check that the beacon client does not
    # attempt to push us back to before the merge.
    let blockNumber = header.blockNumber.truncate(uint64)
    if header.difficulty > 0.u256 or blockNumber ==  0'u64:
      var
        td, ptd: DifficultyInt
        ttd = db.ttd()

      if not db.getTd(blockHash, td) or (blockNumber > 0'u64 and not db.getTd(header.parentHash, ptd)):
        error "TDs unavailable for TTD check",
          number = blockNumber,
          hash = blockHash.data.toHex,
          td = td,
          parent = header.parentHash.data.toHex,
          ptd = ptd
        return simpleFCU(PayloadExecutionStatus.invalid, "TDs unavailable for TDD check")

      if td < ttd or (blockNumber > 0'u64 and ptd > ttd):
        error "Refusing beacon update to pre-merge",
          number = blockNumber,
          hash = blockHash.data.toHex,
          diff = header.difficulty,
          ptd = ptd,
          ttd = ttd

        return simpleFCU(PayloadExecutionStatus.invalid_terminal_block)

    # If the head block is already in our canonical chain, the beacon client is
    # probably resyncing. Ignore the update.
    var canonHash: Hash256
    if db.getBlockHash(header.blockNumber, canonHash) and canonHash == blockHash:
      # TODO should this be possible?
      # If we allow these types of reorgs, we will do lots and lots of reorgs during sync
      warn "Reorg to previous block"
      if not db.setHead(blockHash):
        return simpleFCU(PayloadExecutionStatus.invalid)
    elif not db.setHead(blockHash):
      return simpleFCU(PayloadExecutionStatus.invalid)

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
          hash=finalizedBlockHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "finalized block header not available")
      var finalHash: Hash256
      if not db.getBlockHash(finalBlock.blockNumber, finalHash):
        warn "Final block not in canonical chain",
          number=finalBlock.blockNumber,
          hash=finalizedBlockHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "finalized block hash not available")
      if finalHash != finalizedBlockHash:
        warn "Final block not in canonical chain",
          number=finalBlock.blockNumber,
          finalHash=finalHash.data.toHex,
          finalizedBlockHash=finalizedBlockHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "finalilized block not canonical")

    let safeBlockHash = update.safeBlockHash.asEthHash
    if safeBlockHash != Hash256():
      var safeBlock: EthBlockHeader
      if not db.getBlockHeader(safeBlockHash, safeBlock):
        warn "Safe block not available in database",
          hash = safeBlockHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "safe head not available")
      var safeHash: Hash256
      if not db.getBlockHash(safeBlock.blockNumber, safeHash):
        warn "Safe block hash not available in database",
          hash = safeHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "safe block hash not available")
      if safeHash != safeBlockHash:
        warn "Safe block not in canonical chain",
          safeHash=safeHash.data.toHex,
          safeBlockHash=safeBlockHash.data.toHex
        raise (ref InvalidRequest)(code: engineApiInvalidParams, msg: "safe head not canonical")

    # If payload generation was requested, create a new block to be potentially
    # sealed by the beacon client. The payload will be requested later, and we
    # might replace it arbitrarilly many times in between.
    if payloadAttributes.isSome:
      info "Creating new payload for sealing"
      let payloadAttrs = payloadAttributes.get()
      var payload: ExecutionPayloadV1
      let res = sealingEngine.generateExecutionPayload(payloadAttrs, payload)

      if res.isErr:
        error "Failed to create sealing payload", err = res.error
        return simpleFCU(PayloadExecutionStatus.invalid, res.error)

      let id = computePayloadId(blockHash, payloadAttrs)
      api.put(id, payload)

      info "Created payload for sealing",
        id = id.toHex

      return validFCU(some(id), blockHash)

    return validFCU(none(PayloadID), blockHash)
