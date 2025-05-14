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
  ./worker_config

export
  helpers, sync_desc, worker_config, chain

type
  BnRangeSet* = IntervalSetRef[BlockNumber,uint64]
    ## Disjunct sets of block number intervals

  BnRange* = Interval[BlockNumber,uint64]
    ## Single block number interval

  LinkedHChainQueue* = SortedSet[BlockNumber,LinkedHChain]
    ## Block intervals sorted by largest block number.

  LinkedHChain* = object
    ## Public block items for the `LinkedHChainQueue` list, indexed by the
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

  SyncLayoutState* = enum
    idleSyncState = 0                ## see clause *(8)*, *(12)* of `README.md`
    collectingHeaders                ## see clauses *(5)*, *(9)* of `README.md`
    cancelHeaders                    ## stop this scrum
    finishedHeaders                  ## see clause *(10)* of `README.md`
    processingBlocks                 ## see clause *(11)* of `README.md`
    cancelBlocks                     ## stop this scrum

  SyncClMesg* = object
    ## Beacon state message used for manual first target set up
    consHead*: Header                ## Consensus head
    finalHash*: Hash32               ## Finalised hash

  # -------------------

  HeaderFetchSync* = object
    ## Header sync staging area
    unprocessed*: BnRangeSet         ## Block or header ranges to fetch
    borrowed*: BnRangeSet            ## Fetched/locked ranges
    staged*: LinkedHChainQueue       ## Blocks fetched but not stored yet
    reserveStaged*: int              ## Pre-book staged slot temporarily

  BlocksFetchSync* = object
    ## Block sync staging area
    unprocessed*: BnRangeSet         ## Blocks download requested
    borrowed*: BnRangeSet            ## Fetched/locked fetched ranges
    staged*: StagedBlocksQueue       ## Blocks ready for import
    topImported*: BlockNumber        ## For syncronising opportunistic import

  # -------------------

  BeaconBuddyData* = object
    ## Local descriptor data extension
    nHdrRespErrors*: uint8           ## Number of errors/slow responses in a row
    nBdyRespErrors*: uint8           ## Ditto for bodies
    nBdyProcErrors*: uint8           ## Number of body post processing errors

    # Debugging and logging.
    nMultiLoop*: int                 ## Number of runs
    stoppedMultiRun*: chronos.Moment ## Time when run-multi stopped
    multiRunIdle*: chronos.Duration  ## Idle time between runs

  BeaconCtxData* = object
    ## Globally shared data extension
    nBuddies*: int                   ## Number of active workers
    clReq*: SyncClMesg               ## Manual first target set up
    lastState*: SyncLayoutState      ## Last known layout state
    hdrSync*: HeaderFetchSync        ## Syncing by linked header chains
    blkSync*: BlocksFetchSync        ## For importing/executing blocks
    nextMetricsUpdate*: Moment       ## For updating metrics
    nextAsyncNanoSleep*: Moment      ## Use nano-sleeps for task switch

    chain*: ForkedChainRef           ## Core database, FCU support
    hdrCache*: HeaderChainRef        ## Currently in tandem with `chain`

    # Info, debugging, and error handling stuff
    nReorg*: int                     ## Number of reorg invocations (info only)
    hdrProcError*: Table[Hash,uint8] ## Some globally accessible header errors
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

func hdrCache*(ctx: BeaconCtxRef): HeaderChainRef =
  ## Shortcut
  ctx.pool.hdrCache

func head*(ctx: BeaconCtxRef): Header =
  ## Shortcut
  ctx.hdrCache.head()

func headHash*(ctx: BeaconCtxRef): Hash32 =
  ## Shortcut
  ctx.hdrCache.headHash()

func dangling*(ctx: BeaconCtxRef): Header =
  ## Shortcut
  ctx.hdrCache.antecedent()

func consHeadNumber*(ctx: BeaconCtxRef): BlockNumber =
  ## Shortcut
  ctx.hdrCache.latestConsHeadNumber()

# ------------

func hdr*(ctx: BeaconCtxRef): var HeaderFetchSync =
  ## Shortcut
  ctx.pool.hdrSync

func blk*(ctx: BeaconCtxRef): var BlocksFetchSync =
  ## Shortcut
  ctx.pool.blkSync

func clReq*(ctx: BeaconCtxRef): var SyncClMesg =
  ## Shortcut
  ctx.pool.clReq

func chain*(ctx: BeaconCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.chain

func db*(ctx: BeaconCtxRef): CoreDbRef =
  ## Getter
  ctx.pool.chain.db

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

proc nHdrRespErrors*(buddy: BeaconBuddyRef): int =
  ## Getter, returns the number of `resp` errors for argument `buddy`
  buddy.only.nHdrRespErrors.int

proc `nHdrRespErrors=`*(buddy: BeaconBuddyRef; count: uint8) =
  ## Setter, set arbitrary `resp` error count for argument `buddy`.
  buddy.only.nHdrRespErrors = count

proc incHdrRespErrors*(buddy: BeaconBuddyRef) =
  ## Increment `resp` error count for for argument `buddy`.
  buddy.only.nHdrRespErrors.inc


proc initHdrProcErrors*(buddy: BeaconBuddyRef) =
  ## Create error slot for argument `buddy`
  buddy.ctx.pool.hdrProcError[buddy.peerID] = 0u8

proc clearHdrProcErrors*(buddy: BeaconBuddyRef) =
  ## Delete error slot for argument `buddy`
  buddy.ctx.pool.hdrProcError.del buddy.peerID
  doAssert buddy.ctx.pool.hdrProcError.len <= buddy.ctx.pool.nBuddies

proc nHdrProcErrors*(buddy: BeaconBuddyRef): int =
  ## Getter, returns the number of `proc` errors for argument `buddy`
  buddy.ctx.pool.hdrProcError.withValue(buddy.peerID, val):
    return val[].int

proc `nHdrProcErrors=`*(buddy: BeaconBuddyRef; count: uint8) =
  ## Setter, set arbitrary `proc` error count for argument `buddy`. Due
  ## to (hypothetical) hash collisions, the error register might have
  ## vanished in case a new one is instantiated.
  buddy.ctx.pool.hdrProcError.withValue(buddy.peerID, val):
    val[] = count
  do:
    buddy.ctx.pool.hdrProcError[buddy.peerID] = count

proc incHdrProcErrors*(buddy: BeaconBuddyRef) =
  ## Increment `proc` error count for for argument `buddy`. Due to
  ## (hypothetical) hash collisions, the error register might have
  ## vanished in case a new one is instantiated.
  buddy.ctx.pool.hdrProcError.withValue(buddy.peerID, val):
    val[].inc
  do:
    buddy.ctx.pool.hdrProcError[buddy.peerID] = 1u8

proc incHdrProcErrors*(buddy: BeaconBuddyRef; peerID: Hash) =
  ## Increment `proc` error count for for argument `peerID` entry if it
  ## has a slot. Otherwise the instruction is ignored.
  buddy.ctx.pool.hdrProcError.withValue(peerID, val):
    val[].inc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
