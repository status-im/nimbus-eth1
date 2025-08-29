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
  pkg/[chronicles, chronos, results],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../../networking/p2p,
  ./blocks/[blocks_blocks, blocks_helpers, blocks_queue, blocks_unproc],
  ./worker_desc

export
  blocks_queue, blocks_unproc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nUnprocStr(ctx: BeaconCtxRef): string =
  if ctx.blkSessionStopped() or ctx.blocksUnprocIsEmpty(): "n/a"
  else: $(ctx.hdrCache.head.number.uint64 - ctx.subState.top)

proc bnStrIfAvail(bn: BlockNumber; ctx: BeaconCtxRef): string =
  if ctx.blkSessionStopped(): "n/a" else: bn.bnStr

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func blocksCollectOk*(buddy: BeaconBuddyRef): bool =
  ## Check whether body records can be fetched and imported or stored
  ## on the `staged` queue.
  ##
  if buddy.ctrl.running:
    let ctx = buddy.ctx
    if 0 < ctx.blocksUnprocAvail() and
       not ctx.blkSessionStopped():
      return true
  false


template blocksCollect*(
    buddy: BeaconBuddyRef;
    info: static[string]) =
  ## Async/template
  ##
  ## Collect bodies and import or stage them.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  block body:
    if ctx.blocksUnprocIsEmpty():
      break body                                     # no action

    var
      importedOK = false                             # imported some blocks
      nImported {.inject.} = 0u64                    # statistics, to be updated
      nQueued {.inject.} = 0                         # ditto

    block fetchBlocksBody:
      #
      # Start deterministically. Explicitely fetch/append by parent hash.
      #
      # Exactly one peer can fetch and import store blocks directly on the `FC`
      # module. All other peers fetch and queue blocks for later serialisation.
      while true:
        let bottom = ctx.blocksUnprocAvailBottom() - 1
        #
        # A direct fetch and blocks import is possible if the next block to
        # fetch neigbours the already imported blocks ening at `lastImported`.
        # So this criteria is unique at a given time and when an interval is
        # taken out of the `unproc` pool:
        # ::
        #               |------------------    unproc pool
        #               |-------|              block interval to fetch next
        #    ----------|                       already imported into `FC` module
        #            bottom
        #         topImported
        #
        # After claiming the block interval that will be processed next for
        # the deterministic fetch, the situation for the new `bottom` would
        # look like:
        # ::
        #                        |---------    unproc pool
        #               |-------|              block interval to fetch next
        #    ----------|                       already imported into `FC` module
        #         topImported bottom
        #
        if ctx.subState.top < bottom:
          break

        # Throw away overlap (should not happen anyway)
        if bottom < ctx.subState.top:
          discard ctx.blocksUnprocFetch(ctx.subState.top - bottom).expect("iv")

        # Fetch blocks and verify result
        let blocks = buddy.blocksFetch(nFetchBodiesRequest, info).valueOr:
          break fetchBlocksBody                      # done, exit this function

        # Set flag that there were some blocks fetched at all
        ctx.pool.seenData = true                     # blocks data exist

        # Import blocks (no staging), async/template
        nImported += buddy.blocksImport(blocks, buddy.peerID, info)

        # Sync status logging
        if 0 < nImported:
          importedOK = true
          if ctx.pool.lastSyncUpdLog + syncUpdateLogWaitInterval < Moment.now():
            chronicles.info "Imported blocks", nImported,
              nUnproc=ctx.nUnprocStr(),
              nStagedQ=ctx.blk.staged.len,
              base=ctx.chain.baseNumber.bnStr,
              head=ctx.chain.latestNumber.bnStr,
              target=ctx.subState.head.bnStr,
              targetHash=ctx.subState.headHash.short,
              nSyncPeers=ctx.pool.nBuddies
            ctx.pool.lastSyncUpdLog = Moment.now()
            nImported = 0

        # Import may be incomplete, so a partial roll back may be needed
        let lastBn = blocks[^1].header.number
        if ctx.subState.top < lastBn:
          ctx.blocksUnprocAppend(ctx.subState.top + 1, lastBn)

        # Buddy might have been cancelled while importing blocks.
        if buddy.ctrl.stopped or ctx.poolMode:
          break fetchBlocksBody                      # done, exit this block

        # End while: headersUnprocFetch() + blocksImport()

      # Continue fetching blocks and stage/queue them (if any)
      if ctx.blk.staged.len+ctx.blk.reserveStaged < blocksStagedQueueLengthMax:

        # Fetch blocks and verify result
        ctx.blk.reserveStaged.inc                   # Book a slot on `staged`
        let rc = buddy.blocksFetch(nFetchBodiesRequest, info)
        ctx.blk.reserveStaged.dec                   # Free that slot again

        if rc.isErr:
          break fetchBlocksBody                     # done, exit this block

        let
          # Insert blocks list on the `staged` queue
          key = rc.value[0].header.number
          qItem = ctx.blk.staged.insert(key).valueOr:
            raiseAssert info & ": duplicate key on staged queue iv=" &
              (key, rc.value[^1].header.number).bnStr

        qItem.data.blocks = rc.value                # store `blocks[]` list
        qItem.data.peerID = buddy.peerID

        ctx.blocksStagedQueueMetricsUpdate()        # metrics
        nQueued += rc.value.len                     # statistics
        # End if

      # End block: `fetchBlocksBody`

    if importedOK:
      # Sync status logging.
      if 0 < nImported:
        # Note that `nImported` might have been reset above.
        chronicles.info "Imported blocks", nImported,
          nUnproc=ctx.nUnprocStr(),
          nStagedQ=ctx.blk.staged.len,
          base=ctx.chain.baseNumber.bnStr,
          head=ctx.chain.latestNumber.bnStr,
          target=ctx.subState.head.bnStr,
          targetHash=ctx.subState.headHash.short,
          nSyncPeers=ctx.pool.nBuddies
        ctx.pool.lastSyncUpdLog = Moment.now()

    elif nQueued == 0 and
         not ctx.pool.seenData and
         buddy.peerID notin ctx.pool.failedPeers and
         buddy.ctrl.stopped:
      # Collect peer for detecting cul-de-sac syncing (i.e. non-existing
      # block chain or similar.)
      ctx.pool.failedPeers.incl buddy.peerID

      debug info & ": no blocks yet (failed peer)", peer,
        failedPeers=ctx.pool.failedPeers.len,
        syncState=($buddy.syncState), bdyErrors=buddy.bdyErrors
      break body                                    # return

    # This message might run in addition to the `chronicles.info` part
    trace info & ": queued/staged or imported blocks",
      topImported=ctx.subState.top.bnStr,
      unprocBottom=ctx.blocksUnprocAvailBottom.bnStrIfAvail(ctx),
      nQueued, nImported, nStagedQ=ctx.blk.staged.len,
      nSyncPeers=ctx.pool.nBuddies

  discard

# --------------

proc blocksUnstageOk*(ctx: BeaconCtxRef): bool =
  ## Check whether import processing is possible
  ##
  not ctx.poolMode and
  0 < ctx.blk.staged.len


template blocksUnstage*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): bool =
  ## Async/template
  ##
  ## Import/execute blocks record from staged queue.
  ##
  ## The template returns `false` if the caller should make sure to allow
  ## to switch to another sync peer, e.g. for directly filling the gap
  ## between the top of the `topImported` and the least queue block number.
  ##
  var bodyRc = false
  block body:
    let ctx = buddy.ctx
    if ctx.blk.staged.len == 0:
      break body                                   # return false => switch peer

    var
      peer {.inject.} = buddy.peer
      nImported {.inject.} = 0u64                  # statistics
      importedOK = false                           # imported some blocks
      switchPeer {.inject.} = false                # for return code

    while ctx.pool.lastState == SyncState.blocks:

      # Fetch list with the least block numbers
      let qItem = ctx.blk.staged.ge(0).valueOr:
        break                                      # all done

      # Make sure that the lowest block is available, already. Or the other
      # way round: no unprocessed block number range precedes the least staged
      # block.
      let minNum = qItem.data.blocks[0].header.number
      if ctx.subState.top + 1 < minNum:
        trace info & ": block queue not ready yet", peer,
          topImported=ctx.subState.top.bnStr, qItem=qItem.data.blocks.bnStr,
          nStagedQ=ctx.blk.staged.len, nSyncPeers=ctx.pool.nBuddies
        switchPeer = true # there is a gap -- come back later
        break

      # Remove from queue
      discard ctx.blk.staged.delete qItem.key
      ctx.blocksStagedQueueMetricsUpdate()         # metrics

      # Import blocks list, async/template
      nImported += buddy.blocksImport(qItem.data.blocks,qItem.data.peerID, info)

      # Sync status logging
      if 0 < nImported:
        importedOK = true
        if ctx.pool.lastSyncUpdLog + syncUpdateLogWaitInterval < Moment.now():
          chronicles.info "Imported blocks", nImported,
            nUnproc=ctx.nUnprocStr(),
            nStagedQ=ctx.blk.staged.len,
            base=ctx.chain.baseNumber.bnStr,
            head=ctx.chain.latestNumber.bnStr,
            target=ctx.subState.head.bnStr,
            targetHash=ctx.subState.headHash.short,
            nSyncPeers=ctx.pool.nBuddies
          ctx.pool.lastSyncUpdLog = Moment.now()
          nImported = 0

      # Import probably incomplete, so a partial roll back may be needed
      let lastBn = qItem.data.blocks[^1].header.number
      if ctx.subState.top < lastBn:
        ctx.blocksUnprocAppend(ctx.subState.top + 1, lastBn)

      # End while loop

    if importedOK:
      # Sync status logging
      if 0 < nImported:
        # Note that `nImported` might have been reset above.
        chronicles.info "Imported blocks", nImported,
          nUnproc=ctx.nUnprocStr(),
          nStagedQ=ctx.blk.staged.len,
          base=ctx.chain.baseNumber.bnStr,
          head=ctx.chain.latestNumber.bnStr,
          target=ctx.subState.head.bnStr,
          targetHash=ctx.subState.headHash.short,
          nSyncPeers=ctx.pool.nBuddies
        ctx.pool.lastSyncUpdLog = Moment.now()

    elif switchPeer or 0 < ctx.blk.staged.len:
      trace info & ": no blocks unqueued", peer,
        topImported=ctx.subState.top.bnStr, nStagedQ=ctx.blk.staged.len,
        nSyncPeers=ctx.pool.nBuddies, switchPeer

    bodyRc = not switchPeer

  bodyRc # return

# --------------

proc blocksStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention.
  ##
  if ctx.pool.lastState in {blocksCancel,blocksFinish}:
    trace info & ": Flushing block queues",
      nUnproc=ctx.blocksUnprocTotal(), nStagedQ=ctx.blk.staged.len

    ctx.blocksUnprocClear()
    ctx.blk.staged.clear()
    ctx.subState.reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
