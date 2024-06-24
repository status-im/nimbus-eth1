# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  eth/common,
  results,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

template validateVersion(attr, com, apiVersion) =
  let
    version   = attr.version
    timestamp = ethTime attr.timestamp

  if apiVersion == Version.V3:
    if version != apiVersion:
      raise invalidAttr("forkChoiceUpdatedV3 expect PayloadAttributesV3" &
      " but got PayloadAttributes" & $version)
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork(
        "forkchoiceUpdatedV3 get invalid payloadAttributes timestamp")
  else:
    if com.isCancunOrLater(timestamp):
      if version < Version.V3:
        raise unsupportedFork("forkChoiceUpdated" & $apiVersion &
          " doesn't support payloadAttributes" & $version)
      if version > Version.V3:
        raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support PayloadAttributes" & $version)
    elif com.isShanghaiOrLater(timestamp):
      if version < Version.V2:
        raise invalidParams("forkChoiceUpdated" & $apiVersion &
          " doesn't support payloadAttributesV1")
      if version > Version.V2:
        raise invalidAttr("if timestamp is Shanghai or later," &
          " payloadAttributes must be PayloadAttributesV2")
    else:
      if version != Version.V1:
        raise invalidParams("if timestamp is earlier than Shanghai," &
          " payloadAttributes must be PayloadAttributesV1")

template validateHeaderTimestamp(header, com, apiVersion) =
  # See fCUV3 specification No.2 bullet iii
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/cancun.md#specification-1
  if com.isCancunOrLater(header.timestamp):
    if apiVersion != Version.V3:
      raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support head block with timestamp >= Cancun")
  # See fCUV2 specification No.2 bullet 1
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-1
  elif com.isShanghaiOrLater(header.timestamp):
    if apiVersion != Version.V2:
      raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support head block with Shanghai timestamp")
  else:
    if apiVersion != Version.V1:
      raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support head block with timestamp earlier than Shanghai")

proc forkchoiceUpdated*(ben: BeaconEngineRef,
                        apiVersion: Version,
                        update: ForkchoiceStateV1,
                        attrsOpt: Opt[PayloadAttributes]):
                             ForkchoiceUpdatedResponse =
  let
    com   = ben.com
    db    = com.db
    chain = ben.chain
    blockHash = ethHash update.headBlockHash

  if blockHash == common.Hash256():
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadExecutionStatus.invalid)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  var header: common.BlockHeader
  if not db.getBlockHeader(blockHash, header):
    # If this block was previously invalidated, keep rejecting it here too
    let res = ben.checkInvalidAncestor(blockHash, blockHash)
    if res.isSome:
      return simpleFCU(res.get)

    # If the head hash is unknown (was not given to us in a newPayload request),
    # we cannot resolve the header, so not much to do. This could be extended in
    # the future to resolve from the `eth` network, but it's an unexpected case
    # that should be fixed, not papered over.
    if not ben.get(blockHash, header):
      warn "Forkchoice requested unknown head",
        hash = blockHash.short
      return simpleFCU(PayloadExecutionStatus.syncing)

    # Header advertised via a past newPayload request. Start syncing to it.
    # Before we do however, make sure any legacy sync in switched off so we
    # don't accidentally have 2 cycles running.
    if not ben.ttdReached():
      ben.reachTTD()
      # TODO: cancel downloader

    info "Forkchoice requested sync to new head",
      number = header.number,
      hash   = blockHash.short

    # Update sync header (if any)
    com.syncReqNewHead(header)
    return simpleFCU(PayloadExecutionStatus.syncing)

  validateHeaderTimestamp(header, com, apiVersion)

  # Block is known locally, just sanity check that the beacon client does not
  # attempt to push us back to before the merge.
  #
  # Disable terminal PoW block conditions validation for fCUV2 and later.
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-1
  if apiVersion == Version.V1:
    let blockNumber = header.number
    if header.difficulty > 0.u256 or blockNumber ==  0'u64:
      var
        td, ptd: DifficultyInt
        ttd = com.ttd.get(high(UInt256))

      if not db.getTd(blockHash, td) or (blockNumber > 0'u64 and not db.getTd(header.parentHash, ptd)):
        error "TDs unavailable for TTD check",
          number = blockNumber,
          hash = blockHash.short,
          td = td,
          parent = header.parentHash.short,
          ptd = ptd
        return simpleFCU(PayloadExecutionStatus.invalid, "TDs unavailable for TTD check")

      if td < ttd or (blockNumber > 0'u64 and ptd > ttd):
        notice "Refusing beacon update to pre-merge",
          number = blockNumber,
          hash = blockHash.short,
          diff = header.difficulty,
          ptd = ptd,
          ttd = ttd

        return invalidFCU("Refusing beacon update to pre-merge")

  # If the head block is already in our canonical chain, the beacon client is
  # probably resyncing. Ignore the update.
  # See point 2 of fCUV1 specification
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/paris.md#specification-1
  var canonHash: common.Hash256
  if db.getBlockHash(header.number, canonHash) and canonHash == blockHash:
    notice "Ignoring beacon update to old head",
      blockHash=blockHash.short,
      blockNumber=header.number
    return validFCU(Opt.none(PayloadID), blockHash)

  chain.setCanonical(header).isOkOr:
    return invalidFCU(error, com, header)

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
        hash=finalizedBlockHash.short
      raise invalidForkChoiceState("finalized block header not available")
    var finalHash: common.Hash256
    if not db.getBlockHash(finalBlock.number, finalHash):
      warn "Final block not in canonical chain",
        number=finalBlock.number,
        hash=finalizedBlockHash.short
      raise invalidForkChoiceState("finalized block hash not available")
    if finalHash != finalizedBlockHash:
      warn "Final block not in canonical chain",
        number=finalBlock.number,
        expect=finalizedBlockHash.short,
        get=finalHash.short
      raise invalidForkChoiceState("finalized block not canonical")
    db.finalizedHeaderHash(finalizedBlockHash)

  let safeBlockHash = ethHash update.safeBlockHash
  if safeBlockHash != common.Hash256():
    var safeBlock: common.BlockHeader
    if not db.getBlockHeader(safeBlockHash, safeBlock):
      warn "Safe block not available in database",
        hash = safeBlockHash.short
      raise invalidForkChoiceState("safe head not available")
    var safeHash: common.Hash256
    if not db.getBlockHash(safeBlock.number, safeHash):
      warn "Safe block hash not available in database",
        hash = safeHash.short
      raise invalidForkChoiceState("safe block hash not available")
    if safeHash != safeBlockHash:
      warn "Safe block not in canonical chain",
        blockNumber=safeBlock.number,
        expect=safeBlockHash.short,
        get=safeHash.short
      raise invalidForkChoiceState("safe head not canonical")
    db.safeHeaderHash(safeBlockHash)

  # If payload generation was requested, create a new block to be potentially
  # sealed by the beacon client. The payload will be requested later, and we
  # might replace it arbitrarilly many times in between.
  if attrsOpt.isSome:
    let attrs = attrsOpt.get()
    validateVersion(attrs, com, apiVersion)

    let bundle = ben.generatePayload(attrs).valueOr:
      error "Failed to create sealing payload", err = error
      raise invalidAttr(error)

    let id = computePayloadId(blockHash, attrs)
    ben.put(id, ben.blockValue, bundle.executionPayload, bundle.blobsBundle)

    info "Created payload for sealing",
      id = id.toHex,
      hash = bundle.executionPayload.blockHash.short,
      number = bundle.executionPayload.blockNumber

    return validFCU(Opt.some(id), blockHash)

  return validFCU(Opt.none(PayloadID), blockHash)
