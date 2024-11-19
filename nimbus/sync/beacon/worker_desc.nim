# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronos,
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../core/chain,
  ../sync_desc,
  ./worker/helpers,
  ./worker_config

export
  helpers, sync_desc, worker_config

when enableTicker:
  import ./worker/start_stop/ticker

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
    revHdrs*: seq[seq[byte]]         ## Encoded linked header chain
    parentHash*: Hash32              ## Parent hash of `headers[^1]`

  StagedBlocksQueue* = SortedSet[BlockNumber,BlocksForImport]
    ## Blocks sorted by least block number.

  BlocksForImport* = object
    ## Block request item sorted by least block number (i.e. from `blocks[0]`.)
    blocks*: seq[EthBlock]           ## List of blocks for import

  KvtCache* = Table[BlockNumber,seq[byte]]
    ## This cache type is intended for holding block headers that cannot be
    ## reliably saved persistently. This is the situation after blocks are
    ## imported as the FCU handlers always maintain a positive transaction
    ## level and in some instances the current transaction is flushed and
    ## re-opened.
    ##
    ## The number of block headers to hold in memory after block import has
    ## started is the distance to the new `canonical execution head`.

  # -------------------

  SyncStateTarget* = object
    ## Beacon state to be implicitely updated by RPC method
    locked*: bool                    ## Don't update while fetching header
    changed*: bool                   ## Tell that something has changed
    consHead*: Header                ## Consensus head
    final*: BlockNumber              ## Finalised block number
    finalHash*: Hash32               ## Finalised hash

  SyncStateLayout* = object
    ## Layout of a linked header chains defined by the triple `(C,D,H)` as
    ## described in the `README.md` text.
    ## ::
    ##   0          B     L       C                     D            F   H
    ##   o----------o-----o-------o---------------------o------------o---o--->
    ##   | <- imported -> |       |                     |                |
    ##   | <------ linked ------> | <-- unprocessed --> | <-- linked --> |
    ##
    ## Additional positions known but not declared in this descriptor:
    ## * `B`: base state (from `forked_chain` importer)
    ## * `L`: last imported block, canonical consensus head
    ## * `F`: finalised head (from CL)
    ##
    coupler*: BlockNumber            ## Right end `C` of linked chain `[0,C]`
    dangling*: BlockNumber           ## Left end `D` of linked chain `[D,H]`
    final*: BlockNumber              ## Finalised block number `F`
    finalHash*: Hash32               ## Hash of `F`
    head*: BlockNumber               ## `H`, block num of some finalised block
    headLocked*: bool                ## No need to update `H` yet

  SyncState* = object
    ## Sync state for header and block chains
    target*: SyncStateTarget         ## Consensus head, see `T` in `README.md`
    layout*: SyncStateLayout         ## Current header chains layout
    lastLayout*: SyncStateLayout     ## Previous layout (for delta update)

  # -------------------

  HeaderImportSync* = object
    ## Header sync staging area
    unprocessed*: BnRangeSet         ## Block or header ranges to fetch
    borrowed*: uint64                ## Total of temp. fetched ranges
    staged*: LinkedHChainQueue       ## Blocks fetched but not stored yet

  BlocksImportSync* = object
    ## Block sync staging area
    unprocessed*: BnRangeSet         ## Blocks download requested
    borrowed*: uint64                ## Total of temp. fetched ranges
    topRequest*: BlockNumber         ## Max requested block number
    staged*: StagedBlocksQueue       ## Blocks ready for import

  # -------------------

  BeaconBuddyData* = object
    ## Local descriptor data extension
    nHdrRespErrors*: int             ## Number of errors/slow responses in a row
    nBdyRespErrors*: int             ## Ditto for bodies

    # Debugging and logging.
    nMultiLoop*: int                 ## Number of runs
    stoppedMultiRun*: chronos.Moment ## Time when run-multi stopped
    multiRunIdle*: chronos.Duration  ## Idle time between runs

  BeaconCtxData* = object
    ## Globally shared data extension
    nBuddies*: int                   ## Number of active workers
    syncState*: SyncState            ## Save/resume state descriptor
    hdrSync*: HeaderImportSync       ## Syncing by linked header chains
    blkSync*: BlocksImportSync       ## For importing/executing blocks
    nextUpdate*: Moment              ## For updating metrics

    # Blocks import/execution settings for importing with
    # `nBodiesBatch` blocks in each round (minimum value is
    # `nFetchBodiesRequest`.)
    chain*: ForkedChainRef           ## Core database, FCU support
    stash*: KvtCache                 ## Temporary header and state table
    blockImportOk*: bool             ## Don't fetch data while block importing
    nBodiesBatch*: int               ## Default `nFetchBodiesBatchDefault`
    blocksStagedQuLenMax*: int       ## Default `blocksStagedQueueLenMaxDefault`

    # Info & debugging stuff, no functional contribution
    nReorg*: int                     ## Number of reorg invocations (info only)

    # Debugging stuff
    when enableTicker:
      ticker*: TickerRef             ## Logger ticker

  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func sst*(ctx: BeaconCtxRef): var SyncState =
  ## Shortcut
  ctx.pool.syncState

func hdr*(ctx: BeaconCtxRef): var HeaderImportSync =
  ## Shortcut
  ctx.pool.hdrSync

func blk*(ctx: BeaconCtxRef): var BlocksImportSync =
  ## Shortcut
  ctx.pool.blkSync

func layout*(ctx: BeaconCtxRef): var SyncStateLayout =
  ## Shortcut
  ctx.sst.layout

func target*(ctx: BeaconCtxRef): var SyncStateTarget =
  ## Shortcut
  ctx.sst.target

func chain*(ctx: BeaconCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.chain

func stash*(ctx: BeaconCtxRef): var KvtCache =
  ## Getter
  ctx.pool.stash

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
