# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ./web3_eth_conv,
  ./payload_conv,
  ./execution_types,
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
    merge : MergeTrackerRef
    queue : PayloadQueue
    chain : ChainRef

{.push gcsafe, raises:[].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc setWithdrawals(xp: TxPoolRef, attrs: PayloadAttributes) =
  case attrs.version
  of Version.V2, Version.V3:
    xp.withdrawals = ethWithdrawals attrs.withdrawals.get
  else:
    xp.withdrawals = @[]

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
    merge : MergeTrackerRef.new(txPool.com.db),
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
  ben.merge.finalizePos()

proc put*(ben: BeaconEngineRef,
          hash: common.Hash256, header: common.BlockHeader) =
  ben.queue.put(hash, header)

proc put*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: UInt256, payload: ExecutionPayload) =
  ben.queue.put(id, blockValue, payload)

proc put*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: UInt256, payload: SomeExecutionPayload) =
  ben.queue.put(id, blockValue, payload)

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
          payload: var ExecutionPayload): bool =
  ben.queue.get(id, blockValue, payload)

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
          payload: var ExecutionPayloadV3): bool =
  ben.queue.get(id, blockValue, payload)

proc get*(ben: BeaconEngineRef, id: PayloadID,
          blockValue: var UInt256,
          payload: var ExecutionPayloadV1OrV2): bool =
  ben.queue.get(id, blockValue, payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc generatePayload*(ben: BeaconEngineRef,
                      attrs: PayloadAttributes):
                         Result[ExecutionPayload, string] =
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

    xp.setWithdrawals(attrs)

    if headBlock.blockHash != xp.head.blockHash:
       # reorg
       discard xp.smartHead(headBlock)

    # someBaseFee = true: make sure blk.header
    # have the same blockHash with generated payload
    let blk = xp.ethBlock(someBaseFee = true)
    if blk.header.extraData.len > 32:
      return err "extraData length should not exceed 32 bytes"

    ok(executionPayload(blk))
