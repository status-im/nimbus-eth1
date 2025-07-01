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
  chronos,
  eth/common/[headers, hashes, times],
  web3/execution_types,
  json_rpc/errors,
  chronicles,
  ../../core/tx_pool,
  ../beacon_engine,
  ../web3_eth_conv,
  ./api_utils

{.push gcsafe, raises:[].}

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
                          Future[ForkchoiceUpdatedResponse]
                            {.async: (raises: [CancelledError, InvalidRequest]).} =
  let
    com   = ben.com
    chain = ben.chain
    headHash = update.headBlockHash

  if headHash == zeroHash32:
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadExecutionStatus.invalid)

  chain.pendingFCU = update.finalizedBlockHash
  com.resolveFinHash(update.finalizedBlockHash)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  let header = chain.headerByHash(headHash).valueOr:
    # If this block was previously invalidated, keep rejecting it here too
    let res = ben.checkInvalidAncestor(headHash, headHash)
    if res.isSome:
      return simpleFCU(res.value)

    # If the head hash is unknown (was not given to us in a newPayload request),
    # we cannot resolve the header, so not much to do. This could be extended in
    # the future to resolve from the `eth` network, but it's an unexpected case
    # that should be fixed, not papered over.
    let header = chain.quarantine.getHeader(headHash).valueOr:
      warn "Forkchoice requested unknown head",
        hash = headHash.short
      return simpleFCU(PayloadExecutionStatus.syncing)

    # Header advertised via a past newPayload request. Start syncing to it.
    info "Forkchoice requested sync to new head",
      number = header.number,
      hash   = headHash.short,
      base   = chain.baseNumber,
      finHash= update.finalizedBlockHash.short,
      safe   = update.safeBlockHash.short,
      pendingFCU = chain.finHash.short,
      resolvedFin= chain.resolvedFinNumber

    # Inform the header chain cache (used by the syncer)
    com.headerChainUpdate(header, update.finalizedBlockHash)

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
        txFrame = chain.latestTxFrame()
        td  = txFrame.getScore(headHash)
        ptd = txFrame.getScore(header.parentHash)
        ttd = com.ttd.get(high(UInt256))

      if td.isNone or (blockNumber > 0'u64 and ptd.isNone):
        error "TDs unavailable for TTD check",
          number = blockNumber,
          hash = headHash.short,
          td = td,
          parent = header.parentHash.short,
          ptd = ptd
        return simpleFCU(PayloadExecutionStatus.invalid, "TDs unavailable for TTD check")

      if td.value < ttd or (blockNumber > 0'u64 and ptd.value > ttd):
        notice "Refusing beacon update to pre-merge",
          number = blockNumber,
          hash = headHash.short,
          diff = header.difficulty,
          ptd = ptd.value,
          ttd = ttd

        return invalidFCU("Refusing beacon update to pre-merge")

  # If the head block is already in our canonical chain, the beacon client is
  # probably resyncing. Ignore the update.
  # See point 2 of fCUV1 specification
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/paris.md#specification-1
  if chain.isCanonicalAncestor(header.number, headHash):
    notice "Ignoring beacon update to old head",
      headHash   = headHash.short,
      headNumber = header.number,
      base       = chain.baseNumber,
      pendingFCU = chain.finHash.short,
      resolvedFin= chain.resolvedFinNumber
    return validFCU(Opt.none(Bytes8), headHash)

  # If the beacon client also advertised a finalized block, mark the local
  # chain final and completely in PoS mode.
  let finalizedBlockHash = update.finalizedBlockHash
  if finalizedBlockHash != zeroHash32:
    if not chain.equalOrAncestorOf(finalizedBlockHash, headHash):
      warn "Final block not in canonical tree",
        hash=finalizedBlockHash.short
      raise invalidForkChoiceState("finalized block not in canonical tree")
    # similar to headHash, finalizedBlockHash is saved by FC module

  let safeBlockHash = update.safeBlockHash
  if safeBlockHash != zeroHash32:
    if not chain.equalOrAncestorOf(safeBlockHash, headHash):
      warn "Safe block not in canonical tree",
        hash=safeBlockHash.short
      raise invalidForkChoiceState("safe block not in canonical tree")
    # similar to headHash, safeBlockHash is saved by FC module

  (await chain.queueForkChoice(headHash, finalizedBlockHash, safeBlockHash)).isOkOr:
    return invalidFCU(error, chain, header)

  # If payload generation was requested, create a new block to be potentially
  # sealed by the beacon client. The payload will be requested later, and we
  # might replace it arbitrarilly many times in between.
  if attrsOpt.isSome:
    let attrs = attrsOpt.value
    validateVersion(attrs, com, apiVersion)

    let bundle = ben.generateExecutionBundle(attrs).valueOr:
      error "Failed to create sealing payload", err = error
      raise invalidAttr(error)

    let id = computePayloadId(headHash, attrs)
    ben.putPayloadBundle(id, bundle)

    info "Created payload for block proposal",
      number = bundle.payload.blockNumber,
      hash = bundle.payload.blockHash.short,
      txs = bundle.payload.transactions.len,
      gasUsed = bundle.payload.gasUsed,
      blobGasUsed = bundle.payload.blobGasUsed.get(Quantity(0)),
      id = id.toHex,
      txPoolLen = ben.txPool.len,
      attrs = attrs

    return validFCU(Opt.some(id), headHash)

  info "Fork choice updated",
    requested = header.number,
    head = chain.latestNumber,
    hashHash = headHash.short,
    base = chain.baseNumber,
    baseHash = chain.baseHash.short,
    finalizedHash = finalizedBlockHash.short,
    resolvedFin = chain.resolvedFinNumber

  return validFCU(Opt.none(Bytes8), headHash)
