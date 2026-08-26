# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe, raises:[].}

import
  results,
  chronicles,
  chronos,
  eth/common/hashes,
  web3/[execution_types, primitives],
  json_rpc/errors,
  ../../core/tx_pool,
  ../web3_eth_conv,
  ../beacon_engine,
  ../payload_conv,
  ./api_utils

from beacon_chain/spec/engine_types import EngineFork, PayloadStatus
from ../../rpc/engine_ssz_conv import toSsz, toWeb3
from beacon_chain/spec/forks import ForkyExecutionPayload
from ../ssz_eth_conv import ethBlock, toHash32

logScope:
  topics = "beacon engine"

func validateVersionedHashed(txs: openArray[Transaction],
                              expected: openArray[Hash32]): bool =
  var versionedHashes: seq[VersionedHash]
  for tx in txs:
    versionedHashes.add tx.versionedHashes

  if versionedHashes.len != expected.len:
    return false

  for i, x in expected:
    if distinctBase(x) != versionedHashes[i].data:
      return false
  true

# REMOVE WHEN DROPPING JSON-RPC
template validateVersionMethod(apiVersion, com, timestamp, payloadVersion, payload) =
  if apiVersion == execution_types.Version.V5:
    if not com.isAmsterdamOrLater(timestamp):
      raise unsupportedFork("newPayloadV5 expect payload timestamp fall within Amsterdam")

  elif apiVersion == execution_types.Version.V4:
    if not com.isPragueOrLater(timestamp):
      raise unsupportedFork("newPayloadV4 expect payload timestamp fall within Prague or Osaka")

  elif apiVersion == execution_types.Version.V3:
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork("newPayloadV3 expect payload timestamp fall within Cancun")

  if com.isAmsterdamOrLater(timestamp):
    # TODO: probably blockAccessList field should be a seq[byte] instead of Opt[seq[byte]]
    if payload.blockAccessList.isNone or payload.blockAccessList.value.len == 0:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing blockAccessList")

    if payload.slotNumber.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing slotNumber")

    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing excessBlobGas")

    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing blobGasUsed")

    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing withdrawals")

  elif com.isPragueOrLater(timestamp):
    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing excessBlobGas")

    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing blobGasUsed")

    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing withdrawals")

  elif com.isCancunOrLater(timestamp):
    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing excessBlobGas")

    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing blobGasUsed")

    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing withdrawals")

  elif com.isShanghaiOrLater(timestamp):
    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": payload missing withdrawals")

  elif payloadVersion != execution_types.Version.V1:
    raise invalidParams("if timestamp is earlier than Shanghai, " &
      "payload must be ExecutionPayloadV1, got ExecutionPayload" & $payloadVersion)

  if payload.withdrawals.isSome:
    if not com.isShanghaiOrLater(EthTime payload.timestamp):
      raise invalidParams("newPayload" & $apiVersion &
        ": withdrawals appear before Shanghai")

  if payload.blobGasUsed.isSome:
    if not com.isCancunOrLater(EthTime payload.timestamp):
      raise invalidParams("newPayload" & $apiVersion &
        ": blobGasUsed appear before Cancun")

  if payload.excessBlobGas.isSome:
    if not com.isCancunOrLater(EthTime payload.timestamp):
      raise invalidParams("newPayload" & $apiVersion &
        ": excessBlobGas appear before Cancun")

  # TODO: probably blockAccessList field should be a seq[byte] instead of Opt[seq[byte]]
  if payload.blockAccessList.isSome and payload.blockAccessList.value.len > 0:
    if not com.isAmsterdamOrLater(EthTime payload.timestamp):
      raise invalidParams("newPayload" & $apiVersion &
        ": blockAccessList appear before Amsterdam")

  if payload.slotNumber.isSome:
    if not com.isAmsterdamOrLater(EthTime payload.timestamp):
      raise invalidParams("newPayload" & $apiVersion &
        ": slotNumber appear before Amsterdam")

template validateForkTimestamp(fork, com, timestamp) =
  case fork
  of EngineFork.Amsterdam:
    if not com.isAmsterdamOrLater(timestamp):
      raise invalidParams("newPayload: payload timestamp is not yet Amsterdam")

  of EngineFork.Cancun, EngineFork.Prague, EngineFork.Osaka:
    if com.isAmsterdamOrLater(timestamp):
      raise invalidParams("newPayload: if timestamp is Amsterdam or later, " &
        "payload must be ExecutionPayloadV4")
    elif not com.isCancunOrLater(timestamp):
      raise invalidParams("newPayload: payload timestamp is not yet Cancun")

  of EngineFork.Shanghai:
    if com.isCancunOrLater(timestamp):
      raise invalidParams("newPayload: if timestamp is Cancun or later, " &
        "payload must be ExecutionPayloadV3")
    elif not com.isShanghaiOrLater(timestamp):
      raise invalidParams("newPayload: payload timestamp is not yet Shanghai")

  of EngineFork.Paris:
    if com.isShanghaiOrLater(timestamp):
      raise invalidParams("newPayload: if timestamp is Shanghai or later, " &
        "payload must be ExecutionPayloadV2")

# REMOVE WHEN DROPPING JSON-RPC
template validatePayload(apiVersion, payloadVersion, payload) =
  if payloadVersion >= execution_types.Version.V2:
    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": withdrawals is expected from execution payload")

  if apiVersion >= execution_types.Version.V3:
    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": blobGasUsed is expected from execution payload")
    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": excessBlobGas is expected from execution payload")

  if apiVersion >= execution_types.Version.V5:
    if payload.blockAccessList.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": blockAccessList is expected from execution payload")
    if payload.slotNumber.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": slotNumber is expected from execution payload")

# https://github.com/ethereum/execution-apis/blob/40088597b8b4f48c45184da002e27ffc3c37641f/src/engine/prague.md#request
func validateExecutionRequest(
            requests: openArray[seq[byte]], fork: EngineFork):
              Opt[PayloadStatus] {.raises: [ApplicationError].} =
  var previousRequestType = -1
  for request in requests:
    if request.len == 0:
      raise invalidParams("newPayload" & $fork &
        ": Execution request data must not be empty")

    let requestType = request[0]
    if requestType.int <= previousRequestType:
      raise invalidParams("newPayload" & $fork &
        ": Execution requests are not in strictly ascending order")

    if request.len == 1:
      raise invalidParams("newPayload" & $fork &
        ": Empty data for request type " & $requestType)

    if fork == EngineFork.Amsterdam:
      if requestType notin [
        DEPOSIT_REQUEST_TYPE,
        WITHDRAWAL_REQUEST_TYPE,
        CONSOLIDATION_REQUEST_TYPE,
        BUILDER_DEPOSIT_REQUEST_TYPE,
        BUILDER_EXIT_REQUEST_TYPE]:
        return Opt.some(invalidStatus(
          "newPayload" & $fork & ": Invalid execution request type" & $requestType))
    else:
      if requestType notin [
        DEPOSIT_REQUEST_TYPE,
        WITHDRAWAL_REQUEST_TYPE,
        CONSOLIDATION_REQUEST_TYPE]:
        return Opt.some(invalidStatus(
          "newPayload" & $fork & ": Invalid execution request type" & $requestType))

    previousRequestType = requestType.int
  Opt.none(PayloadStatus)

proc processNewPayload(ben: BeaconEngineRef,
                        fork: EngineFork,
                        blk: Block,
                        blockAccessList: Opt[BlockAccessListRef],
                        blockHash: Hash32,
                        versionedHashes: Opt[seq[Hash32]], # only needed for json rpc spec
                        executionRequests: Opt[seq[seq[byte]]]):
                          Future[PayloadStatus]
                            {.async: (raises: [CancelledError, ApplicationError]).} =
  let
    com   = ben.com
    chain = ben.chain

  template header: Header = blk.header

  trace "Engine API request received",
    meth = "newPayload",
    number = header.number,
    hash = blockHash

  if fork >= EngineFork.Cancun:
    if header.parentBeaconBlockRoot.isNone:
      raise invalidParams("newPayload" & $fork & " expect beaconRoot but got none")

  if fork >= EngineFork.Prague:
    if executionRequests.isNone:
      raise invalidParams("newPayload" & $fork &
        ": executionRequests is expected from execution payload")

    let res = validateExecutionRequest(executionRequests.value, fork)
    if res.isSome:
      return res.value

  validateForkTimestamp(fork, com, header.timestamp)

  if versionedHashes.isSome:
    if not validateVersionedHashed(blk.transactions, versionedHashes.value):
      return invalidStatus(header.parentHash, "invalid blob versionedHashes")

  header.validateBlockHash(blockHash, fork).isOkOr:
    return toSsz(error)

  # If we already have the block locally, ignore the entire execution and just
  # return a fake success.
  if chain.haveBlockAndState(blockHash):
    debug "Ignoring already known beacon payload",
      number = header.number, hash = blockHash.short
    return validStatus(blockHash)

  # If this block was rejected previously, keep rejecting it
  block:
    let res = ben.checkInvalidAncestor(blockHash, blockHash)
    if res.isSome:
      return res.value

  # If the parent is missing, we - in theory - could trigger a sync, but that
  # would also entail a reorg. That is problematic if multiple sibling blocks
  # are being fed to us, and even moreso, if some semi-distant uncle shortens
  # our live chain. As such, payload execution will not permit reorgs and thus
  # will not trigger a sync cycle. That is fine though, if we get a fork choice
  # update after legit payload executions.
  let parent = chain.headerByHash(header.parentHash).valueOr:
    return ben.delayPayloadImport(blockHash, blk, blockAccessList)

  # We have an existing parent, do some sanity checks to avoid the beacon client
  # triggering too early
  let ttd = com.ttd.get(high(UInt256))

  if fork == EngineFork.Paris:
    let txFrame = chain.latestTxFrame()
    let ptd  = txFrame.getScore(header.parentHash).valueOr:
      0.u256
    let gptd  = txFrame.getScore(parent.parentHash)
    if ptd < ttd:
      warn "Ignoring pre-merge payload",
        number = header.number, hash = blockHash.short, ptd, ttd
      return invalidStatus()
    if parent.difficulty > 0.u256 and gptd.isSome and gptd.value >= ttd:
      warn "Ignoring pre-merge parent block",
        number = header.number, hash = blockHash.short, ptd, ttd
      return invalidStatus()

  if header.timestamp <= parent.timestamp:
    warn "Invalid timestamp",
      number = header.number, parentNumber = parent.number,
      parent = parent.timestamp, header = header.timestamp
    return invalidStatus(parent.computeBlockHash, "Invalid timestamp")

  if not chain.haveBlockAndState(header.parentHash):
    chain.quarantine.addOrphan(blockHash, blk, blockAccessList)
    warn "State not available, ignoring new payload",
      hash   = blockHash,
      number = header.number
    let
      txFrame = chain.latestTxFrame()
      blockHash = latestValidHash(txFrame, parent, ttd)
    return acceptedStatus(blockHash)

  trace "Importing block without sethead",
    hash = blockHash, number = header.number

  block:
    let res = await chain.queueImportBlock(blk, blockAccessList)
    if res.isErr:
      warn "Error importing block",
        number = header.number,
        hash = blockHash.short,
        parent = header.parentHash.short,
        error = res.error.msg
      ben.setInvalidAncestor(header, blockHash)
      let
        txFrame = chain.latestTxFrame()
        blockHash = latestValidHash(txFrame, parent, ttd)
      return invalidStatus(blockHash, res.error.msg)

  ben.txPool.removeNewBlockTxs(blk, Opt.some(blockHash))

  info "New payload received and validated",
    number = header.number,
    hash = blockHash.short,
    parent = header.parentHash.short,
    txs = blk.transactions.len,
    gasUsed = header.gasUsed,
    blobGas = header.blobGasUsed.get(0'u64)

  return validStatus(blockHash)

# REMOVE WHEN DROPPING JSON-RPC
# assigns the earliest fork per version tag
func apiVersionFork(apiVersion: execution_types.Version): EngineFork =
  case apiVersion
  of execution_types.Version.V1: EngineFork.Paris
  of execution_types.Version.V2: EngineFork.Shanghai
  of execution_types.Version.V3: EngineFork.Cancun
  of execution_types.Version.V4: EngineFork.Prague
  of execution_types.Version.V5, execution_types.Version.V6: EngineFork.Amsterdam

# REMOVE WHEN DROPPING JSON-RPC
proc newPayload*(ben: BeaconEngineRef,
                 apiVersion: execution_types.Version,
                 payload: ExecutionPayload,
                 versionedHashes = Opt.none(seq[Hash32]),
                 beaconRoot = Opt.none(Hash32),
                 executionRequests = Opt.none(seq[seq[byte]])):
                   Future[PayloadStatusV1] {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
  let apiFork = apiVersionFork(apiVersion)

  let
    com = ben.com
    timestamp = ethTime payload.timestamp
    payloadVersion = payload.version

  validatePayload(apiVersion, payloadVersion, payload)
  validateVersionMethod(apiVersion, com, timestamp, payloadVersion, payload)

  if apiFork >= EngineFork.Cancun:
    if versionedHashes.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        " expect blobVersionedHashes but got none")

  let
    requestsHash = calcRequestsHash(executionRequests)
    blk =
      try:
        ethBlock(payload, beaconRoot, requestsHash)
      except RlpError as e:
        warn "Failed to decode payload",
          error = e.msg
        return toWeb3(invalidStatus("newPayload" & $apiVersion &
          ": Failed to decode block in payload: " & e.msg))
    blockAccessList =
      try:
        blockAccessList(payload)
      except RlpError as e:
        warn "Failed to decode payload",
          error = e.msg
        raise invalidParams("newPayload" & $apiVersion &
          ": Failed to decode BAL in payload: " & e.msg)

  toWeb3(await processNewPayload(ben, apiFork, blk, blockAccessList,
    payload.blockHash, versionedHashes, executionRequests))

proc newPayload*(ben: BeaconEngineRef,
                    fork: EngineFork,
                    payload: ForkyExecutionPayload,
                    blockAccessList: Opt[BlockAccessListRef],
                    beaconRoot: Opt[Hash32],
                    executionRequests: Opt[seq[seq[byte]]]):
                      Future[PayloadStatus]
                        {.async: (raises: [CancelledError, ApplicationError, RlpError]).} =
  let
    requestsHash = calcRequestsHash(executionRequests)
    blk = ethBlock(payload, beaconRoot, requestsHash)
    blockHash = toHash32(payload.block_hash)
  var res = await processNewPayload(ben, fork, blk, blockAccessList,
    blockHash, Opt.none(seq[Hash32]), executionRequests)

  # REMOVE WHEN DROPPING JSON-RPC
  if res.status == uint8(PayloadStatusCode.INVALID_BLOCK_HASH):
    res.status = uint8(PayloadStatusCode.INVALID)

  res
