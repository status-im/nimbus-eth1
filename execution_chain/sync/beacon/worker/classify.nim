# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  ./[blocks, headers, worker_desc]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func somethingToCollectOrUnstage*(buddy: BeaconBuddyRef): bool =
  if buddy.ctx.hibernate:                        # not activated yet?
    return false
  if buddy.headersCollectOk() or                 # something on TODO list
     buddy.headersUnstageOk() or
     buddy.blocksCollectOk() or
     buddy.blocksUnstageOk():
    return true
  false


func classifyForFetching*(buddy: BeaconBuddyRef): PeerRanking =
  ## Rank and classify peers by whether they should be used for fetching
  ## data.
  ##
  ## If data are available, the peers are ranked by its througput. Then the
  ## highest ranking peers are selected for filling the slots given by the
  ## queue lengths for downloading simultaneously.
  ##
  var ranking = 0

  case buddy.ctx.pool.syncState:
  of SyncState.headers:
    # Classify this peer only if there are enough header slots available on
    # the queue for dowmloading simmultaneously. There is an additional slot
    # for downlading directly to the header chain cache (rather than queuing.)
    if buddy.ctx.nSyncPeers() <= headersStagedQueueLengthMax + 1:
      return (qSlotsAvail, -1)

    template hdr(b: BeaconBuddyRef): StatsCollect =
      b.only.thPutStats.hdr

    # Are there throughput data available for this peer (aka buddy), at all?
    if buddy.hdr.samples == 0:
      return (notEnoughData, -1)

    # Only reply rejections with this peer?
    if buddy.hdr.sum == 0f:
      return (rankingTooLow, 0)

    # Get number of peers with poorer header throughput. This results in a
    # ranking of the sync peers where a high rank is preferable.
    let (bSum, bSamples) = (buddy.hdr.sum, buddy.hdr.samples.float)
    for w in buddy.ctx.getSyncPeers():
      if buddy.peerID != w.peerID and
         # Mind fringe case when most higher throughputs are equal in which
         # case all ranks must be the topmost rank (i.e. `<=`, here.)
         w.hdr.sum * bSamples <= bSum * w.hdr.samples.float:
        ranking.inc

    # Test against better performing peers. Choose those if there are enough.
    if ranking < buddy.ctx.nSyncPeers() - headersStagedQueueLengthMax:
      return (rankingTooLow, ranking)

  of SyncState.blocks:
    # Ditto for block bodies
    if buddy.ctx.nSyncPeers() <= blocksStagedQueueLengthMax + 1:
      return (qSlotsAvail, -1)

    template blk(b: BeaconBuddyRef): StatsCollect =
      b.only.thPutStats.blk

    if buddy.blk.samples == 0:
      return (notEnoughData, -1)
    if buddy.blk.sum == 0f:
      return (rankingTooLow, 0)

    let (bSum, bSamples) = (buddy.blk.sum, buddy.blk.samples.float)
    for w in buddy.ctx.getSyncPeers():
      if buddy.peerID != w.peerID and
         w.blk.sum * bSamples <= bSum * w.blk.samples.float:
        ranking.inc

    if ranking < buddy.ctx.nSyncPeers() - blocksStagedQueueLengthMax:
      return (rankingTooLow, ranking)

  else:
    # Nothing to do here
    return (notApplicable, -1)

  (rankingOk, ranking)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
