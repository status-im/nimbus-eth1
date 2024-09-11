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
  pkg/[bearssl/rand, chronos], # chronos/timer],
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
