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
  pkg/[chronicles, chronos],
  pkg/eth/[common, rlp],
  pkg/stew/[byteutils, sorted_set],
  ../../../core/chain,
  ../worker_desc,
  ./update/metrics,
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  "."/[blocks_unproc, db, headers_unproc, helpers]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc syncState(ctx: BeaconCtxRef; info: static[string]): SyncLayoutState =
  ## Calculate `SyncLayoutState` from the download context

  let
    b = ctx.chain.baseNumber()
    l = ctx.chain.latestNumber()
    c = ctx.layout.coupler
    d = ctx.layout.dangling
    h = ctx.layout.head

  # See clause *(8)* in `README.md`:
  # ::
  #     0               H    L
  #     o---------------o----o
  #     | <--- imported ---> |
  #
  # where `H << L` with `L` is the `latest` (aka cursor) parameter from
  # `FC` the logic will be updated to (see clause *(9)* in `README.md`):
  #
  if h <= c or h <= l:                 # empty interval `(C,H]` or nothing to do
    return idleSyncState

  # See clauses *(9)* and *(10)* in `README.md`:
  # ::
  #   0               B
  #   o---------------o----o
  #   | <--- imported ---> |
  #                C                     D                H
  #                o---------------------o----------------o
  #                | <-- unprocessed --> | <-- linked --> |
  #
  # where *B* is the **base** entity of the `FC` module and `C` is sort of
  # a placehoder with block number equal to *B* at some earlier time (the
  # value *B* increases over time.)
  #
  # It is already known that `C < H` (see first check)
  #
  if c <= b:                           # check for `C <= B` as sketched above

    # Case `C < D-1` => not ready yet
    if c + 1 < d:
      return collectingHeaders

    # Case `C == D-1` => just finished the download
    if c + 1 == d:
      return finishedHeaders

    # Case `C == D` => see below for general case

  # Case `C == D` => set to import blocks (see *(10)* in `README.md`):
  # ::
  #   0                    L
  #   o--------------------o
  #   | <--- imported ---> |
  #                     D
  #                     C                                H
  #                     o--------------------------------o
  #                     | <-- blocks to be completed --> |
  #
  # It is known already (see first check) that `L <`H`
  #
  if c == d:
    return processingBlocks

  # Case `B < C` oops:
  # ::
  #     0               B
  #     o---------------o----o
  #     | <--- imported ---> |
  #                        C                     D                H
  #                        o---------------------o----------------o
  #                        | <-- unprocessed --> | <-- linked --> |
  #
  debug info & ": inconsistent state",
    B=(if b == c: "C" else: b.bnStr),
    C=(if c == l: "L" else: c.bnStr),
    L=(if l == d: "D" else: l.bnStr),
    D=(if d == h: "H" else: d.bnStr),
    H=h.bnStr

  idleSyncState

# ------------

proc startHibernating(ctx: BeaconCtxRef; info: static[string]) =
  ## Clean up target bucket and await a new target.
  ##
  ctx.sst.reset # => target.reset, layout.reset
  ctx.headersUnprocClear()
  ctx.blocksUnprocClear()
  ctx.headersStagedQueueClear()
  ctx.blocksStagedQueueClear()
  ctx.dbHeadersClear()

  ctx.hibernate = true

  info info & ": suspending syncer", L=ctx.chain.latestNumber.bnStr

  # Update, so it can be followed nicely
  ctx.updateMetrics()


proc setupCollectingHeaders(ctx: BeaconCtxRef; info: static[string]) =
  ## Set up sync target (see clause *(9)* in `README.md`) by modifying
  ## layout to:
  ## ::
  ##   0            B
  ##   o------------o-------o
  ##   | <--- imported ---> |                           D
  ##                C                                   H
  ##                o-----------------------------------o
  ##                | <--------- unprocessed ---------> |
  ##
  ## where *B* is the **base** entity of the `FC` module and `C ~ B`. The
  ## parameter `H` is set to the new sync head target `T`.
  ##
  let
    c = ctx.chain.baseNumber()
    h = ctx.target.consHead.number

  if c+1 < h:                                 # header chain interval is `(C,H]`
    doAssert ctx.headersUnprocTotal() == 0
    doAssert ctx.headersUnprocBorrowed() == 0
    doAssert ctx.headersStagedQueueIsEmpty()
    doAssert ctx.blocksUnprocTotal() == 0
    doAssert ctx.blocksUnprocBorrowed() == 0
    doAssert ctx.blocksStagedQueueIsEmpty()

    ctx.sst.layout = SyncStateLayout(
      coupler:   c,
      dangling:  h,
      final:     ctx.target.final,
      finalHash: ctx.target.finalHash,
      head:      h,
      lastState: collectingHeaders)           # state transition

    # Save this header on the database so it needs not be fetched again from
    # somewhere else.
    ctx.dbHeadersStash(h, @[rlp.encode(ctx.target.consHead)], info)

    # Save state
    ctx.dbStoreSyncStateLayout info

    # Update range
    ctx.headersUnprocSet(c+1, h-1)

    # Update, so it can be followed nicely
    ctx.updateMetrics()

    # Mark target used, reset for re-fill
    ctx.target.changed = false

    trace info & ": new header target", C=c.bnStr, D="H", H="T", T=h.bnStr


proc linkIntoFc(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Link `(C,H]` into the `FC` logic. If successful, `true` is returned.
  ## Otherwise the chain `(C,H]` must be discarded.
  ##
  ## Condider the following layout (see clause *(10)* in `README.md`):
  ## ::
  ##   0             B  Y    L
  ##   o-------------o--o----o
  ##   | <--- imported ----> |
  ##                C    Z                                H
  ##                o----o--------------------------------o
  ##                | <------------- linked ------------> |
  ##
  ## for some `Y` in `[B,L]` and `Z` in `(C,H]` where `Y<-Z` with `L` the
  ## `latest` and `B` the `base` entity of the `FC` logic.
  ##
  ## If there are such `Y <- Z`, then update the sync state to (see chause
  ## *(11)* in `README.md`):
  ## ::
  ##   0                Y
  ##   o----------------o----o
  ##   | <--- imported ----> |
  ##                   D
  ##                   C Z                              H
  ##                   o-o------------------------------o
  ##                   | <-- blocks to be completed --> |
  ##
  ## where `C==Y`, `(C,H]==[Z,H]`, `C<-Z`
  ##
  ## Otherwise, if *Z* does not exists then reset to idle state.
  ##
  let
    b = ctx.chain.baseNumber()
    l = ctx.chain.latestNumber()
    c = ctx.layout.coupler
    h = ctx.layout.head

  if l < h:
    # Try to find a parent in the `FC` data domain. For practical reasons the
    # loop does not go further back than the base `B`. Blocks below/older than
    # that will not be handled by the `FC`.
    for bn in (l+1).countdown(max(b,c)):

      # The syncer cache holds headers for `(C,H]`. It starts with checking
      # whether `L<-Z` holds (i.e. `Y==L` can be chosen.)
      let
        yHash = ctx.dbHeaderParentHash(bn).expect "Hash32"     # maybe `Y`
        yHdr = ctx.chain.headerByHash(yHash).valueOr: continue # test for `Y`
        yNum = yHdr.number                                     # == bn-1

      ctx.layout.coupler = yNum                                # parent of `Z`
      ctx.layout.dangling = yNum                               # .. ditto

      trace info & ": linked into FC", B=b.bnStr,
        C=(if yNum==l: "L" else: yNum.bnStr), L=l.bnStr, H=h.bnStr

      # Save layout state
      ctx.dbStoreSyncStateLayout info

      # Update, so it can be followed nicely
      ctx.updateMetrics()
      return true

  trace info & ": cannot link into FC", B=b.bnStr, L=l.bnStr,
    C=c.bnStr, H=h.bnStr
  false


proc setupProcessingBlocks(ctx: BeaconCtxRef; info: static[string]) =
  doAssert ctx.headersUnprocTotal() == 0
  doAssert ctx.headersUnprocBorrowed() == 0
  doAssert ctx.headersStagedQueueIsEmpty()
  doAssert ctx.blocksUnprocTotal() == 0
  doAssert ctx.blocksUnprocBorrowed() == 0
  doAssert ctx.blocksStagedQueueIsEmpty()

  let
    c = ctx.layout.coupler
    h = ctx.layout.head

  # Update blocks `(C,H]`
  ctx.blocksUnprocCommit(0, c+1, h)

  # State transition
  ctx.layout.lastState = processingBlocks

  trace info & ": collecting block bodies", iv=BnRange.new(c+1, h)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update internal state when needed
  let
    prevState = ctx.layout.lastState     # previous state
    thisState = ctx.syncState info       # currently observed state

  if thisState == prevState:
    # Check whether the system has been idle and a new header download
    # session can be set up
    if prevState == idleSyncState and
       ctx.target.changed and            # and there is a new target from CL
       ctx.target.final != 0:            # .. ditto
      ctx.setupCollectingHeaders info    # set up new header sync
    return
    # Notreached

  info info & ": sync state changed", prevState, thisState,
    L=ctx.chain.latestNumber.bnStr,
    C=(if ctx.layout.coupler == ctx.layout.dangling: "D"
       else: ctx.layout.coupler.bnStr),
    D=(if ctx.layout.dangling == ctx.layout.head: "H"
       else: ctx.layout.dangling.bnStr),
    H=ctx.layout.head.bnStr

  # So there is a states transition. The only relevant transition here
  # is `collectingHeaders -> finishedHeaders` which will be continued
  # as `finishedHeaders -> processingBlocks`.
  #
  if prevState == collectingHeaders and
     thisState == finishedHeaders and
     ctx.linkIntoFc(info):               # commit downloading headers
    ctx.setupProcessingBlocks info       # start downloading block bodies
    info info & ": sync state changed",
      prevState=thisState, thisState=ctx.syncState(info)
    return
    # Notreached

  # Final sync target reached or inconsistent/impossible state
  ctx.startHibernating info


proc updateFinalBlockHeader*(
    ctx: BeaconCtxRef;
    finHdr: Header;
    finHash: Hash32;
    info: static[string];
      ) =
  ## Update the finalised header cache. If the finalised header is acceptable,
  ## the syncer will be activated from hibernation if necessary.
  ##
  let
    b = ctx.chain.baseNumber()
    f = finHdr.number
  if f < b:
    trace info & ": finalised block # too low",
      B=b.bnStr, finalised=f.bnStr, delta=(b - f)

    ctx.target.reset

  else:
    ctx.target.final = f
    ctx.target.finalHash = finHash

    # Activate running (unless done yet)
    if ctx.hibernate:
      ctx.hibernate = false
      info info & ": activating syncer", B=b.bnStr,
        finalised=f.bnStr, head=ctx.target.consHead.bnStr

    # Update, so it can be followed nicely
    ctx.updateMetrics()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
