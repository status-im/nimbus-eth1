# Nimbus
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[hashes, math, options, sets],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[interval_set, keyed_queue],
  ../../db/select_backend,
  ".."/[protocol, sync_desc],
  ./worker/[accounts_db, fetch_accounts, ticker],
  "."/[range_desc, worker_desc]

const
  usePivot2ok = false or true

when usePivot2ok:
  import ../pivot/best_pivot
else:
  import ../pivot/snap_pivot

{.push raises: [Defect].}

logScope:
  topics = "snap-sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(h: Hash256): Hash =
  ## Mixin for `Table` or `keyedQueue`
  h.data.hash

proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
  if 0 < length:
    result[0] = sum / length.float
    result[1] = sqrt(sqSum / length.float - result[0] * result[0])

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" & info & ": name=" & $e.name & " msg=" & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

when usePivot2ok:
  proc envPivotNumber(buddy: SnapBuddyRef): BlockNumber =
    if buddy.ctx.data.pivotEnv.isNil:
      0.u256
    else:
      buddy.ctx.data.pivotEnv.stateHeader.blockNumber

  template pivotSetup(ctx: SnapCtxRef) = ctx.bestPivotSetup()
  template pivotRelease(ctx: SnapCtxRef) = ctx.bestPivotRelease()
  template pivotStart(b: SnapBuddyRef) = b.bestPivotStart()
  template pivotStop(b: SnapBuddyRef) = b.bestPivotStop()
  template pivotRestart(b: SnapBuddyRef) = b.bestPivotRestart()
  template pivotHeader(b: SnapBuddyRef): auto = b.bestPivotHeader()
  template pivotNegotiate(b: SnapBuddyRef; n: BlockNumber): auto =
    b.bestPivotNegotiate(n)
else:
  template pivotSetup(ctx: SnapCtxRef) = ctx.snapPivotSetup()
  template pivotRelease(ctx: SnapCtxRef) = ctx.snapPivotRelease()
  template pivotStart(b: SnapBuddyRef) = b.snapPivotStart()
  template pivotStop(b: SnapBuddyRef) = b.snapPivotStop()
  template pivotRestart(b: SnapBuddyRef) = b.snapPivotRestart()
  template pivotHeader(b: SnapBuddyRef): auto = b.snapPivotHeader()
  template pivotNegotiate(b: SnapBuddyRef): auto = b.snapPivotNegotiate()


proc rndNodeTag(buddy: SnapBuddyRef): NodeTag =
  ## Create random node tag
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var data: array[32,byte]
  ctx.data.rng[].generate(data)
  UInt256.fromBytesBE(data).NodeTag


proc setPivotEnv(buddy: SnapBuddyRef; header: BlockHeader) =
  ## Activate environment for state root implied by `header` argument
  let
    ctx = buddy.ctx
    key = header.stateRoot
    rc = ctx.data.pivotTable.lruFetch(key)
  if rc.isOk:
    ctx.data.pivotEnv = rc.value
    return

  let env = SnapPivotRef(
    stateHeader:   header,
    pivotAccount:  buddy.rndNodeTag,
    availAccounts: LeafRangeSet.init())
  # Pre-filled with the largest possible interval
  discard env.availAccounts.merge(low(NodeTag),high(NodeTag))

  # Statistics
  ctx.data.pivotCount.inc

  # Activate per-state root environment (and hold previous one)
  ctx.data.prevEnv = ctx.data.pivotEnv
  ctx.data.pivotEnv = ctx.data.pivotTable.lruAppend(key, env, ctx.buddiesMax)


proc updatePivotEnv(buddy: SnapBuddyRef): bool =
  ## Update global state root environment from local `pivotHeader`. Choose the
  ## latest block number. Returns `true` if the environment was changed
  let rc = buddy.pivotHeader
  if rc.isOk:
    let
      peer = buddy.peer
      ctx = buddy.ctx
      env = ctx.data.pivotEnv
      pivotHeader = rc.value
      newStateNumber = pivotHeader.blockNumber
      stateNumber = if env.isNil: 0.toBlockNumber
                    else: env.stateHeader.blockNumber
      stateWindow = stateNumber + maxPivotBlockWindow

    block keepCurrent:
      if env.isNil:
        break keepCurrent # => new pivot
      if stateNumber < newStateNumber:
        when switchPivotAfterCoverage < 1.0:
          if env.minCoverageReachedOk:
            break keepCurrent # => new pivot
        if stateWindow < newStateNumber:
          break keepCurrent # => new pivot
        if newStateNumber <= maxPivotBlockWindow:
          break keepCurrent # => new pivot
      # keep current
      return false

    # set new block
    buddy.setPivotEnv(pivotHeader)
    return true


proc tickerUpdate*(ctx: SnapCtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    var
      aSum, aSqSum, uSum, uSqSum, sSum, sSqSum: float
      count = 0
    for kvp in ctx.data.pivotTable.nextPairs:

      # Accounts mean & variance
      let aLen = kvp.data.nAccounts.float
      if 0 < aLen:
        count.inc
        aSum += aLen
        aSqSum += aLen * aLen

        # Fill utilisation mean & variance
        let fill = kvp.data.availAccounts.freeFactor
        uSum += fill
        uSqSum += fill * fill

        let sLen = kvp.data.nStorage.float
        sSum += sLen
        sSqSum += sLen * sLen

    let
      tabLen = ctx.data.pivotTable.len
      pivotBlock = if ctx.data.pivotEnv.isNil: none(BlockNumber)
                   else: some(ctx.data.pivotEnv.stateHeader.blockNumber)
      accCoverage = ctx.data.coveredAccounts.fullFactor
      accFill = meanStdDev(uSum, uSqSum, count)

    when snapAccountsDumpEnable:
      if snapAccountsDumpCoverageStop < accCoverage:
        trace " Snap proofs dump stop",
          threshold=snapAccountsDumpCoverageStop, coverage=accCoverage.toPC
        ctx.data.proofDumpOk = false

    TickerStats(
      pivotBlock:    pivotBlock,
      activeQueues:  tabLen,
      flushedQueues: ctx.data.pivotCount.int64 - tabLen,
      nAccounts:     meanStdDev(aSum, aSqSum, count),
      nStorage:      meanStdDev(sSum, sSqSum, count),
      accountsFill:  (accFill[0], accFill[1], accCoverage))


proc havePivot(buddy: SnapBuddyRef): bool =
  ## ...
  let rc = buddy.pivotHeader
  if rc.isOk and rc.value.blockNumber != 0:

    # So there is a `ctx.data.pivotEnv`
    when 1.0 <= switchPivotAfterCoverage:
      return true
    else:
      let
        ctx = buddy.ctx
        env = ctx.data.pivotEnv

      # Force fetching new pivot if coverage reached by returning `false`
      if not env.minCoverageReachedOk:

        # Not sure yet, so check whether coverage has been reached at all
        let cov = env.availAccounts.freeFactor
        if switchPivotAfterCoverage <= cov:
          trace " Snap accounts coverage reached", peer,
            threshold=switchPivotAfterCoverage, coverage=cov.toPC

          # Need to reset pivot handlers
          buddy.ctx.poolMode = true
          buddy.ctx.data.runPoolHook = proc(b: SnapBuddyRef) =
            b.ctx.data.pivotEnv.minCoverageReachedOk = true
            b.pivotRestart
          return true

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data.accountRangeMax = high(UInt256) div ctx.buddiesMax.u256
  ctx.data.coveredAccounts = LeafRangeSet.init()
  ctx.data.accountsDb =
      if ctx.data.dbBackend.isNil: AccountsDbRef.init(ctx.chain.getTrieDB)
      else: AccountsDbRef.init(ctx.data.dbBackend)
  ctx.pivotSetup()
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdate)
  else:
    trace "Ticker is disabled"
  result = true

  # -----------------------
  when snapAccountsDumpEnable:
    doAssert ctx.data.proofDumpFile.open("./dump-stream.out", fmWrite)
    ctx.data.proofDumpOk = true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.pivotRelease()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()
    ctx.data.ticker = nil

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.pivotStart()
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  buddy.ctrl.stopped = true
  buddy.pivotStop()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## This peer worker is invoked if the peer-local flag `buddy.ctrl.multiOk`
  ## is set `false` which is the default mode. This flag is updated by the
  ## worker when deemed appropriate.
  ## * For all workers, there can be only one `runSingle()` function active
  ##   simultaneously for all worker peers.
  ## * There will be no `runMulti()` function active for the same worker peer
  ##   simultaneously
  ## * There will be no `runPool()` iterator active simultaneously.
  ##
  ## Note that this function runs in `async` mode.
  ##
  when usePivot2ok:
    #
    # Run alternative pivot finder. This one harmonises difficulties of at
    # least two peers. The can only be one instance active/unfinished of the
    # `pivot2Exec()` functions.
    #
    let peer = buddy.peer
    if buddy.pivotHeader.isErr:
      if await buddy.pivotNegotiate(buddy.envPivotNumber):
        discard buddy.updatePivotEnv()
      else:
        # Wait if needed, then return => repeat
        if not buddy.ctrl.stopped:
          await sleepAsync(2.seconds)
        return

    buddy.ctrl.multiOk = true

    trace "Snap pivot initialised", peer,
      multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state
  else:
    #
    # The default pivot finder runs in multi mode. So there is nothing to do
    # here.
    #
    buddy.ctrl.multiOk = true


proc runPool*(buddy: SnapBuddyRef, last: bool) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## functions activated simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## peer instance.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let ctx = buddy.ctx
  if ctx.poolMode:
    ctx.poolMode = false
  if not ctx.data.runPoolHook.isNil:
    noExceptionOops("runPool"):
      ctx.data.runPoolHook(buddy)
    if last:
      ctx.data.runPoolHook = nil


proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  when not usePivot2ok:
    if not buddy.havePivot:
      await buddy.pivotNegotiate()
      if not buddy.updatePivotEnv():
        return

  # Ignore rest if the pivot is still acceptably covered
  when switchPivotAfterCoverage < 1.0:
    if ctx.data.pivotEnv.minCoverageReachedOk:
      await sleepAsync(50.milliseconds)
      return

  await buddy.fetchAccounts()

  if ctx.data.pivotEnv.repairState == Done:
    buddy.ctrl.multiOk = false
    buddy.pivotRestart()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
