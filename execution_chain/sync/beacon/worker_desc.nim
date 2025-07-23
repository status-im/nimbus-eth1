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
  ../../core/chain,
  ../[sync_desc, wire_protocol],
  ./worker/helpers,
  ./worker_const

export
  helpers, sync_desc, worker_const, chain

type
  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData]
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

  # -------------------

  ActivateSyncerHdl* =
    proc(ctx: BeaconCtxRef) {.gcsafe, raises: [].}
      ## Syncer activation function run when notified by header chain cache.

  SuspendSyncerHdl* = proc(ctx: BeaconCtxRef) {.gcsafe, raises: [].}
    ## Syncer hibernate function run when the current session fas finished.

  SchedDaemonHdl* =
    proc(ctx: BeaconCtxRef): Future[Duration] {.async: (raises: []).}
      ## See `runDaemon()` described in `sync_sched.nim`

  SchedStartHdl* =
    proc(buddy: BeaconBuddyRef): bool {.gcsafe, raises: [].}
      ## See `runStart()` described in `sync_sched.nim`

  SchedStopHdl* =
    proc(buddy: BeaconBuddyRef) {.gcsafe, raises: [].}
      ## See `runStart()` described in `sync_sched.nim`

  SchedPoolHdl* =
    proc(buddy: BeaconBuddyRef; last: bool; laps: int):
      bool {.gcsafe, raises: [].}
        ## See `runPool()` described in `sync_sched.nim`

  SchedPeerHdl* =
    proc(buddy: BeaconBuddyRef): Future[Duration] {.async: (raises: []).}
      ## See `runPeer()` described in `sync_sched.nim`

  GetBlockHeadersHdl* =
    proc(buddy: BeaconBuddyRef; req: BlockHeadersRequest):
      Future[Result[FetchHeadersData,BeaconError]] {.async: (raises: []).}
        ## From the ethXX argument peer implied by `buddy` fetch a list of
        ## headers.

  SyncBlockHeadersHdl* =
    proc(buddy: BeaconBuddyRef) {.gcsafe, raises: [].}
      ## Status of syncer after `GetBlockHeadersHdl`

  GetBlockBodiesHdl* =
    proc(buddy: BeaconBuddyRef; request: BlockBodiesRequest):
      Future[Result[FetchBodiesData,BeaconError]] {.async: (raises: []).}
        ## Fetch bodies from the network.

  SyncBlockBodiesHdl* =
    proc(buddy: BeaconBuddyRef) {.gcsafe, raises: [].}
      ## Status of syncer after `GetBlockBodiesHdl`

  ImportBlockHdl* =
    proc(ctx: BeaconCtxRef; maybePeer: Opt[BeaconBuddyRef]; blk: EthBlock;
      effPeerID: Hash):
      Future[Result[Duration,BeaconError]] {.async: (raises: []).}
        ## Import a sinmgle block into `FC` module.

  SyncImportBlockHdl* =
    proc(ctx: BeaconCtxRef; maybePeer: Opt[BeaconBuddyRef])
      {.gcsafe, raises: [].}
        ## Status of syncer after `ImportBlockHdl`

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

  BuddyError* = tuple
    ## Count fetching or processing errors
    hdr, blk: uint8

  BeaconBuddyData* = object
    ## Local descriptor data extension
    nRespErrors*: BuddyError         ## Number of errors/slow responses in a row


  BeaconHandlersRef* = ref object of RootRef
    ## Selected handlers that can be replaced for tracing. The version number
    ## allows to identify overlays.
    version*: int                    ## Overlay version unless 0 (i.e. base=0)
    activate*: ActivateSyncerHdl     ## Allows for redirect (e.g. tracing)
    suspend*: SuspendSyncerHdl       ## Ditto
    schedDaemon*: SchedDaemonHdl     ## ...
    schedStart*: SchedStartHdl
    schedStop*: SchedStopHdl
    schedPool*: SchedPoolHdl
    schedPeer*: SchedPeerHdl
    getBlockHeaders*: GetBlockHeadersHdl
    syncBlockHeaders*: SyncBlockHeadersHdl
    getBlockBodies*: GetBlockBodiesHdl
    syncBlockBodies*: SyncBlockBodiesHdl
    importBlock*: ImportBlockHdl
    syncImportBlock*: SyncImportBlockHdl

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
    handlers*: BeaconHandlersRef     ## Allows for redirect (e.g. tracing)

    # Info, debugging, and error handling stuff
    nProcError*: Table[Hash,BuddyError] ## Per peer processing error
    lastSlowPeer*: Opt[Hash]         ## Register slow peer when the last one
    failedPeers*: HashSet[Hash]      ## Detect dead end sync by collecting peers
    seenData*: bool                  ## Set `true` if data were fetched, already

    # Debugging stuff
    clReq*: SyncClMesg               ## Manual first target set up

    when enableTicker:
      ticker*: RootRef               ## Logger ticker

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

func handler*(ctx: BeaconCtxRef): BeaconHandlersRef =
  ## Shortcut
  ctx.pool.handlers

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

proc incHdrProcErrors*(buddy: BeaconBuddyRef) =
  ## Increment `proc` error count for for argument `buddy`. Due to
  ## (hypothetical) hash collisions, the error register might have
  ## vanished in case a new one is instantiated.
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.hdr.inc
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (1u8,0u8)

proc setHdrProcFail*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Set `proc` error count high enough so that the implied sync peer will
  ## be zombified on the next attempt to download data.
  ctx.pool.nProcError.withValue(peerID, val):
    val.hdr = nProcHeadersErrThreshold + 1

proc resetHdrProcErrors*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Reset `proc` error count.
  ctx.pool.nProcError.withValue(peerID, val):
    val.hdr = 0

# -----

proc nBlkProcErrors*(buddy: BeaconBuddyRef): int =
  ## Getter, similar to `nHdrProcErrors()`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    return val.blk.int

proc incBlkProcErrors*(buddy: BeaconBuddyRef) =
  ## Increment `proc` error count, similar to `incHdrProcErrors()`
  buddy.ctx.pool.nProcError.withValue(buddy.peerID, val):
    val.blk.inc
  do:
    buddy.ctx.pool.nProcError[buddy.peerID] = (0u8,1u8)

proc setBlkProcFail*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Set `proc` error count high enough so that the implied sync peer will
  ## be zombified on the next attempt to download data.
  ctx.pool.nProcError.withValue(peerID, val):
    val.blk = nProcBlocksErrThreshold + 1

proc resetBlkProcErrors*(ctx: BeaconCtxRef; peerID: Hash) =
  ## Reset `proc` error count.
  ctx.pool.nProcError.withValue(peerID, val):
    val.blk = 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
