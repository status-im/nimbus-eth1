# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/sequtils,
  ./web3_eth_conv,
  ./payload_conv,
  web3/execution_types,
  ./merge_tracker,
  ./payload_queue,
  ../db/core_db,
  ../core/[tx_pool, casper, chain],
  ../common/common

export
  common,
  chain

type
  BeaconEngineRef* = ref object
    txPool: TxPoolRef
    merge : MergeTracker
    queue : PayloadQueue
    chain : ChainRef

{.push gcsafe, raises:[].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc setWithdrawals(ctx: CasperRef, attrs: PayloadAttributes) =
  case attrs.version
  of Version.V2, Version.V3:
    ctx.withdrawals = ethWithdrawals attrs.withdrawals.get
  else:
    ctx.withdrawals = @[]

template wrapException(body: untyped): auto =
  try:
    body
  except CatchableError as ex:
    err(ex.msg)

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc new*(_: type BeaconEngineRef,
          txPool: TxPoolRef,
          chain: ChainRef): BeaconEngineRef =
  BeaconEngineRef(
    txPool: txPool,
    merge : MergeTracker.init(txPool.com.db),
    queue : PayloadQueue(),
    chain : chain,
  )

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc reachTTD*(ben: BeaconEngineRef) =
  ## ReachTTD is called whenever the first NewHead message received
  ## from the consensus-layer.
  ben.merge.reachTTD()

proc finalizePoS*(ben: BeaconEngineRef) =
  ## FinalizePoS is called whenever the first FinalisedBlock message received
  ## from the consensus-layer.
  ben.merge.finalizePoS()

proc put*(ben: BeaconEngineRef,
          hash: common.Hash256, header: common.BlockHeader) =
  ben.queue.put(hash, header)

proc put*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: UInt256, payload: ExecutionPayload,
          blobsBundle: Option[BlobsBundleV1]) =
  ben.queue.put(id, blockValue, payload, blobsBundle)

proc put*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: UInt256, payload: SomeExecutionPayload,
          blobsBundle: Option[BlobsBundleV1]) =
  doAssert blobsBundle.isNone == (payload is
    ExecutionPayloadV1 | ExecutionPayloadV2)
  ben.queue.put(id, blockValue, payload, blobsBundle)

proc put*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: UInt256,
          payload: ExecutionPayloadV1 | ExecutionPayloadV2) =
  ben.queue.put(
    id, blockValue, payload, blobsBundle = options.none(BlobsBundleV1))

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------
func com*(ben: BeaconEngineRef): CommonRef =
  ben.txPool.com

func chain*(ben: BeaconEngineRef): ChainRef =
  ben.chain

func ttdReached*(ben: BeaconEngineRef): bool =
  ## TTDReached reports whether the chain has left the PoW stage.
  ben.merge.ttdReached

func posFinalized*(ben: BeaconEngineRef): bool =
  ## PoSFinalized reports whether the chain has entered the PoS stage.
  ben.merge.posFinalized

func blockValue*(ben: BeaconEngineRef): UInt256 =
  ## return sum of reward for feeRecipient for each
  ## tx included in a block
  ben.txPool.blockValue

proc get*(ben: BeaconEngineRef, hash: common.Hash256,
          header: var common.BlockHeader): bool =
  ben.queue.get(hash, header)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayload,
          blobsBundle: var Option[BlobsBundleV1]): bool =
  ben.queue.get(id, blockValue, payload, blobsBundle)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV1): bool =
  ben.queue.get(id, blockValue, payload)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV2): bool =
  ben.queue.get(id, blockValue, payload)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV3,
          blobsBundle: var BlobsBundleV1): bool =
  ben.queue.get(id, blockValue, payload, blobsBundle)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV1OrV2): bool =
  ben.queue.get(id, blockValue, payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

type ExecutionPayloadAndBlobsBundle* = object
  executionPayload*: ExecutionPayload
  blobsBundle*: Option[BlobsBundleV1]

proc generatePayload*(ben: BeaconEngineRef,
                      attrs: PayloadAttributes):
                         Result[ExecutionPayloadAndBlobsBundle, string] =
  wrapException:
    let
      xp  = ben.txPool
      db  = xp.com.db
      pos = xp.com.pos
      headBlock = db.getCanonicalHead()

    pos.prevRandao   = ethHash attrs.prevRandao
    pos.timestamp    = ethTime attrs.timestamp
    pos.feeRecipient = ethAddr attrs.suggestedFeeRecipient

    if attrs.parentBeaconBlockRoot.isSome:
      pos.parentBeaconBlockRoot = ethHash attrs.parentBeaconBlockRoot.get

    pos.setWithdrawals(attrs)

    if headBlock.blockHash != xp.head.blockHash:
       # reorg
       discard xp.smartHead(headBlock)

    if pos.timestamp <= headBlock.timestamp:
      return err "timestamp must be strictly later than parent"

    # someBaseFee = true: make sure bundle.blk.header
    # have the same blockHash with generated payload
    let bundle = xp.assembleBlock(someBaseFee = true).valueOr:
      return err(error)

    if bundle.blk.header.extraData.len > 32:
      return err "extraData length should not exceed 32 bytes"

    var blobsBundle: Option[BlobsBundleV1]
    if bundle.blobsBundle.isSome:
      template blobData: untyped = bundle.blobsBundle.get
      blobsBundle = options.some BlobsBundleV1(
        commitments: blobData.commitments.mapIt it.Web3KZGCommitment,
        proofs: blobData.proofs.mapIt it.Web3KZGProof,
        blobs: blobData.blobs.mapIt it.Web3Blob)

    ok ExecutionPayloadAndBlobsBundle(
      executionPayload: executionPayload(bundle.blk),
      blobsBundle: blobsBundle)
