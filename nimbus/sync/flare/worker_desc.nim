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
  pkg/stew/[interval_set, sorted_set],
  ../sync_desc,
  ./worker_config

export
  sync_desc, worker_config

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
    hash*: Hash256                   ## Hash of `headers[0]`
    revHdrs*: seq[Blob]              ## Encoded linked header chain
    parentHash*: Hash256             ## Parent hash of `headers[^1]`

  StagedBlocksQueue* = SortedSet[BlockNumber,BlocksForImport]
    ## Blocks sorted by least block number.

  BlocksForImport* = object
    ## Block request item sorted by least block number (i.e. from `blocks[0]`.)
    blocks*: seq[EthBlock]           ## List of blocks for import

  # -------------------

  LinkedHChainsLayout* = object
    ## Layout of a triple of linked header chains
    ## ::
    ##   G                B                     L                F
    ##   o----------------o---------------------o----------------o--->
    ##   | <-- linked --> | <-- unprocessed --> | <-- linked --> |
    ##
    ## see `README.md` for details and explanations
    ##
    base*: BlockNumber
      ## `B`, maximal block number of linked chain starting at Genesis `G`
    baseHash*: Hash256
      ## Hash of `B`

    least*: BlockNumber
      ## `L`, minimal block number of linked chain ending at `F` with `B <= L`
    leastParent*: Hash256
      ## Parent hash of `L` (similar to `parentHash` in `HeaderChainItemRef`)

    final*: BlockNumber
      ## `F`, some finalised block
    finalHash*: Hash256
      ## Hash of `F` (similar to `hash` in `HeaderChainItemRef`)

  BeaconHeader* = object
    ## Beacon state to be implicitely updated by RPC method
    changed*: bool                   ## Set a marker if something has changed
    header*: BlockHeader             ## Beacon chain, finalised header
    finalised*: Hash256              ## From RPC, ghash of finalised header

  LinkedHChainsSync* = object
    ## Sync state for linked header chains
    beacon*: BeaconHeader            ## See `Z` in README
    unprocessed*: BnRangeSet         ## Block or header ranges to fetch
    borrowed*: uint64                ## Total of temp. fetched ranges
    staged*: LinkedHChainQueue       ## Blocks fetched but not stored yet
    layout*: LinkedHChainsLayout     ## Current header chains layout
    lastLayout*: LinkedHChainsLayout ## Previous layout (for delta update)

  BlocksImportSync* = object
    ## Sync state for blocks to import/execute
    unprocessed*: BnRangeSet         ## Blocks download requested
    borrowed*: uint64                ## Total of temp. fetched ranges
    topRequest*: BlockNumber         ## Max requested block number
    staged*: StagedBlocksQueue       ## Blocks ready for import

  # -------------------

  FlareBuddyData* = object
    ## Local descriptor data extension
    nHdrRespErrors*: int             ## Number of errors/slow responses in a row
    nBdyRespErrors*: int             ## Ditto for bodies

    # Debugging and logging.
    nMultiLoop*: int                 ## Number of runs
    stoppedMultiRun*: chronos.Moment ## Time when run-multi stopped
    multiRunIdle*: chronos.Duration  ## Idle time between runs

  FlareCtxData* = object
    ## Globally shared data extension
    nBuddies*: int                   ## Number of active workers
    lhcSyncState*: LinkedHChainsSync ## Syncing by linked header chains
    blkSyncState*: BlocksImportSync  ## For importing/executing blocks
    nextUpdate*: Moment              ## For updating metrics

    # Blocks import/execution settings for running  `persistBlocks()` with
    # `nBodiesBatch` blocks in each round (minimum value is
    # `nFetchBodiesRequest`.)
    chain*: ChainRef
    importRunningOk*: bool           ## Advisory lock, fetch vs. import
    nBodiesBatch*: int               ## Default `nFetchBodiesBatchDefault`
    blocksStagedQuLenMax*: int       ## Default `blocksStagedQueueLenMaxDefault`

    # Info stuff, no functional contribution
    nReorg*: int                     ## Number of reorg invocations (info only)

    # Debugging stuff
    when enableTicker:
      ticker*: TickerRef             ## Logger ticker

  FlareBuddyRef* = BuddyRef[FlareCtxData,FlareBuddyData]
    ## Extended worker peer descriptor

  FlareCtxRef* = CtxRef[FlareCtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func lhc*(ctx: FlareCtxRef): var LinkedHChainsSync =
  ## Shortcut
  ctx.pool.lhcSyncState

func blk*(ctx: FlareCtxRef): var BlocksImportSync =
  ## Shortcut
  ctx.pool.blkSyncState

func layout*(ctx: FlareCtxRef): var LinkedHChainsLayout =
  ## Shortcut
  ctx.pool.lhcSyncState.layout

func db*(ctx: FlareCtxRef): CoreDbRef =
  ## Getter
  ctx.chain.com.db

# ------------------------------------------------------------------------------
# Public logging/debugging helpers
# ------------------------------------------------------------------------------

proc `$`*(w: BnRange): string =
  if w.len == 1: $w.minPt else: $w.minPt & ".." & $w.maxPt

proc bnStr*(w: BlockNumber): string =
  "#" & $w

# Source: `nimbus_import.shortLog()`
func toStr*(a: chronos.Duration, parts: int): string =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  if a == nanoseconds(0):
    return "0"
  var
    res = ""
    v = a.nanoseconds()
    parts = parts

  template f(n: string, T: Duration) =
    if v >= T.nanoseconds():
      res.add($(uint64(v div T.nanoseconds())))
      res.add(n)
      v = v mod T.nanoseconds()
      dec parts
      if v == 0 or parts <= 0:
        return res

  f("s", Second)
  f("ms", Millisecond)
  f("us", Microsecond)
  f("ns", Nanosecond)

  res

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
