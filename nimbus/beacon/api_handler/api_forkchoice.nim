# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  eth/common,
  stew/results,
  ../web3_eth_conv,
  ../beacon_engine,
  ../execution_types,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

template validateVersion(attrsOpt, com) =
  if attrsOpt.isSome:
    let
      attr      = attrsOpt.get
      version   = attr.version
      timestamp = ethTime attr.timestamp

    if com.isCancunOrLater(timestamp):
      if version != Version.V3:
        raise invalidParams("if timestamp is Cancun or later," &
          " payloadAttributes must be PayloadAttributesV3")
    elif com.isShanghaiOrLater(timestamp):
      if version != Version.V2:
        raise invalidParams("if timestamp is Shanghai or later," &
          " payloadAttributes must be PayloadAttributesV2")
    else:
      if version != Version.V1:
        raise invalidParams("if timestamp is earlier than Shanghai," &
          " payloadAttributes must be PayloadAttributesV1")

proc forkchoiceUpdated*(ben: BeaconEngineRef,
                        update: ForkchoiceStateV1,
                        attrsOpt: Option[PayloadAttributes]):
                             ForkchoiceUpdatedResponse =
  let
    com   = ben.com
    db    = com.db
    chain = ben.chain
    blockHash = ethHash update.headBlockHash

  validateVersion(attrsOpt, com)

  if blockHash == common.Hash256():
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadExecutionStatus.invalid)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  var header: common.BlockHeader
  if not db.getBlockHeader(blockHash, header):
    # If the head hash is unknown (was not given to us in a newPayload request),
    # we cannot resolve the header, so not much to do. This could be extended in
    # the future to resolve from the `eth` network, but it's an unexpected case
    # that should be fixed, not papered over.
    if not ben.get(blockHash, header):
      warn "Forkchoice requested unknown head",
        hash = blockHash
      return simpleFCU(PayloadExecutionStatus.syncing)

    # Header advertised via a past newPayload request. Start syncing to it.
    # Before we do however, make sure any legacy sync in switched off so we
    # don't accidentally have 2 cycles running.
    if not ben.ttdReached():
      ben.reachTTD()
      # TODO: cancel downloader

    info "Forkchoice requested sync to new head",
      number = header.blockNumber,
      hash   = blockHash

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
  var canonHash: common.Hash256
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
  let finalizedBlockHash = ethHash update.finalizedBlockHash
  if finalizedBlockHash != common.Hash256():
    if not ben.posFinalized:
      ben.finalizePoS()

    # TODO: If the finalized block is not in our canonical tree, somethings wrong
    var finalBlock: common.BlockHeader
    if not db.getBlockHeader(finalizedBlockHash, finalBlock):
      warn "Final block not available in database",
        hash=finalizedBlockHash
      raise invalidParams("finalized block header not available")
    var finalHash: common.Hash256
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

  let safeBlockHash = ethHash update.safeBlockHash
  if safeBlockHash != common.Hash256():
    var safeBlock: common.BlockHeader
    if not db.getBlockHeader(safeBlockHash, safeBlock):
      warn "Safe block not available in database",
        hash = safeBlockHash
      raise invalidParams("safe head not available")
    var safeHash: common.Hash256
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
  if attrsOpt.isSome:
    let attrs = attrsOpt.get()
    let payload = ben.generatePayload(attrs).valueOr:
      error "Failed to create sealing payload", err = error
      raise invalidAttr(error)

    let id = computePayloadId(blockHash, attrs)
    ben.put(id, ben.blockValue, payload)

    info "Created payload for sealing",
      id = id.toHex,
      hash = payload.blockHash,
      number = payload.blockNumber

    return validFCU(some(id), blockHash)

  return validFCU(none(PayloadID), blockHash)
