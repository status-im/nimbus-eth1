# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  eth/common/[eth_types_json_serialization, headers, hashes, times],
  web3/[conversions, execution_types],
  json_rpc/errors,
  chronicles,
  ../../core/tx_pool,
  ../beacon_engine,
  ../ssz_eth_conv,
  ../web3_eth_conv,
  ./api_utils

import beacon_chain/spec/engine_types as engine_ssz_types
from ../../rpc/engine_ssz_conv import toWeb3, toForkedPayloadAttributes

{.push gcsafe, raises:[].}

logScope:
  topics = "beacon engine"

template validateVersion(attr, com, apiVersion) =
  let
    version   = attr.version
    timestamp = ethTime(attr.timestamp)

  if apiVersion == execution_types.Version.V4:
    if version != apiVersion:
      raise invalidAttr("forkChoiceUpdatedV4 expect PayloadAttributesV4" &
      " but got PayloadAttributes" & $version)
    if not com.isAmsterdamOrLater(timestamp):
      raise unsupportedFork(
        "forkchoiceUpdatedV4 get invalid payloadAttributes timestamp")
  elif apiVersion == execution_types.Version.V3:
    if version != apiVersion:
      raise invalidAttr("forkChoiceUpdatedV3 expect PayloadAttributesV3" &
      " but got PayloadAttributes" & $version)
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork(
        "forkchoiceUpdatedV3 get invalid payloadAttributes timestamp")
  else:
    if com.isCancunOrLater(timestamp):
      if version < execution_types.Version.V3:
        raise unsupportedFork("forkChoiceUpdated" & $apiVersion &
          " doesn't support payloadAttributes" & $version)
      if version > execution_types.Version.V3:
        raise invalidAttr("forkChoiceUpdated" & $apiVersion &
          " doesn't support PayloadAttributes" & $version)
      # ForkchoiceUpdatedV2 after Cancun with beacon root field must return INVALID_PAYLOAD_ATTRIBUTES
      if apiVersion == execution_types.Version.V2 and attr.parentBeaconBlockRoot.isSome:
        raise invalidAttr("forkChoiceUpdatedV2 with beacon root field is invalid after Cancun")
    elif com.isShanghaiOrLater(timestamp):
      if version < execution_types.Version.V2:
        raise invalidParams("forkChoiceUpdated" & $apiVersion &
          " doesn't support payloadAttributesV1 when Shanghai is activated")
      if version > execution_types.Version.V2:
        raise invalidAttr("if timestamp is Shanghai or later," &
          " payloadAttributes must be PayloadAttributesV2")
    else:
      if version != execution_types.Version.V1:
        raise invalidParams("if timestamp is earlier than Shanghai," &
          " payloadAttributes must be PayloadAttributesV1")

template validateAttributes(fork, com, timestamp) =
  case fork
  of EngineFork.Amsterdam:
    if not com.isAmsterdamOrLater(timestamp):
      raise invalidAttr("forkchoiceUpdated: payloadAttributes timestamp is not yet Amsterdam")
  of EngineFork.Cancun, EngineFork.Prague, EngineFork.Osaka:
    if not com.isCancunOrLater(timestamp):
      raise invalidAttr("forkchoiceUpdated: payloadAttributes timestamp is not yet Cancun")
  of EngineFork.Shanghai:
    if com.isCancunOrLater(timestamp):
      raise invalidAttr("forkchoiceUpdated: Shanghai payloadAttributes is invalid after Cancun")
    elif not com.isShanghaiOrLater(timestamp):
      raise invalidAttr("forkchoiceUpdated: payloadAttributes timestamp is not yet Shanghai")
  of EngineFork.Paris:
    if com.isShanghaiOrLater(timestamp):
      raise invalidAttr("forkchoiceUpdated: Paris payloadAttributes is invalid on/after Shanghai")

template validateHeaderTimestamp(header, com, isParis) =
  # See fCUV3 specification No.2 bullet iii
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/cancun.md#specification-1
  #  No additional restrictions on the timestamp of the head block
  # See fCUV2 specification No.2 bullet 1
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-1
  if isParis and com.isShanghaiOrLater(header.timestamp):
    raise invalidAttr("forkchoiceUpdated: Paris (V1) is invalid for a head block at or after Shanghai")

proc processForkchoiceUpdate(ben: BeaconEngineRef,
                        isParis: bool,
                        headHash, safeBlockHash, finalizedBlockHash: Hash32,
                        attrsOpt: Opt[ForkedPayloadAttributes]):
                          Future[engine_ssz_types.ForkchoiceUpdateResponse]
                            {.async: (raises: [CancelledError, ApplicationError]).} =
  let
    com   = ben.com
    chain = ben.chain

  if headHash == zeroHash32:
    warn "Forkchoice requested update to zero hash"
    return simpleFCU(PayloadStatusCode.INVALID)

  # Try updateing the finalised header argument by hash. If unsuccessful,
  # the hash will be stored in `pendingFCU`. Otherwise, hash and block
  # number will have been stored in `latestFinalized`.
  com.resolveFinHash(finalizedBlockHash)

  # Check whether we have the block yet in our database or not. If not, we'll
  # need to either trigger a sync, or to reject this forkchoice update for a
  # reason.
  let header = chain.headerByHash(headHash).valueOr:
    # If this block was previously invalidated, keep rejecting it here too
    let res = ben.checkInvalidAncestor(headHash, headHash)
    if res.isSome:
      return simpleFCU(res.value)

    # If the head hash is unknown (was not given to us in a newPayload
    # request), ask the syncer to fetch the head header from a connected
    # peer over the `eth` wire protocol. Once the header arrives, the
    # syncer's normal header-chain sync activates toward it.
    let header = chain.quarantine.getHeader(headHash).valueOr:
      info "Forkchoice requested sync to unknown head",
        hash = headHash.short,
        finHash = finalizedBlockHash.short,
        safe = safeBlockHash.short,
        base = chain.baseNumber,
        pendingFCU = chain.pendingFCU.short
      com.headerTargetRequest(headHash, finalizedBlockHash)
      return simpleFCU(PayloadStatusCode.SYNCING)

    # Header advertised via a past newPayload request. Start syncing to it.
    info "Forkchoice requested sync to new head",
      number = header.number,
      hash   = headHash.short,
      base   = chain.baseNumber,
      finHash= finalizedBlockHash.short,
      safe   = safeBlockHash.short,
      pendingFCU = chain.pendingFCU.short,
      resolvedFinNum = chain.resolvedFinNumber,
      resolvedFinHash = chain.resolvedFinHash.short

    # Inform the header chain cache (used by the syncer)
    com.headerChainUpdate(header, finalizedBlockHash)

    return simpleFCU(PayloadStatusCode.SYNCING)

  validateHeaderTimestamp(header, com, isParis)

  # Block is known locally, just sanity check that the beacon client does not
  # attempt to push us back to before the merge.
  #
  # Disable terminal PoW block conditions validation for fCUV2 and later.
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-1
  if isParis:
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
        return simpleFCU(PayloadStatusCode.INVALID, "TDs unavailable for TTD check")

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
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.7/src/engine/paris.md#specification-1
  if chain.isCanonicalAndFinalizedAncestor(header.number, headHash, finalizedBlockHash):
    notice "Ignoring beacon update to old head",
      headHash   = headHash.short,
      headNumber = header.number,
      base       = chain.baseNumber,
      pendingFCU = chain.pendingFCU.short,
      resolvedFinNum = chain.resolvedFinNumber,
      resolvedFinHash = chain.resolvedFinHash.short
    return validFCU(Opt.none(Bytes8), headHash)

  # If the beacon client also advertised a finalized block, mark the local
  # chain final and completely in PoS mode.
  if finalizedBlockHash != zeroHash32:
    if not chain.equalOrAncestorOf(finalizedBlockHash, headHash):
      warn "Final block not in canonical tree",
        hash=finalizedBlockHash.short
      raise invalidForkChoiceState("finalized block not in canonical tree")
    # similar to headHash, finalizedBlockHash is saved by FC module

  if safeBlockHash != zeroHash32:
    if not chain.equalOrAncestorOf(safeBlockHash, headHash):
      warn "Safe block not in canonical tree",
        hash=safeBlockHash.short
      raise invalidForkChoiceState("safe block not in canonical tree")
    # similar to headHash, safeBlockHash is saved by FC module

  (await chain.queueForkChoice(headHash, finalizedBlockHash, safeBlockHash)).isOkOr:
    return invalidFCU(error.msg, chain, header)

  # If payload generation was requested, create a new block to be potentially
  # sealed by the beacon client. The payload will be requested later, and we
  # might replace it arbitrarilly many times in between.
  if attrsOpt.isSome:
    let
      attrs = attrsOpt.value
      bundle = ben.generateExecutionBundle(headHash, attrs).valueOr:
        error "Failed to create sealing payload", err = error
        raise invalidAttr(error)

    let id = computePayloadId(headHash, attrs)
    ben.putPayloadBundle(id, bundle)

    info "Created payload for block proposal",
      number = bundle.blk.header.number,
      hash = bundle.blk.header.computeRlpHash.short,
      txs = bundle.blk.transactions.len,
      gasUsed = bundle.blk.header.gasUsed,
      blobGasUsed = bundle.blk.header.blobGasUsed.get(0'u64),
      id = id.toHex,
      txPoolLen = ben.txPool.len,
      attrs = attrs

    return validFCU(Opt.some(id), headHash)

  info "Fork choice updated",
    requested = header.number,
    head = chain.latestNumber,
    headHash = headHash.short,
    base = chain.baseNumber,
    baseHash = chain.baseHash.short,
    finalizedHash = finalizedBlockHash.short,
    resolvedFinNum = chain.resolvedFinNumber,
    resolvedFinHash = chain.resolvedFinHash.short

  return validFCU(Opt.none(Bytes8), headHash)

# REMOVE WHEN DROPPING JSON-RPC
proc forkchoiceUpdated*(ben: BeaconEngineRef,
                        apiVersion: execution_types.Version,
                        update: ForkchoiceStateV1,
                        attrsOpt: Opt[PayloadAttributes]):
                          Future[ForkchoiceUpdatedResponse]
                            {.async: (raises: [CancelledError, ApplicationError]).} =
  var forkedAttrsOpt = Opt.none(ForkedPayloadAttributes)
  if attrsOpt.isSome:
    let attrs = attrsOpt.value
    validateVersion(attrs, ben.com, apiVersion)
    forkedAttrsOpt = Opt.some(toForkedPayloadAttributes(attrs))

  toWeb3(await processForkchoiceUpdate(ben, apiVersion == execution_types.Version.V1,
    update.headBlockHash, update.safeBlockHash, update.finalizedBlockHash, forkedAttrsOpt))

proc forkchoiceUpdated*(ben: BeaconEngineRef,
                        fork: EngineFork,
                        fcState: engine_ssz_types.ForkchoiceState,
                        attrsOpt: Opt[ForkedPayloadAttributes]):
                          Future[engine_ssz_types.ForkchoiceUpdateResponse]
                            {.async: (raises: [CancelledError, ApplicationError]).} =
  if attrsOpt.isSome:
    validateAttributes(fork, ben.com, EthTime(attrsOpt.value.timestamp))

  await processForkchoiceUpdate(ben, fork == EngineFork.Paris,
    toHash32(fcState.head_block_hash), toHash32(fcState.safe_block_hash),
    toHash32(fcState.finalized_block_hash), attrsOpt)
