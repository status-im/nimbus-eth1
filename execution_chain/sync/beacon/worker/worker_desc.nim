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
  std/[sets, sequtils],
  pkg/[chronos, eth/common, results],
  pkg/stew/[interval_set, sorted_set],
  ../../../core/chain,
  ../../[sync_desc, wire_protocol],
  ./[helpers, worker_const]

export
  sync_desc, worker_const, chain

type
  BeaconPeerRef* = SyncPeerRef[BeaconCtxData,BeaconPeerData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData,BeaconPeerData]
    ## Extended global descriptor

  # -------------------

  BeaconError* = tuple
    ## Capture exception context for heders/bodies fetcher logging
    excp: ErrorType
    name: string
    msg: string
    elapsed: Duration

  FetchHeadersData* = tuple
    packet: BlockHeadersPacket
    elapsed: Duration

  FetchBodiesData* = tuple
    packet: BlockBodiesPacket
    elapsed: Duration

  PeerRanking* = tuple
    assessed: PerfClass
    ranking: int

  Ticker* =
    proc(ctx: BeaconCtxRef) {.gcsafe, raises: [].}
      ## Some function that is invoked regularly

  # -------------------

  BnRangeSet* = IntervalSetRef[BlockNumber,uint64]
    ## Disjunct sets of block number intervals

  BnRange* = Interval[BlockNumber,uint64]
    ## Single block number interval

  StagedHeaderQueue* = SortedSet[BlockNumber,HeaderChain]
    ## Block intervals sorted by largest block number.

  HeaderChain* = object
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
    topNum*: BlockNumber             ## For locally syncronising block import
    headNum*: BlockNumber            ## Copy of `ctx.hdrCache.head().number`
    headHash*: Hash32                ## Copy of `ctx.hdrCache.headHash()`
    stateSince*: chronos.Moment      ## Time of last sync state change
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

  ThPutStats* = object
    ## Throughput statistice for fetching headers and bodies. The fileds
    ## have the following meaning:
    ##    sum:      -- Sum of samples, throuhputs per sec
    ##    sum2:     -- Squares of samples, throuhputs per sec
    ##    samples:  -- Number of samples in sum/sum2
    ##    total:    -- Total number of bytes tranfered
    ##
    hdr*, blk*: StatsCollect

  PeerErrors* = tuple
    ## Count fetching and processing errors
    fetch: tuple[
      hdr, bdy: uint8]
    apply: tuple[
      hdr, blk: uint8]

  PeerFirstFetchReq* = object
    ## Register fetch request. This is intended to avoid sending the same (or
    ## similar) fetch request again from the same peer that sent it previously.
    case state*: SyncState
    of SyncState.headers:
      blockNumber*: BlockNumber      ## First block number
    of SyncState.blocks:
      blockHash*: Hash32             ## First block hash
    else:
      discard

  BeaconPeerData* = object
    ## Local descriptor data extension
    nErrors*: PeerErrors             ## Error register
    thPutStats*: ThPutStats          ## Throughput statistics
    failedReq*: PeerFirstFetchReq    ## Avoid sending the same request twice

  InitTarget* = tuple
    hash: Hash32                     ## Some block hash to sync towards to
    isFinal: bool                    ## The `hash` belongs to a finalised block

  SyncEta* = tuple
    ## Eta calculator. The latest values of `headerTime` and `blockTime` are
    ## not supposed to be reset and used for interpolating `eta`.
    headerTime: float                ## Nanosecs per header (inverse velocity)
    blockTime: float                 ## Nanosecs per block (inverse velocity)
    lastUpdate: chronos.Moment       ## Needed to keep samples apart, timewise
    inSync: bool                     ## Change `avg` & `latest` display
    etaInx: int                      ## Round robin index for `eta[]`
    etaRr: array[etaAvgPoints,float] ## Estimated ETA sample points

  BeaconCtxData* = object
    ## Globally shared data extension
    hdrSync*: HeaderFetchSync        ## Syncing by linked header chains
    blkSync*: BlocksFetchSync        ## For importing/executing blocks
    syncState*: SyncState            ## Last known layout state
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
    syncEta*: SyncEta                ## Estimated time until all in sync
    ticker*: Ticker                  ## Ticker function to run in background

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

func nErrors*(buddy: BeaconPeerRef): var PeerErrors =
  ## Shortcut
  buddy.only.nErrors

proc getSyncPeer*(buddy: BeaconPeerRef; peerID: Hash): BeaconPeerRef =
  ## Getter, retrieve syncer peer (aka buddy) by `peerID` argument
  if buddy.peerID == peerID: buddy else: buddy.ctx.getSyncPeer peerID

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
  (ctx.pool.syncState,
   ctx.hdrCache.state,
   ctx.poolMode)

func syncState*(
    buddy: BeaconPeerRef;
      ): (SyncPeerRunState,SyncState,HeaderChainMode,bool) =
  ## Getter, also includes buddy state
  (buddy.ctrl.state,
   buddy.ctx.pool.syncState,
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

func toMeanVar*(w: ThPutStats): MeanVarStats =
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
    stats.samples.inc
    if 0 < dataSize:
      let bps = dataSize.float * 1_000_000_000f / ns.float
      stats.sum += bps
      stats.sum2 +=  bps * bps
      stats.total += dataSize.uint64
      return bps.uint

# -------------

func avg*(w: SyncEta): chronos.Duration =
  ## Get the avaerage of the round robin register
  if low(Moment) < w.lastUpdate:
    nanoseconds(w.etaRr.foldl(a + b / w.etaRr.len.float, 0f).int64)
  elif w.inSync:
    0.nanoseconds
  else:
    twoHundredYears

func latest*(w: SyncEta): chronos.Duration =
  ## Get the latest ETA entry
  if low(Moment) < w.lastUpdate:
    nanoseconds w.etaRr[w.etaInx].int64
  elif w.inSync:
    0.nanoseconds
  else:
    twoHundredYears

proc add*(w: var SyncEta; value: float) =
  ## Register a new ETA entry
  w.etaInx.inc
  if w.etaRr.len <= w.etaInx:
    # Wait with time stamp for at least one index cycle
    w.lastUpdate = Moment.now()
    w.etaInx = 0
  elif low(Moment) < w.lastUpdate:
    w.lastUpdate = Moment.now()
  w.etaRr[w.etaInx] = value
  w.inSync = false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
