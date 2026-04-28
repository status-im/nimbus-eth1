# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[algorithm, sets, sequtils],
  pkg/[chronicles, chronos, stew/interval_set],
  ../../../wire_protocol,
  ../[helpers, mpt, state_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc storageRecover(
    ctx: SnapCtxRef;
    state: StateDataRef;
    acc: SnapAccount;
    info: static[string];
      ) =
  let storageRoot = acc.accBody.storageRoot
  if not storageRoot.isEmpty:
    let
      stoRoot = storageRoot.to(StoreRoot)
      accKey = acc.accHash.to(ItemKey)
      left = ItemKeyRangeSet.init ItemKeyRangeMax

    for w in ctx.pool.mptAsm.walkStoSlot(state.stateRoot, accKey):
      discard left.reduce(w.start, w.limit)

    # Get the least point in the range it there is any. Unprocessed storage
    # was filled up linearly left to right (with increasing min point entry.)
    let iv = left.ge().valueOr:
      return
    state.register(accKey, stoRoot, ItemKeyRange.new(iv.minPt, high(ItemKey)))

proc codesRecover(
    ctx: SnapCtxRef;
    state: StateDataRef;
    lst: openArray[SnapAccount];
    info: static[string];
      ) =
  if 0 < lst.len:
    let
      accMin = lst[0].accHash.to(ItemKey)
      accMax = lst[^1].accHash.to(ItemKey)

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in ctx.pool.mptAsm.walkByteCode(state.stateRoot, accMin):
      if accMax < w.limit:
        break
      for (key,_) in w.codes:
        found.incl key

    # Check for unprocessed byte codes
    for w in lst:
      let
        snapHash = w.accBody.codeHash
        codeHash = snapHash.to(CodeHash)
      if not snapHash.isEmpty and codeHash notin found:
        state.register(w.accHash.to(ItemKey), codeHash)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionResume*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Async/template
  ##
  var bodyRc = false
  block body:
    let
      sdb = ctx.pool.stateDB
      adb = ctx.pool.mptAsm

    block recoverStates:
      var
        napAt = Moment.now() + threadSwitchRunLimit # allow for thread switch
        msgAt = Moment.now() + threadLogTimeLimit   # message while looping

        # Get list of sorted states available, the most recent ones first.
        byTouch = adb.walkStateData().toSeq()       # list to be sorted, below
        tchInx: seq[int]                            # index list into `byTouch`

      # Sort states, latest time stamp first
      byTouch.sort proc(x,y: WalkStateData): int = cmp(y.touch,x.touch)

      # Walk over states, latest time stamp first. Collect the lastest some
      # non-empty states (see `stateDbCapacity`) for import into the state
      # DB cache.
      for n in 0 ..< byTouch.len:
        let p = byTouch[n]

        if p.coverage.isZero:
          continue

        if stateDbCapacity <= tchInx.len:           # index list complete?
          sdb.addAccountArchive p.coverage.per256() # set archived coverage
          continue

        if tchInx.len == 0:                         # print message once, only
          chronicles.info info & ": Resuming download session",
            nStates=byTouch.len

        if p.onTrie:                                # ignore assembled data
          sdb.addAccountArchive p.coverage.per256() # set archived coverage
        else:
          tchInx.add n                              # collect, re-process below

      if tchInx.len == 0:                           # nothing to do?
        break body

      # Loop over states with time stamp in oldest-first order. Processing in
      # that order, current time stamps (aka `Moment.now()`) can be used when
      # importing into the state DB cache. This way, the oldest-first order
      # will be preserved on the cache.
      for n in (tchInx.len - 1).countdown(0):
        let p = byTouch[tchInx[n]]

        # Create record on state DB cache
        let state = sdb.register(p.root, p.hash, p.number, info)

        # Walk account for the current state root
        for w in adb.walkAccounts(p.root):
          if 0 < w.error.len:
            error info & ": Corrupt data, resetting session", error=w.error
            break recoverStates

          # Occasionally some text to show this loop is active
          if msgAt < Moment.now():
            debug info & ": Recovering states cache..", root=state.rootStr,
              n=(tchInx.len - 1 - n), nMax=tchInx.len
            msgAt = Moment.now() + threadLogTimeLimit

          # Register seen accounts in state record
          sdb.setAccountRange(state, w.start, w.limit, Moment.now())

          # Register unprocessed storages per account
          for acc in w.accounts:
            ctx.storageRecover(state, acc, info)

          # Register unprocessed codes for the current account list
          ctx.codesRecover(state, w.accounts, info)

          # Occasionally allow thread switch
          if napAt < Moment.now():
            try:
              await sleepAsync threadSwitchTimeSlot
            except CancelledError as e:
              chronicles.error info & ": Resuming session cancelled",
                error=($e.name & "(" & e.msg & ")")
              break recoverStates
            napAt = Moment.now() + threadSwitchRunLimit

      debug info & ": Download session restored",
        coverage=sdb.accountsCoverage.pcStr,
        archived=sdb.archivedCoverage.pcStr

      bodyRc = true
      break body

    # Any reset must take place outside the assembly DB iterator.
    chronicles.info info & ": Previous session abandoned"
    sdb.clear()                                     # flush/reset state DB
    if not adb.clear(info):                         # ditto for assembly DB
      raiseAssert info & ": Cannot clear session DB"

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
