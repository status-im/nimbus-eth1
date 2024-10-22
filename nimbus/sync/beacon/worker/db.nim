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
  "../../.."/[common, core/chain, db/storage_types],
  ../worker_desc,
  "."/[blocks_unproc, headers_unproc]

logScope:
  topics = "beacon db"

const
  LhcStateKey = 1.beaconStateKey

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
    return ok(rlp.decode(data, SyncStateLayout))
  except RlpError:
    discard
  err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbStoreSyncStateLayout*(ctx: BeaconCtxRef) =
  ## Save chain layout to persistent db
  const info = "dbStoreSyncStateLayout"
  if ctx.layout == ctx.sst.lastLayout:
    return

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
      return
  else:
    trace info & ": not saved, tx pending", txLevel
    return

  trace info & ": saved pesistently on DB"


proc dbLoadSyncStateLayout*(ctx: BeaconCtxRef) =
  ## Restore chain layout from persistent db
  const info = "dbLoadLinkedHChainsLayout"

  let
    rc = ctx.fetchSyncStateLayout()
    latest = ctx.chain.latestNumber()

  if rc.isOk:
    ctx.sst.layout = rc.value

    # Add interval of unprocessed block range `(L,C]` from `README.md`
    ctx.blocksUnprocSet(latest+1, ctx.layout.coupler)
    ctx.blk.topRequest = ctx.layout.coupler

    # Add interval of unprocessed header range `(C,D)` from `README.md`
    ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

    trace info & ": restored layout", L=latest.bnStr,
      C=ctx.layout.coupler.bnStr, D=ctx.layout.dangling.bnStr,
      F=ctx.layout.final.bnStr, H=ctx.layout.head.bnStr

  else:
    let
      latestHash = ctx.chain.latestHash()
      latestParent = ctx.chain.latestHeader.parentHash

    ctx.sst.layout = SyncStateLayout(
      coupler:        latest,
      couplerHash:    latestHash,
      dangling:       latest,
      danglingParent: latestParent,
      final:          latest,
      finalHash:      latestHash,
      head:           latest,
      headHash:       latestHash)

    trace info & ": new layout", L="C", C="D", D="F", F="H", H=latest.bnStr

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
