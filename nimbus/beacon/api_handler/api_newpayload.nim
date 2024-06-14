# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common,
  results,
  ../web3_eth_conv,
  ../beacon_engine,
  web3/execution_types,
  ../payload_conv,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

func validateVersionedHashed(payload: ExecutionPayload,
                              expected: openArray[Web3Hash]): bool  =
  var versionedHashes: seq[common.Hash256]
  for x in payload.transactions:
    let tx = rlp.decode(distinctBase(x), Transaction)
    versionedHashes.add tx.versionedHashes

  if versionedHashes.len != expected.len:
    return false

  for i, x in expected:
    if distinctBase(x) != versionedHashes[i].data:
      return false
  true

template validateVersion(com, timestamp, version, apiVersion) =
  if apiVersion == Version.V4:
    if not com.isPragueOrLater(timestamp):
      raise unsupportedFork("newPayloadV4 expect payload timestamp fall within Prague")

  if com.isPragueOrLater(timestamp):
    if version != Version.V4:
      raise invalidParams("if timestamp is Prague or later, " &
        "payload must be ExecutionPayloadV4, got ExecutionPayload" & $version)

  if apiVersion == Version.V3:
    if not com.isCancunOrLater(timestamp):
      raise unsupportedFork("newPayloadV3 expect payload timestamp fall within Cancun")

  if com.isCancunOrLater(timestamp):
    if version != Version.V3:
      raise invalidParams("if timestamp is Cancun or later, " &
        "payload must be ExecutionPayloadV3, got ExecutionPayload" & $version)

  elif com.isShanghaiOrLater(timestamp):
    if version != Version.V2:
      raise invalidParams("if timestamp is Shanghai or later, " &
        "payload must be ExecutionPayloadV2, got ExecutionPayload" & $version)

  elif version != Version.V1:
    raise invalidParams("if timestamp is earlier than Shanghai, " &
      "payload must be ExecutionPayloadV1, got ExecutionPayload" & $version)

  if apiVersion >= Version.V3:
    if version != apiVersion:
      raise invalidParams("newPayload" & $apiVersion &
      " expect ExecutionPayload" & $apiVersion &
      " but got ExecutionPayload" & $version)

template validatePayload(apiVersion, version, payload) =
  if version >= Version.V2:
    if payload.withdrawals.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "withdrawals is expected from execution payload")

  if apiVersion >= Version.V3 or version >= Version.V3:
    if payload.blobGasUsed.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "blobGasUsed is expected from execution payload")
    if payload.excessBlobGas.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "excessBlobGas is expected from execution payload")

  if apiVersion >= Version.V4 or version >= Version.V4:
    if payload.depositReceipts.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "depositReceipts is expected from execution payload")
    if payload.exits.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        "exits is expected from execution payload")


proc newPayload*(ben: BeaconEngineRef,
                 apiVersion: Version,
                 payload: ExecutionPayload,
                 versionedHashes = none(seq[Web3Hash]),
                 beaconRoot = none(Web3Hash)): PayloadStatusV1 =

  trace "Engine API request received",
    meth = "newPayload",
    number = payload.blockNumber,
    hash = payload.blockHash

  if apiVersion >= Version.V3:
    if beaconRoot.isNone:
      raise invalidParams("newPayloadV3 expect beaconRoot but got none")

  let
    com = ben.com
    db  = com.db
    timestamp = ethTime payload.timestamp
    version = payload.version

  validatePayload(apiVersion, version, payload)
  validateVersion(com, timestamp, version, apiVersion)

  var blk = ethBlock(payload, beaconRoot = ethHash beaconRoot)
  template header: BlockHeader = blk.header

  if apiVersion >= Version.V3:
    if versionedHashes.isNone:
      raise invalidParams("newPayload" & $apiVersion &
        " expect blobVersionedHashes but got none")
    if not validateVersionedHashed(payload, versionedHashes.get):
      return invalidStatus(header.parentHash, "invalid blob versionedHashes")

  let blockHash = ethHash payload.blockHash
  header.validateBlockHash(blockHash, version).isOkOr:
    return error

  # If we already have the block locally, ignore the entire execution and just
  # return a fake success.
  if db.getBlockHeader(blockHash, header):
    warn "Ignoring already known beacon payload",
      number = header.blockNumber, hash = blockHash.short
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
  var parent: common.BlockHeader
  if not db.getBlockHeader(header.parentHash, parent):
    return ben.delayPayloadImport(header)

  # We have an existing parent, do some sanity checks to avoid the beacon client
  # triggering too early
  let ttd = com.ttd.get(high(common.BlockNumber))

  if version == Version.V1:
    let td  = db.getScore(header.parentHash).valueOr:
      0.u256
    if (not com.forkGTE(MergeFork)) and td < ttd:
      warn "Ignoring pre-merge payload",
        number = header.blockNumber, hash = blockHash, td, ttd
      return invalidStatus()

  if header.timestamp <= parent.timestamp:
    warn "Invalid timestamp",
      number = header.blockNumber, parentNumber = parent.blockNumber,
      parent = parent.timestamp, header = header.timestamp
    return invalidStatus(parent.blockHash, "Invalid timestamp")

  # Another corner case: if the node is in snap sync mode, but the CL client
  # tries to make it import a block. That should be denied as pushing something
  # into the database directly will conflict with the assumptions of snap sync
  # that it has an empty db that it can fill itself.
  when false:
    if api.eth.SyncMode() != downloader.FullSync:
      return api.delayPayloadImport(header)

  if not db.haveBlockAndState(header.parentHash):
    ben.put(blockHash, header)
    warn "State not available, ignoring new payload",
      hash   = blockHash,
      number = header.blockNumber
    let blockHash = latestValidHash(db, parent, ttd)
    return acceptedStatus(blockHash)

  trace "Inserting block without sethead",
    hash = blockHash, number = header.blockNumber
  let vres = ben.chain.insertBlockWithoutSetHead(blk)
  if vres.isErr:
    ben.setInvalidAncestor(header, blockHash)
    let blockHash = latestValidHash(db, parent, ttd)
    return invalidStatus(blockHash, vres.error())

  # We've accepted a valid payload from the beacon client. Mark the local
  # chain transitions to notify other subsystems (e.g. downloader) of the
  # behavioral change.
  if not ben.ttdReached():
    ben.reachTTD()
    # TODO: cancel downloader

  return validStatus(blockHash)
