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

proc dbStoreSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Save chain layout to persistent db
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
      debug info & ": failed to save sync state persistently", error=($$error)
      return
  else:
    trace info & ": sync state not saved, tx pending", txLevel
    return

  trace info & ": saved sync state persistently"


proc dbClearSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Clear saved state. This function might not succeed (see comments on
  ## function `dbStoreSyncStateLayout()`) in which case the state is only
  ## locally deleted but might not be saved permanently.
  ##
  if ctx.db.ctx.getKvt().del(LhcStateKey.toOpenArray).isOk:
    let number = ctx.db.getSavedStateBlockNumber()
    ctx.db.persistent(number).isOkOr:
      debug info & ": failed to clear persistent sync state", error=($$error)


proc dbLoadSyncStateAvailable*(ctx: BeaconCtxRef): bool =
  ## Check whether `dbLoadSyncStateLayout()` would load a saved state
  let rc = ctx.fetchSyncStateLayout()
  rc.isOk and
    # The base number is the least record of the FCU chains. So the finalised
    # entry must not be smaller.
    ctx.chain.baseNumber() <= rc.value.final and
    # If the latest FCU number is not larger than the head, there is nothing
    # to do (might also happen after a manual import.)
    ctx.chain.latestNumber() < rc.value.head


proc dbLoadSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Restore chain layout from persistent db
  let
    rc = ctx.fetchSyncStateLayout()
    latest = ctx.chain.latestNumber()

  # See `dbLoadSyncStateAvailable()` for comments
  if rc.isOk and
     ctx.chain.baseNumber() <= rc.value.final and
     latest < rc.value.head:
    ctx.sst.layout = rc.value

    # Add interval of unprocessed block range `(L,C]` from `README.md`
    ctx.blocksUnprocSet(latest+1, ctx.layout.coupler)
    ctx.blk.topRequest = ctx.layout.coupler

    # Add interval of unprocessed header range `(C,D)` from `README.md`
    ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

    trace info & ": restored sync state", L=latest.bnStr,
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
      # There is no need to record a separate finalised head `F` as its only
      # use is to serve as second argument in `forkChoice()` when committing
      # a batch of imported blocks. Currently, there are no blocks to fetch
      # and import. The system must wait for instructions and update the fields
      # `final` and `head` while the latter will be increased so that import
      # can start.
      final:          latest,
      finalHash:      latestHash,
      head:           latest,
      headHash:       latestHash,
      headLocked:     false)

    trace info & ": new sync state", L="C", C="D", D="F", F="H", H=latest.bnStr

  ctx.sst.lastLayout = ctx.layout

# ------------------

proc dbStashHeaders*(
    ctx: BeaconCtxRef;
    first: BlockNumber;
    revBlobs: openArray[seq[byte]];
    info: static[string];
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
