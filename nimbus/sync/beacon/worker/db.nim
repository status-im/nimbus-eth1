# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  pkg/eth/[common, rlp],
  pkg/stew/[byteutils, interval_set, sorted_set],
  pkg/results,
  ../../../db/storage_types,
  ../../../common,
  ../worker_desc,
  "."/[blocks_unproc, headers_unproc]

logScope:
  topics = "beacon db"

const
  LhcStateKey = 1.beaconStateKey

type
  SavedDbStateSpecs = tuple
    number: BlockNumber
    hash: Hash32
    parent: Hash32

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.data.toHex

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fetchSyncStateLayout(ctx: BeaconCtxRef): Opt[SyncStateLayout] =
  let data = ctx.db.ctx.getKvt().get(LhcStateKey.toOpenArray).valueOr:
    return err()
  try:
    result = ok(rlp.decode(data, SyncStateLayout))
  except RlpError:
    return err()


proc fetchSavedState(ctx: BeaconCtxRef): Opt[SavedDbStateSpecs] =
  let db = ctx.db
  var val: SavedDbStateSpecs
  val.number = db.getSavedStateBlockNumber()

  if db.getBlockHash(val.number, val.hash):
    var header: Header
    if db.getBlockHeader(val.hash, header):
      val.parent = header.parentHash
      return ok(val)

  err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbStoreSyncStateLayout*(ctx: BeaconCtxRef): bool =
  ## Save chain layout to persistent db
  const info = "dbStoreLinkedHChainsLayout"
  if ctx.layout == ctx.sst.lastLayout:
    return false

  let data = rlp.encode(ctx.layout)
  ctx.db.ctx.getKvt().put(LhcStateKey.toOpenArray, data).isOkOr:
    raiseAssert info & " put() failed: " & $$error

  # While executing blocks there are frequent save cycles. Otherwise, an
  # extra save request might help to pick up an interrupted sync session.
  let txLevel = ctx.db.level()
  if txLevel == 0:
    let number = ctx.db.getSavedStateBlockNumber()
    ctx.db.persistent(number).isOkOr:
      debug info & ": failed to save persistently", error=($$error)
      return false
  else:
    trace info & ": not saved, tx pending", txLevel
    return false

  trace info & ": saved pesistently on DB"
  true


proc dbLoadSyncStateLayout*(ctx: BeaconCtxRef) =
  ## Restore chain layout from persistent db
  const info = "dbLoadLinkedHChainsLayout"

  let rc = ctx.fetchSyncStateLayout()
  if rc.isOk:
    ctx.sst.layout = rc.value

    # Add interval of unprocessed block range `(B,C]` from `README.md`
    let base = ctx.db.getSavedStateBlockNumber()
    ctx.blocksUnprocSet(base+1, ctx.layout.coupler)

    # Add interval of unprocessed header range `(C,D)` from `README.md`
    ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

    trace info & ": restored layout", B=base.bnStr,
      C=ctx.layout.coupler.bnStr, D=ctx.layout.dangling.bnStr,
      F=ctx.layout.final.bnStr, H=ctx.layout.head.bnStr

  else:
    let val = ctx.fetchSavedState().expect "saved states"
    ctx.sst.layout = SyncStateLayout(
      coupler:        val.number,
      couplerHash:    val.hash,
      dangling:       val.number,
      danglingParent: val.parent,
      final:          val.number,
      finalHash:      val.hash,
      head:           val.number,
      headHash:       val.hash)

    trace info & ": new layout", B="C", C="D", D="F", F="H", H=val.number

  ctx.sst.lastLayout = ctx.layout

# ------------------

proc dbStashHeaders*(
    ctx: BeaconCtxRef;
    first: BlockNumber;
    revBlobs: openArray[seq[byte]];
      ) =
  ## Temporarily store header chain to persistent db (oblivious of the chain
  ## layout.) The headers should not be stashed if they are imepreted and
  ## executed on the database, already.
  ##
  ## The `revBlobs[]` arguments are passed in reverse order so that block
  ## numbers apply as
  ## ::
  ##    #first     -- revBlobs[^1]
  ##    #(first+1) -- revBlobs[^2]
  ##    ..
  ##
  const info = "dbStashHeaders"
  let
    kvt = ctx.db.ctx.getKvt()
    last = first + revBlobs.len.uint64 - 1
  for n,data in revBlobs:
    let key = beaconHeaderKey(last - n.uint64)
    kvt.put(key.toOpenArray, data).isOkOr:
      raiseAssert info & ": put() failed: " & $$error

proc dbPeekHeader*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  let
    key = beaconHeaderKey(num)
    rc = ctx.db.ctx.getKvt().get(key.toOpenArray)
  if rc.isOk:
    try:
      return ok(rlp.decode(rc.value, Header))
    except RlpError:
      discard
  err()

proc dbPeekParentHash*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Hash32] =
  ## Retrieve some stashed parent hash.
  ok (? ctx.dbPeekHeader num).parentHash

proc dbUnstashHeader*(ctx: BeaconCtxRef; bn: BlockNumber) =
  ## Remove header from temporary DB list
  discard ctx.db.ctx.getKvt().del(beaconHeaderKey(bn).toOpenArray)

# ------------------

proc dbStateBlockNumber*(ctx: BeaconCtxRef): BlockNumber =
  ## Currently only a wrapper around the function returning the current
  ## database state block number
  ctx.db.getSavedStateBlockNumber()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
