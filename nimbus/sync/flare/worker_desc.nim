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
  pkg/[bearssl/rand, chronos, chronos/timer],
  pkg/stew/[interval_set, sorted_set],
  ../../db/era1_db,
  ../sync_desc

export
  sync_desc

const
  enableTicker* = false or true
    ## Log regular status updates similar to metrics. Great for debugging.

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(30)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  runMultiIdleWaitInterval* = chronos.seconds(30)
    ## Sllep some time in multi-mode if there is nothing to do

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ## Generously calculating a header with size 1k, fetching 1_024 headers
    ## would amount to a megabyte. As suggested in
    ## github.com/ethereum/devp2p/blob/master/caps/eth.md#blockheaders-0x04,
    ## the size of a message should not exceed 2 MiB.
    ##
    ## On live tests, responses to larger requests where all truncted to 1024
    ## header entries. It makes sense to not ask for more. So reserving
    ## smaller unprocessed slots that mostly all will be served leads to less
    ## fragmentation on a multi-peer downloading approach.

  nFetchHeadersOpportunisticly* = 8 * nFetchHeadersRequest
    ## Length of the request/stage batch. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.
    ## This is the size of an opportunistic run where the record stashed on
    ## the queue might be later discarded.

  nFetchHeadersByTopHash* = 16 * nFetchHeadersRequest
    ## This entry is similar to `nFetchHeadersOpportunisticly` only that it
    ## will always be successfully merged into the database.

  stagedQueueLengthLwm* = 24
    ## Limit the number of records in the staged queue. They start accumulating
    ## if one peer stalls while fetching the top chain so leaving a gap. This
    ## gap must be filled first before inserting the queue into a contiguous
    ## chain of headers. So this is a low-water mark where the system will
    ## try some magic to mitigate this problem.

  stagedQueueLengthHwm* = 40
    ## If this size is exceeded, the staged queue is flushed and its contents
    ## is re-fetched from scratch.

when enableTicker:
  import ./worker/start_stop/ticker

type
  BnRangeSet* = IntervalSetRef[BlockNumber,uint64]
    ## Disjunct sets of block number intervals

  BnRange* = Interval[BlockNumber,uint64]
    ## Single block number interval

  LinkedHChainQueue* = SortedSet[BlockNumber,LinkedHChain]
    ## Block intervals sorted by largest block number.

  LinkedHChainQueueWalk* = SortedSetWalkRef[BlockNumber,LinkedHChain]
    ## Traversal descriptor

  LinkedHChain* = object
    ## Public block items for the `LinkedHChainQueue` list, indexed by the
    ## largest block number. The list `revHdrs[]` is reversed, i.e. the largest
    ## block number has the least index `0`. This makes it easier to grow the
    ## sequence with parent headers, i.e. decreasing block numbers.
    ##
    hash*: Hash256                   ## Hash of `headers[0]`
    revHdrs*: seq[Blob]              ## Encoded linked header chain
    parentHash*: Hash256             ## Parent hash of `headers[^1]`

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
    header*: BlockHeader             ## Running on beacon chain, last header
    slow_start*: float               ## Share of block number to use if positive

  LinkedHChainsSync* = object
    ## Sync state for linked header chains
    beacon*: BeaconHeader            ## See `Z` in README
    unprocessed*: BnRangeSet         ## Block or header ranges to fetch
    staged*: LinkedHChainQueue       ## Blocks fetched but not stored yet
    layout*: LinkedHChainsLayout     ## Current header chains layout
    lastLayout*: LinkedHChainsLayout ## Previous layout (for delta update)

  # -------------------

  FlareBuddyData* = object
    ## Local descriptor data extension
    fetchBlocks*: BnRange

  FlareTossUp* = object
    ## Reminiscent of CSMA/CD. For the next number `nCoins` in a row, each
    ## participant can fetch a `true`/`false` value to decide whether to
    ## start doing something or delay.
    nCoins*: uint                    ## Numner of coins to toss in a row
    nLeft*: uint                     ## Number of flopped coins left
    coins*: uint64                   ## Sequence of fliopped coins

  FlareCtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext        ## Random generator, pre-initialised
    lhcSyncState*: LinkedHChainsSync ## Syncing by linked header chains
    tossUp*: FlareTossUp             ## Reminiscent of CSMA/CD
    nextUpdate*: Moment              ## For updating metrics

    # Era1 related, disabled if `e1db` is `nil`
    e1Dir*: string                   ## Pre-merge archive (if any)
    e1db*: Era1DbRef                 ## Era1 db handle (if any)
    e1AvailMax*: BlockNumber         ## Last Era block applicable here

    # Info stuff, no functional contribution
    nBuddies*: int                   ## Number of active workers (info only)
    nReorg*: int                     ## Number of reorg invocations (info only)

    # Debugging stuff
    when enableTicker:
      ticker*: TickerRef             ## Logger ticker

  FlareBuddyRef* = BuddyRef[FlareCtxData,FlareBuddyData]
    ## Extended worker peer descriptor

  FlareCtxRef* = CtxRef[FlareCtxData]
    ## Extended global descriptor

static:
  doAssert 0 < nFetchHeadersRequest
  doAssert nFetchHeadersRequest <= nFetchHeadersOpportunisticly
  doAssert nFetchHeadersRequest <= nFetchHeadersByTopHash

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func lhc*(ctx: FlareCtxRef): var LinkedHChainsSync =
  ## Shortcut
  ctx.pool.lhcSyncState

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
