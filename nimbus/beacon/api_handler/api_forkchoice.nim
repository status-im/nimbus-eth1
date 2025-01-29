# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  results,
  eth/common/[headers, hashes, times],
  web3/execution_types,
  chronicles,
  ../../core/tx_pool,
  ../beacon_engine,
  ../web3_eth_conv,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

logScope:
  topics = "beacon engine"

template validateVersion(attr, com, apiVersion) =
  let
    version   = attr.version
    timestamp = ethTime(attr.timestamp)

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
      # ForkchoiceUpdatedV2 after Cancun with beacon root field must return INVALID_PAYLOAD_ATTRIBUTES
      if apiVersion == Version.V2 and attr.parentBeaconBlockRoot.isSome:
        raise invalidAttr("forkChoiceUpdatedV2 with beacon root field is invalid after Cancun")
    elif com.isShanghaiOrLater(timestamp):
      if version < Version.V2:
        raise invalidParams("forkChoiceUpdated" & $apiVersion &
          " doesn't support payloadAttributesV1 when Shanghai is activated")
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
  #  No additional restrictions on the timestamp of the head block
  # See fCUV2 specification No.2 bullet 1
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-1
  if com.isShanghaiOrLater(header.timestamp):
    if apiVersion < Version.V2:
      raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support head block with Shanghai timestamp")

proc forkchoiceUpdated*(ben: BeaconEngineRef,
                        apiVersion: Version,
                        update: ForkchoiceStateV1,
                        attrsOpt: Opt[PayloadAttributes]):
                             ForkchoiceUpdatedResponse =
  let
    com   = ben.com
    txFrame = ben.chain.latestTxFrame()
    chain = ben.chain
    blockHash = update.headBlockHash

  if blockHash == default(Hash32):
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadExecutionStatus.invalid)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  let header = ben.chain.headerByHash(blockHash).valueOr:
    # If this block was previously invalidated, keep rejecting it here too
    let res = ben.checkInvalidAncestor(blockHash, blockHash)
    if res.isSome:
      return simpleFCU(res.get)

    # If the head hash is unknown (was not given to us in a newPayload request),
    # we cannot resolve the header, so not much to do. This could be extended in
    # the future to resolve from the `eth` network, but it's an unexpected case
    # that should be fixed, not papered over.
    var header: Header
    if not ben.get(blockHash, header):
      warn "Forkchoice requested unknown head",
        hash = blockHash.short
      return simpleFCU(PayloadExecutionStatus.syncing)

    # Header advertised via a past newPayload request. Start syncing to it.
    info "Forkchoice requested sync to new head",
      number = header.number,
      hash   = blockHash.short

    # Update sync header (if any)
    com.syncReqNewHead(header)
    com.reqBeaconSyncTargetCB(header, update.finalizedBlockHash)

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
      let
        td  = txFrame.getScore(blockHash)
        ptd = txFrame.getScore(header.parentHash)
        ttd = com.ttd.get(high(UInt256))

      if td.isNone or (blockNumber > 0'u64 and ptd.isNone):
        error "TDs unavailable for TTD check",
          number = blockNumber,
          hash = blockHash.short,
          td = td,
          parent = header.parentHash.short,
          ptd = ptd
        return simpleFCU(PayloadExecutionStatus.invalid, "TDs unavailable for TTD check")

      if td.get < ttd or (blockNumber > 0'u64 and ptd.get > ttd):
        notice "Refusing beacon update to pre-merge",
          number = blockNumber,
          hash = blockHash.short,
          diff = header.difficulty,
          ptd = ptd.get,
          ttd = ttd

        return invalidFCU("Refusing beacon update to pre-merge")

  # If the head block is already in our canonical chain, the beacon client is
  # probably resyncing. Ignore the update.
  # See point 2 of fCUV1 specification
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/paris.md#specification-1
  if ben.chain.isCanonicalAncestor(header.number, blockHash):
    notice "Ignoring beacon update to old head",
      blockHash=blockHash.short,
      blockNumber=header.number
    return validFCU(Opt.none(Bytes8), blockHash)

  # If the beacon client also advertised a finalized block, mark the local
  # chain final and completely in PoS mode.
  let baseTxFrame = ben.chain.baseTxFrame
  let finalizedBlockHash = update.finalizedBlockHash
  if finalizedBlockHash != default(Hash32):
    if not ben.chain.isCanonical(finalizedBlockHash):
      warn "Final block not in canonical chain",
        hash=finalizedBlockHash.short
      raise invalidForkChoiceState("finalized block not canonical")
    baseTxFrame.finalizedHeaderHash(finalizedBlockHash)

  let safeBlockHash = update.safeBlockHash
  if safeBlockHash != default(Hash32):
    if not ben.chain.isCanonical(safeBlockHash):
      warn "Safe block not in canonical chain",
        hash=safeBlockHash.short
      raise invalidForkChoiceState("safe head not canonical")
    baseTxFrame.safeHeaderHash(safeBlockHash)

  chain.forkChoice(blockHash, finalizedBlockHash).isOkOr:
    return invalidFCU(error, chain, header)

  # If payload generation was requested, create a new block to be potentially
  # sealed by the beacon client. The payload will be requested later, and we
  # might replace it arbitrarilly many times in between.
  if attrsOpt.isSome:
    let attrs = attrsOpt.get()
    validateVersion(attrs, com, apiVersion)

    let bundle = ben.generateExecutionBundle(attrs).valueOr:
      error "Failed to create sealing payload", err = error
      raise invalidAttr(error)

    let id = computePayloadId(blockHash, attrs)
    ben.put(id, bundle)

    info "Created payload for block proposal",
      number = bundle.payload.blockNumber,
      hash = bundle.payload.blockHash.short,
      txs = bundle.payload.transactions.len,
      gasUsed = bundle.payload.gasUsed,
      blobGasUsed = bundle.payload.blobGasUsed.get(Quantity(0)),
      id = id.toHex,
      txPoolLen = ben.txPool.len,
      attrs = attrs

    return validFCU(Opt.some(id), blockHash)

  info "Fork choice updated",
    requested = header.number,
    hash = blockHash.short,
    head = ben.chain.latestNumber,
    base = ben.chain.baseNumber,
    baseHash = ben.chain.baseHash.short

  return validFCU(Opt.none(Bytes8), blockHash)
