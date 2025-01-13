# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  results,
  chronicles,
  eth/common/hashes,
  web3/[execution_types, primitives],
  ../../core/tx_pool,
  ../web3_eth_conv,
  ../beacon_engine,
  ../payload_conv,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

logScope:
  topics = "beacon engine"

func validateVersionedHashed(payload: ExecutionPayload,
                              expected: openArray[Hash32]): bool  =
  var versionedHashes: seq[VersionedHash]
  for x in payload.transactions:
    let tx = rlp.decode(distinctBase(x), Transaction)
    versionedHashes.add tx.versionedHashes

  if versionedHashes.len != expected.len:
    return false

  for i, x in expected:
    if distinctBase(x) != versionedHashes[i].data:
      return false
  true

template validateVersion(com, timestamp, payloadVersion, apiVersion) =
  if apiVersion == Version.V4:
    if not com.isPragueOrLater(timestamp):
      raise unsupportedFork("newPayloadV4 expect payload timestamp fall within Prague")

  if com.isPragueOrLater(timestamp):
    if payloadVersion != Version.V3:
      raise invalidParams("if timestamp is Prague or later, " &
        "payload must be ExecutionPayloadV3, got ExecutionPayload" & $payloadVersion)

  if apiVersion == Version.V3:
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork("newPayloadV3 expect payload timestamp fall within Cancun")

  if com.isCancunOrLater(timestamp):
    if payloadVersion != Version.V3:
      raise invalidParams("if timestamp is Cancun or later, " &
        "payload must be ExecutionPayloadV3, got ExecutionPayload" & $payloadVersion)

  elif com.isShanghaiOrLater(timestamp):
    if payloadVersion != Version.V2:
      raise invalidParams("if timestamp is Shanghai or later, " &
        "payload must be ExecutionPayloadV2, got ExecutionPayload" & $payloadVersion)

  elif payloadVersion != Version.V1:
    raise invalidParams("if timestamp is earlier than Shanghai, " &
      "payload must be ExecutionPayloadV1, got ExecutionPayload" & $payloadVersion)

  if apiVersion == Version.V3 or apiVersion == Version.V4:
    # both newPayloadV3 and newPayloadV4 expect ExecutionPayloadV3
    if payloadVersion != Version.V3:
      raise invalidParams("newPayload" & $apiVersion &
      " expect ExecutionPayload3" &
      " but got ExecutionPayload" & $payloadVersion)

template validatePayload(apiVersion, payloadVersion, payload) =
  if payloadVersion >= Version.V2:
    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "withdrawals is expected from execution payload")

  if apiVersion >= Version.V3 or payloadVersion >= Version.V3:
    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "blobGasUsed is expected from execution payload")
    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "excessBlobGas is expected from execution payload")

func validateExecutionRequest(requests: openArray[seq[byte]]): Result[void, string] {.raises:[].} =
  var previousRequestType = -1
  for request in requests:
    if request.len == 0:
      return err("Execution request data must not be empty")

    let requestType = request[0]
    if requestType.int <= previousRequestType:
      return err("Execution requests are not in strictly ascending order")

    if request.len == 1:
      return err("Empty data for request type " & $requestType)

    if requestType notin [
       DEPOSIT_REQUEST_TYPE,
       WITHDRAWAL_REQUEST_TYPE,
       CONSOLIDATION_REQUEST_TYPE]:
      return err("Invalid execution request type: " & $requestType)

    previousRequestType = requestType.int

  ok()

proc newPayload*(ben: BeaconEngineRef,
                 apiVersion: Version,
                 payload: ExecutionPayload,
                 versionedHashes = Opt.none(seq[Hash32]),
                 beaconRoot = Opt.none(Hash32),
                 executionRequests = Opt.none(seq[seq[byte]])): PayloadStatusV1 =

  trace "Engine API request received",
    meth = "newPayload",
    number = payload.blockNumber,
    hash = payload.blockHash

  if apiVersion >= Version.V3:
    if beaconRoot.isNone:
      raise invalidParams("newPayloadV3 expect beaconRoot but got none")

  if apiVersion >= Version.V4:
    if executionRequests.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        ": executionRequests is expected from execution payload")

    validateExecutionRequest(executionRequests.get).isOkOr:
      raise invalidParams("newPayload" & $apiVersion &
        ": " & error)

  let
    com = ben.com
    db  = com.db.baseTxFrame() # TODO this should be forkedchain!
    timestamp = ethTime payload.timestamp
    version = payload.version
    requestsHash = calcRequestsHash(executionRequests)

  validatePayload(apiVersion, version, payload)
  validateVersion(com, timestamp, version, apiVersion)

  var blk = ethBlock(payload, beaconRoot, requestsHash)
  template header: Header = blk.header

  if apiVersion >= Version.V3:
    if versionedHashes.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        " expect blobVersionedHashes but got none")
    if not validateVersionedHashed(payload, versionedHashes.get):
      return invalidStatus(header.parentHash, "invalid blob versionedHashes")

  let blockHash = payload.blockHash
  header.validateBlockHash(blockHash, version).isOkOr:
    return error

  # If we already have the block locally, ignore the entire execution and just
  # return a fake success.
  if ben.chain.haveBlockLocally(blockHash):
    warn "Ignoring already known beacon payload",
      number = header.number, hash = blockHash.short
    return validStatus(blockHash)

  # If this block was rejected previously, keep rejecting it
  let res = ben.checkInvalidAncestor(blockHash, blockHash)
  if res.isSome:
    return res.get

  # If the parent is missing, we - in theory - could trigger a sync, but that
  # would also entail a reorg. That is problematic if multiple sibling blocks
  # are being fed to us, and even moreso, if some semi-distant uncle shortens
  # our live chain. As such, payload execution will not permit reorgs and thus
  # will not trigger a sync cycle. That is fine though, if we get a fork choice
  # update after legit payload executions.
  let parent = ben.chain.headerByHash(header.parentHash).valueOr:
    return ben.delayPayloadImport(header)

  # We have an existing parent, do some sanity checks to avoid the beacon client
  # triggering too early
  let ttd = com.ttd.get(high(UInt256))

  if version == Version.V1:
    let ptd  = db.getScore(header.parentHash).valueOr:
      0.u256
    let gptd  = db.getScore(parent.parentHash)
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
    return invalidStatus(parent.blockHash, "Invalid timestamp")

  # Another corner case: if the node is in snap sync mode, but the CL client
  # tries to make it import a block. That should be denied as pushing something
  # into the database directly will conflict with the assumptions of snap sync
  # that it has an empty db that it can fill itself.
  when false:
    if api.eth.SyncMode() != downloader.FullSync:
      return api.delayPayloadImport(header)

  if not ben.chain.haveBlockAndState(header.parentHash):
    ben.put(blockHash, header)
    warn "State not available, ignoring new payload",
      hash   = blockHash,
      number = header.number
    let blockHash = latestValidHash(com.db, parent, ttd)
    return acceptedStatus(blockHash)

  trace "Inserting block without sethead",
    hash = blockHash, number = header.number
  let vres = ben.chain.importBlock(blk)
  if vres.isErr:
    warn "Error importing block",
      number = header.number,
      hash = blockHash.short,
      parent = header.parentHash.short,
      error = vres.error()
    ben.setInvalidAncestor(header, blockHash)
    let blockHash = latestValidHash(com.db, parent, ttd)
    return invalidStatus(blockHash, vres.error())

  ben.txPool.removeNewBlockTxs(blk, Opt.some(blockHash))

  info "New payload received and validated",
    number = header.number,
    hash = blockHash.short,
    parent = header.parentHash.short,
    txs = blk.transactions.len,
    gasUsed = header.gasUsed,
    blobGas = header.blobGasUsed.get(0'u64)

  return validStatus(blockHash)
