# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ../../../core/chain,
  ../../[sync_desc, wire_protocol],
  ./[helpers, worker_const]

export
  helpers, sync_desc, worker_const, chain

type
  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData,BeaconBuddyData]
    ## Extended global descriptor

  # -------------------

  BeaconErrorType* = enum
    ## For `FetchError` return code object/tuple
    ENoException = 0
    EPeerDisconnected                ## Exception
    ECatchableError                  ## Exception
    ECancelledError                  ## Exception

  BeaconError* = tuple
    ## Capture exception context for heders/bodies fetcher logging
    excp: BeaconErrorType
    name: string
    msg: string
    elapsed: Duration

  FetchHeadersData* = tuple
    packet: BlockHeadersPacket
    elapsed: Duration

  FetchBodiesData* = tuple
    packet: BlockBodiesPacket
    elapsed: Duration

  BackgroundTicker* =
    proc(ctx: BeaconCtxRef) {.gcsafe, raises: [].}
      ## Some function that is invoked regularly

  # -------------------

  BnRangeSet* = IntervalSetRef[BlockNumber,uint64]
    ## Disjunct sets of block number intervals

  BnRange* = Interval[BlockNumber,uint64]
    ## Single block number interval

  StagedHeaderQueue* = SortedSet[BlockNumber,LinkedHChain]
    ## Block intervals sorted by largest block number.

  LinkedHChain* = object
    ## Headers list item.
    ##
    ## The list `revHdrs[]` is reversed, i.e. the largest block number has
    ## the least index `0`. This makes it easier to grow the sequence with
    ## parent headers, i.e. decreasing block numbers.
    ##
    ## The headers list item indexed by the greatest block number (i.e. by
    ## `revHdrs[0]`.)
    ##
    revHdrs*: seq[Header]            ## Linked header chain, reversed
    peerID*: Hash                    ## For comparing peers

  StagedBlocksQueue* = SortedSet[BlockNumber,BlocksForImport]
    ## Blocks sorted by least block number.

  BlocksForImport* = object
    ## Blocks list item indexed by least block number (i.e. by `blocks[0]`.)
    blocks*: seq[EthBlock]           ## List of blocks lineage for import
    peerID*: Hash                    ## For comparing peers

  # -------------------

  SyncSubState* = object
    ## Bundelled state variables, easy to clear all with one `reset`.
    top*: BlockNumber                ## For locally syncronising block import
    head*: BlockNumber               ## Copy of `ctx.hdrCache.head()`
    headHash*: Hash32                ## Copy of `ctx.hdrCache.headHash()`
    cancelRequest*: bool             ## Cancel block sync via state machine
    procFailNum*: BlockNumber        ## Block (or header) error location
    procFailCount*: uint8            ## Number of failures at location

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

  StatsCollect* = object
    ## Statistics collector record
    sum*, sum2*: float
    samples*: uint
    total*: uint64

  BuddyThruPutStats* = object
    ## Throughput statistice for fetching headers and bodies. The fileds
    ## have the following meaning:
    ##    sum:      -- Sum of samples, throuhputs per sec
    ##    sum2:     -- Squares of samples, throuhputs per sec
    ##    samples:  -- Number of samples in sum/sum2
    ##    total:    -- Total number of bytes tranfered
    ##
    hdr*, blk*: StatsCollect

  BuddyErrors* = tuple
    ## Count fetching and processing errors
    fetch: tuple[
      hdr, bdy: uint8]
    apply: tuple[
      hdr, blk: uint8]

  BeaconBuddyData* = object
    ## Local descriptor data extension
    nErrors*: BuddyErrors            ## Error register
    thruPutStats*: BuddyThruPutStats ## Throughput statistics

  InitTarget* = tuple
    hash: Hash32                     ## Some block hash to sync towards to
    isFinal: bool                    ## The `hash` belongs to a finalised block

  BeaconCtxData* = object
    ## Globally shared data extension
    nBuddies*: int                   ## Number of active workers
    lastState*: SyncState            ## Last known layout state
    hdrSync*: HeaderFetchSync        ## Syncing by linked header chains
    blkSync*: BlocksFetchSync        ## For importing/executing blocks
    subState*: SyncSubState          ## Additional state variables
    nextMetricsUpdate*: Moment       ## For updating metrics
    nextAsyncNanoSleep*: Moment      ## Use nano-sleeps for task switch

    chain*: ForkedChainRef           ## Core database, FCU support
    hdrCache*: HeaderChainRef        ## Currently in tandem with `chain`

    # Info, debugging, and error handling stuff
    lastSlowPeer*: Opt[Hash]         ## Register slow peer when the last one
    failedPeers*: HashSet[Hash]      ## Detect dead end sync by collecting peers
    seenData*: bool                  ## Set `true` if data were fetched, already
    minInitBuddies*: int             ## Min # peers needed for acivating syncer
    initTarget*: Opt[InitTarget]     ## Optionally set up first target
    lastPeerSeen*: chronos.Moment    ## Time when the last peer was abandoned
    lastNoPeersLog*: chronos.Moment  ## Control messages about missing peers
    lastSyncUpdLog*: chronos.Moment  ## Control update messages
    ticker*: BackgroundTicker        ## Ticker function to run in background

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

func nErrors*(buddy: BeaconBuddyRef): var BuddyErrors =
  ## Shortcut
  buddy.only.nErrors

proc getPeer*(buddy: BeaconBuddyRef; peerID: Hash): BeaconBuddyRef =
  ## Getter, retrieve syncer peer (aka buddy) by `peerID` argument
  if buddy.peerID == peerID: buddy else: buddy.ctx.getPeer peerID

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

func toMeanVar*(w: StatsCollect): MeanVarStats =
  ## Calculate standard statistics.
  if 0 < w.samples:
    let
      samples = w.samples.float
      mean = w.sum / samples
      #            __________   ______   ______   |
      # Variance = sum(x * x) - sum(x) * sum(x)   | x = sample values
      #            ____
      #          = sum2 - mean * mean
      #
    result.mean = mean
    result.variance = w.sum2 / samples - mean * mean
    result.samples = w.samples
    result.total = w.total

func toMeanVar*(w: BuddyThruPutStats): MeanVarStats =
  ## Combined statistics for headers and bodies
  toMeanVar StatsCollect(
    sum:     w.hdr.sum +     w.blk.sum,
    sum2:    w.hdr.sum2 +    w.blk.sum2,
    samples: w.hdr.samples + w.blk.samples,
    total:   w.hdr.total +   w.blk.total)

proc bpsSample*(
    stats: var StatsCollect;
    elapsed: chronos.Duration;
    dataSize: int;
      ): uint =
  ## Helper for updating download statistics counters. It returns the current
  ## bytes/sec calculation.
  let ns = elapsed.nanoseconds
  if 0 < ns:
    let bps = dataSize.float * 1_000_000_000f / ns.float
    stats.sum += bps
    stats.sum2 +=  bps * bps
    stats.samples.inc
    stats.total += dataSize.uint64
    return bps.uint

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
