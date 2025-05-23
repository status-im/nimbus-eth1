# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/sets,
  pkg/[chronos, eth/common, results],
  pkg/stew/[interval_set, sorted_set],
  ../../core/chain,
  ../sync_desc,
  ./worker/helpers,
  ./worker_const

export
  helpers, sync_desc, worker_const, chain

type
  BnRangeSet* = IntervalSetRef[BlockNumber,uint64]
    ## Disjunct sets of block number intervals

  BnRange* = Interval[BlockNumber,uint64]
    ## Single block number interval

  StagedHeaderQueue* = SortedSet[BlockNumber,LinkedHChain]
    ## Block intervals sorted by largest block number.

  LinkedHChain* = object
    ## Public block items for the `StagedHeaderQueue` list, indexed by the
    ## largest block number. The list `revHdrs[]` is reversed, i.e. the largest
    ## block number has the least index `0`. This makes it easier to grow the
    ## sequence with parent headers, i.e. decreasing block numbers.
    ##
    hash*: Hash32                    ## Hash of `headers[0]`
    revHdrs*: seq[Header]            ## Linked header chain, reversed
    peerID*: Hash                    ## For comparing peers

  StagedBlocksQueue* = SortedSet[BlockNumber,BlocksForImport]
    ## Blocks sorted by least block number.

  BlocksForImport* = object
    ## Block request item sorted by least block number (i.e. from `blocks[0]`.)
    blocks*: seq[EthBlock]           ## List of blocks for import

  # -------------------

  SyncClMesg* = object
    ## Beacon state message used for manual first target set up
    consHead*: Header                ## Consensus head
    finalHash*: Hash32               ## Finalised hash

  # -------------------

  SyncSubState* = object
    ## Bundelled state variables, easy to clear all with one `reset`.
    top*: BlockNumber                ## For locally syncronising block import
    head*: BlockNumber               ## Copy of `ctx.hdrCache.head()`
    headHash*: Hash32                ## Copy of `ctx.hdrCache.headHash()`
    cancelRequest*: bool             ## Cancel block sync via state machine

  HeaderFetchSync* = object
    ## Header sync staging area
    unprocessed*: BnRangeSet         ## Block or header ranges to fetch
    borrowed*: BnRangeSet            ## Fetched/locked ranges
    staged*: StagedHeaderQueue       ## Blocks fetched but not stored yet
    reserveStaged*: int              ## Pre-book staged slot temporarily

  BlocksFetchSync* = object
    ## Block sync staging area
    unprocessed*: BnRangeSet         ## Blocks download requested
    borrowed*: BnRangeSet            ## Fetched/locked fetched ranges
    staged*: StagedBlocksQueue       ## Blocks ready for import
    reserveStaged*: int              ## Pre-book staged slot temporarily

  # -------------------

  BuddyError* = tuple
    ## Count fetching or processing errors
    hdr, blk: uint8

  BeaconBuddyData* = object
    ## Local descriptor data extension
    nRespErrors*: BuddyError         ## Number of errors/slow responses in a row

    # Debugging and logging.
    nMultiLoop*: int                 ## Number of runs
    stoppedMultiRun*: chronos.Moment ## Time when run-multi stopped
    multiRunIdle*: chronos.Duration  ## Idle time between runs

  BeaconCtxData* = object
    ## Globally shared data extension
    nBuddies*: int                   ## Number of active workers
    clReq*: SyncClMesg               ## Manual first target set up
    lastState*: SyncState            ## Last known layout state
    hdrSync*: HeaderFetchSync        ## Syncing by linked header chains
    blkSync*: BlocksFetchSync        ## For importing/executing blocks
    subState*: SyncSubState          ## Additional state variables
    nextMetricsUpdate*: Moment       ## For updating metrics
    nextAsyncNanoSleep*: Moment      ## Use nano-sleeps for task switch

    chain*: ForkedChainRef           ## Core database, FCU support
    hdrCache*: HeaderChainRef        ## Currently in tandem with `chain`

    # Info, debugging, and error handling stuff
    nProcError*: Table[Hash,BuddyError] ## Per peer processing error
    blkLastSlowPeer*: Opt[Hash]      ## Register slow peer when last one
    failedPeers*: HashSet[Hash]      ## Detect dead end sync by collecting peers
    seenData*: bool                  ## Set `true` is data were fetched, already

    # Debugging stuff
    when enableTicker:
      ticker*: RootRef               ## Logger ticker

  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func hdr*(ctx: BeaconCtxRef): var HeaderFetchSync =
  ## Shortcut
  ctx.pool.hdrSync

func blk*(ctx: BeaconCtxRef): var BlocksFetchSync =
  ## Shortcut
  ctx.pool.blkSync

func subState*(ctx: BeaconCtxRef): var SyncSubState =
  ## Shortcut
  ctx.pool.subState

func chain*(ctx: BeaconCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.chain

func hdrCache*(ctx: BeaconCtxRef): HeaderChainRef =
  ## Shortcut
  ctx.pool.hdrCache

# -----

func hibernate*(ctx: BeaconCtxRef): bool =
  ## Getter, re-interpretation of the daemon flag for reduced service mode
  # No need for running the daemon with reduced service mode. So it is
  # convenient to use this flag for indicating this.
  not ctx.daemon

proc `hibernate=`*(ctx: BeaconCtxRef; val: bool) =
  ## Setter
  ctx.daemon = not val

  # Control some error messages on the scheduler (e.g. zombie/banned-peer
  # reconnection attempts, LRU flushing out oldest peer etc.)
  ctx.noisyLog = not val

# -----

func syncState*(
    ctx: BeaconCtxRef;
      ): (SyncState,HeaderChainMode,bool) =
  ## Getter, triple of relevant run-time states
  (ctx.pool.lastState,
   ctx.hdrCache.state,
   ctx.poolMode)

func syncState*(
    buddy: BeaconBuddyRef;
      ): (BuddyRunState,SyncState,HeaderChainMode,bool) =
  ## Getter, also includes buddy state
  (buddy.ctrl.state,
   buddy.ctx.pool.lastState,
   buddy.ctx.hdrCache.state,
   buddy.ctx.poolMode)

# -----

proc initProcErrors*(buddy: BeaconBuddyRef) =
  ## Create error slot for argument `buddy`
  buddy.ctx.pool.nProcError[buddy.peerID] = (0u8,0u8)

proc clearProcErrors*(buddy: BeaconBuddyRef) =
  ## Delete error slot for argument `buddy`
  buddy.ctx.pool.nProcError.del buddy.peerID
  doAssert buddy.ctx.pool.nProcError.len <= buddy.ctx.pool.nBuddies

# -----

proc nHdrProcErrors*(buddy: BeaconBuddyRef): int =
  ## Getter, returns the number of `proc` errors for argument `buddy`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    return val.hdr.int

proc `nHdrProcErrors=`*(buddy: BeaconBuddyRef; count: uint8) =
  ## Setter, set arbitrary `proc` error count for argument `buddy`. Due
  ## to (hypothetical) hash collisions, the error register might have
  ## vanished in case a new one is instantiated.
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.hdr = count
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (count,0u8)

proc incHdrProcErrors*(buddy: BeaconBuddyRef) =
  ## Increment `proc` error count for for argument `buddy`. Due to
  ## (hypothetical) hash collisions, the error register might have
  ## vanished in case a new one is instantiated.
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.hdr.inc
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (1u8,0u8)

proc incHdrProcErrors*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Increment `proc` error count for for argument `peerID` entry if it
  ## has a slot. Otherwise the instruction is ignored.
  ctx.pool.nProcError.withValue(peerID, val):
    val.hdr.inc

# -----

proc nBlkProcErrors*(buddy: BeaconBuddyRef): int =
  ## Getter, similar to `nHdrProcErrors()`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    return val.blk.int

proc `nBlkProcErrors=`*(buddy: BeaconBuddyRef; count: uint8) =
  ## Setter, simolar to `nHdrProcErrors()`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.blk = count
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (0u8,count)

proc incBlkProcErrors*(buddy: BeaconBuddyRef) =
  ## Increment `proc` error count, similar to `incHdrProcErrors()`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.blk.inc
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (0u8,1u8)

proc incBlkProcErrors*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Increment `proc` error count, similar to `incHdrProcErrors()`
  ctx.pool.nProcError.withValue(peerID, val):
    val.blk.inc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
