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
  pkg/stew/[interval_set, sorted_set],
  pkg/results,
  "../../.."/[common, core/chain, db/storage_types],
  ../worker_desc,
  "."/[blocks_unproc, headers_unproc]

const
  LhcStateKey = 1.beaconStateKey

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


proc deleteStaleHeadersAndState(
    ctx: BeaconCtxRef;
    upTo: BlockNumber;
    info: static[string];
      ) =
  ## Delete stale headers and state
  let
    kvt = ctx.db.ctx.getKvt()
    stateNum = ctx.db.getSavedStateBlockNumber() # for persisting

  var bn = upTo
  while 0 < bn and kvt.hasKey(beaconHeaderKey(bn).toOpenArray):
    discard kvt.del(beaconHeaderKey(bn).toOpenArray)
    bn.dec

    # Occasionallly persist the deleted headers. This will succeed if
    # this function is called early enough after restart when there is
    # no database transaction pending.
    if (upTo - bn) mod 8192 == 0:
      ctx.db.persistent(stateNum).isOkOr:
        debug info & ": cannot persist deleted sync headers", error=($$error)
        # So be it, stop here.
        return

  # Delete persistent state, there will be no use of it anymore
  discard kvt.del(LhcStateKey.toOpenArray)
  ctx.db.persistent(stateNum).isOkOr:
    debug info & ": cannot persist deleted sync headers", error=($$error)
    return

  if bn < upTo:
    debug info & ": deleted stale sync headers", iv=BnRange.new(bn+1,upTo)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbStoreSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]) =
  ## Save chain layout to persistent db
  let data = rlp.encode(ctx.layout)
  ctx.db.ctx.getKvt().put(LhcStateKey.toOpenArray, data).isOkOr:
    raiseAssert info & " put() failed: " & $$error

  # While executing blocks there are frequent save cycles. Otherwise, an
  # extra save request might help to pick up an interrupted sync session.
  if ctx.db.level() == 0 and ctx.stash.len == 0:
    let number = ctx.db.getSavedStateBlockNumber()
    ctx.db.persistent(number).isOkOr:
      raiseAssert info & " persistent() failed: " & $$error


proc dbLoadSyncStateLayout*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Restore chain layout from persistent db. It returns `true` if a previous
  ## state could be loaded, and `false` if a new state was created.
  let
    rc = ctx.fetchSyncStateLayout()
    latest = ctx.chain.latestNumber()

  # If there was a manual import after a previous sync, then saved state
  # might be outdated.
  if rc.isOk and
     # The base number is the least record of the FCU chains/tree. So the
     # finalised entry must not be smaller.
     ctx.chain.baseNumber() <= rc.value.final and

     # If the latest FCU number is not larger than the head, there is nothing
     # to do (might also happen after a manual import.)
     latest < rc.value.head:

    # Assign saved sync state
    ctx.sst.layout = rc.value

    # Add interval of unprocessed block range `(L,C]` from `README.md`
    ctx.blocksUnprocSet(latest+1, ctx.layout.coupler)
    ctx.blk.topRequest = ctx.layout.coupler

    # Add interval of unprocessed header range `(C,D)` from `README.md`
    ctx.headersUnprocSet(ctx.layout.coupler+1, ctx.layout.dangling-1)

    trace info & ": restored sync state", L=latest.bnStr,
      C=ctx.layout.coupler.bnStr, D=ctx.layout.dangling.bnStr,
      F=ctx.layout.final.bnStr, H=ctx.layout.head.bnStr

    true

  else:
    let
      latestHash = ctx.chain.latestHash()
      latestParent = ctx.chain.latestHeader.parentHash

    ctx.sst.layout = SyncStateLayout(
      coupler:        latest,
      dangling:       latest,
      # There is no need to record a separate finalised head `F` as its only
      # use is to serve as second argument in `forkChoice()` when committing
      # a batch of imported blocks. Currently, there are no blocks to fetch
      # and import. The system must wait for instructions and update the fields
      # `final` and `head` while the latter will be increased so that import
      # can start.
      final:          latest,
      finalHash:      latestHash,
      head:           latest,
      headLocked:     false)

    if rc.isOk:
      # Some stored headers might have become stale, so delete them. Even
      # though it is not critical, stale headers just stay on the database
      # forever occupying space without purpose. Also, delete the state record.
      # After deleting headers, the state record becomes stale as well.
      if rc.value.head <= latest:
        # After manual import, the `latest` state might be ahead of the old
        # `head` which leaves a gap `(rc.value.head,latest)` of missing headers.
        # So the `deleteStaleHeadersAndState()` clean up routine needs to start
        # at the `head` and work backwards.
        ctx.deleteStaleHeadersAndState(rc.value.head, info)
      else:
        # Delete stale headers with block numbers starting at to `latest` while
        # working backwards.
        ctx.deleteStaleHeadersAndState(latest, info)

    false

# ------------------

proc dbHeadersClear*(ctx: BeaconCtxRef) =
  ## Clear stashed in-memory headers
  ctx.stash.clear

proc dbHeadersStash*(
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
    txLevel = ctx.db.level()
    last = first + revBlobs.len.uint64 - 1
  if 0 < txLevel:
    # Need to cache it because FCU has blocked writing through to disk.
    for n,data in revBlobs:
      ctx.stash[last - n.uint64] = data
  else:
    let kvt = ctx.db.ctx.getKvt()
    for n,data in revBlobs:
      let key = beaconHeaderKey(last - n.uint64)
      kvt.put(key.toOpenArray, data).isOkOr:
        raiseAssert info & ": put() failed: " & $$error

proc dbHeaderPeek*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  # Try cache first
  ctx.stash.withValue(num, val):
    try:
      return ok(rlp.decode(val[], Header))
    except RlpError:
      discard
  # Use persistent storage next
  let
    key = beaconHeaderKey(num)
    rc = ctx.db.ctx.getKvt().get(key.toOpenArray)
  if rc.isOk:
    try:
      return ok(rlp.decode(rc.value, Header))
    except RlpError:
      discard
  err()

proc dbHeaderParentHash*(ctx: BeaconCtxRef; num: BlockNumber): Opt[Hash32] =
  ## Retrieve some stashed parent hash.
  ok (? ctx.dbHeaderPeek num).parentHash

proc dbHeaderUnstash*(ctx: BeaconCtxRef; bn: BlockNumber) =
  ## Remove header from temporary DB list
  ctx.stash.withValue(bn, _):
    ctx.stash.del bn
    return
  discard ctx.db.ctx.getKvt().del(beaconHeaderKey(bn).toOpenArray)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
