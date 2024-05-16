# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[sequtils, tables],
  ./web3_eth_conv,
  ./payload_conv,
  chronicles,
  web3/execution_types,
  ./merge_tracker,
  ./payload_queue,
  ./api_handler/api_utils,
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

    # The forkchoice update and new payload method require us to return the
    # latest valid hash in an invalid chain. To support that return, we need
    # to track historical bad blocks as well as bad tipsets in case a chain
    # is constantly built on it.
    #
    # There are a few important caveats in this mechanism:
    #   - The bad block tracking is ephemeral, in-memory only. We must never
    #     persist any bad block information to disk as a bug in Geth could end
    #     up blocking a valid chain, even if a later Geth update would accept
    #     it.
    #   - Bad blocks will get forgotten after a certain threshold of import
    #     attempts and will be retried. The rationale is that if the network
    #     really-really-really tries to feed us a block, we should give it a
    #     new chance, perhaps us being racey instead of the block being legit
    #     bad (this happened in Geth at a point with import vs. pending race).
    #   - Tracking all the blocks built on top of the bad one could be a bit
    #     problematic, so we will only track the head chain segment of a bad
    #     chain to allow discarding progressing bad chains and side chains,
    #     without tracking too much bad data.

    # Ephemeral cache to track invalid blocks and their hit count
    invalidBlocksHits: Table[common.Hash256, int]
    # Ephemeral cache to track invalid tipsets and their bad ancestor
    invalidTipsets   : Table[common.Hash256, common.BlockHeader]

{.push gcsafe, raises:[].}

const
  # invalidBlockHitEviction is the number of times an invalid block can be
  # referenced in forkchoice update or new payload before it is attempted
  # to be reprocessed again.
  invalidBlockHitEviction = 128

  # invalidTipsetsCap is the max number of recent block hashes tracked that
  # have lead to some bad ancestor block. It's just an OOM protection.
  invalidTipsetsCap = 512

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

# setInvalidAncestor is a callback for the downloader to notify us if a bad block
# is encountered during the async sync.
proc setInvalidAncestor(ben: BeaconEngineRef,
                         invalid, origin: common.BlockHeader) =
  ben.invalidTipsets[origin.blockHash] = invalid
  inc ben.invalidBlocksHits.mgetOrPut(invalid.blockHash, 0)

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc new*(_: type BeaconEngineRef,
          txPool: TxPoolRef,
          chain: ChainRef): BeaconEngineRef =
  let ben = BeaconEngineRef(
    txPool: txPool,
    merge : MergeTracker.init(txPool.com.db),
    queue : PayloadQueue(),
    chain : chain,
  )

  txPool.com.notifyBadBlock = proc(invalid, origin: common.BlockHeader)
    {.gcsafe, raises: [].} =
    ben.setInvalidAncestor(invalid, origin)

  ben

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

proc setInvalidAncestor*(ben: BeaconEngineRef, header: common.BlockHeader, blockHash: common.Hash256) =
  ben.invalidBlocksHits[blockHash] = 1
  ben.invalidTipsets[blockHash] = header

# checkInvalidAncestor checks whether the specified chain end links to a known
# bad ancestor. If yes, it constructs the payload failure response to return.
proc checkInvalidAncestor*(ben: BeaconEngineRef,
                           check, head: common.Hash256): Opt[PayloadStatusV1] =
  # If the hash to check is unknown, return valid
  ben.invalidTipsets.withValue(check, invalid) do:
    # If the bad hash was hit too many times, evict it and try to reprocess in
    # the hopes that we have a data race that we can exit out of.
    let badHash = invalid[].blockHash

    inc ben.invalidBlocksHits.mgetOrPut(badHash, 0)
    if ben.invalidBlocksHits.getOrDefault(badHash) >= invalidBlockHitEviction:
      warn "Too many bad block import attempt, trying",
        number=invalid.blockNumber, hash=badHash.short

      ben.invalidBlocksHits.del(badHash)

      var deleted = newSeq[common.Hash256]()
      for descendant, badHeader in ben.invalidTipsets:
        if badHeader.blockHash == badHash:
          deleted.add descendant

      for x in deleted:
        ben.invalidTipsets.del(x)

      return Opt.none(PayloadStatusV1)

    # Not too many failures yet, mark the head of the invalid chain as invalid
    if check != head:
      warn "Marked new chain head as invalid",
        hash=head, badnumber=invalid.blockNumber, badhash=badHash

      if ben.invalidTipsets.len >= invalidTipsetsCap:
        let size = invalidTipsetsCap - ben.invalidTipsets.len
        var deleted = newSeqOfCap[common.Hash256](size)
        for key in ben.invalidTipsets.keys:
          deleted.add key
          if deleted.len >= size:
            break
        for x in deleted:
          ben.invalidTipsets.del(x)

      ben.invalidTipsets[head] = invalid[]

    var lastValid = invalid.parentHash

    # If the last valid hash is the terminal pow block, return 0x0 for latest valid hash
    var header: common.BlockHeader
    if ben.com.db.getBlockHeader(invalid.parentHash, header):
      if header.difficulty != 0.u256:
        lastValid = common.Hash256()

    return Opt.some invalidStatus(lastValid, "links to previously rejected block")

  do:
    return Opt.none(PayloadStatusV1)

# delayPayloadImport stashes the given block away for import at a later time,
# either via a forkchoice update or a sync extension. This method is meant to
# be called by the newpayload command when the block seems to be ok, but some
# prerequisite prevents it from being processed (e.g. no parent, or snap sync).
proc delayPayloadImport*(ben: BeaconEngineRef, header: common.BlockHeader): PayloadStatusV1 =
  # Sanity check that this block's parent is not on a previously invalidated
  # chain. If it is, mark the block as invalid too.
  let blockHash = header.blockHash
  let res = ben.checkInvalidAncestor(header.parentHash, blockHash)
  if res.isSome:
    return res.get

  # Stash the block away for a potential forced forkchoice update to it
  # at a later time.
  ben.put(blockHash, header)

  # Although we don't want to trigger a sync, if there is one already in
  # progress, try to extend it with the current payload request to relieve
  # some strain from the forkchoice update.
  ben.com.syncReqNewHead(header)

  PayloadStatusV1(status: PayloadExecutionStatus.syncing)
