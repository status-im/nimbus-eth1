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
  ../[helpers, mpt, state_db, worker_desc],
  ./session_helpers

logScope:
  topics = "snap sync"

type
  ResumeSession = object of SessionTicker
    ctx: SnapCtxRef
    db: MptAsmRef
    nStates: int                                    # total of available states
    stateInx: int                                   # index of current state
    state: StateDataRef                             # current state data
    elapsed: array[6,Duration]                      # collected times

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(
    w: var ResumeSession;
    ctx: SnapCtxRef;
    nStates: int;
      ) =
  procCall init(SessionTicker(w))                   # base method initialiser
  w.ctx = ctx
  w.db = ctx.pool.mptAsm
  w.nStates = nStates

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template storageRecover(
    session: ResumeSession;                         # used as var parameter
    acc: SnapAccount;
    info: static[string];
      ): Opt[void] =
  var bodyRc = Opt[void].err()
  block body:
    let storageRoot = acc.accBody.storageRoot
    if not storageRoot.isEmpty:
      let
        stoRoot = storageRoot.to(StoreRoot)
        accKey = acc.accHash.to(ItemKey)
        left = ItemKeyRangeSet.init ItemKeyRangeMax

      for w in session.db.walkStoSlot(session.state.stateRoot, accKey):
        discard left.reduce(w.start, w.limit)

        # Print keep alive messages and allow thread switch
        let rc = session.sessionTicker(info):
          debug info & ": Recovering states cache..",
            stateInx=session.stateInx, nStates=session.nStates,
            root=session.state.rootStr
        if rc.isSome():
          break body

      # Get the least point in the range it there is any. Unprocessed storage
      # was filled up consecutively with increasing min point entry.
      left.ge().isErrOr:
        session.state.register(
          accKey, stoRoot, ItemKeyRange.new(value.minPt, high(ItemKey)))
      # End `if storageRoot`

    bodyRc = typeof(bodyRc).ok()

  bodyRc

proc codesRecover(
    session: ResumeSession;
    lst: openArray[SnapAccount];
    info: static[string];
      ) =
  if 0 < lst.len:
    let
      accMin = lst[0].accHash.to(ItemKey)
      accMax = lst[^1].accHash.to(ItemKey)

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in session.db.walkByteCode(session.state.stateRoot, accMin):
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
        session.state.register(w.accHash.to(ItemKey), codeHash)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionResume*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  ## Async/template
  ##
  var bodyRc = Opt[void].err()
  block body:
    let
      sdb = ctx.pool.stateDB
      adb = ctx.pool.mptAsm
    var
      # Get list of sorted states available, the most recent ones first.
      byTouch = adb.walkStateData().toSeq()       # list to be sorted, below
      tchInx: seq[int]                            # index list into `byTouch`
      session = ResumeSession()                   # session environment
      intro = false                               # introductory message

    session.init(ctx, byTouch.len)                # init session environment

    # Sort states, order by latest time stamp first
    byTouch.sort proc(x,y: WalkStateData): int = cmp(y.touch,x.touch)

    # Walk over states, latest time stamp first. Collect the lastest some
    # non-empty states (see `stateDbCapacity`) for import into the state
    # DB cache.
    for n in 0 ..< byTouch.len:
      let p = byTouch[n]
      session.stateInx = n + 1                      # ranges `1`..`byTouch.len`

      if 0 < p.error.len:
        chronicles.info info & ": Bad state record ignored",
          stateInx=session.stateInx, nStates=session.nStates
        continue

      if p.coverage.isZero:
        continue

      if stateDbCapacity <= tchInx.len:             # index list complete?
        sdb.addAccountArchive p.coverage.per256()   # set archived coverage
        continue

      if not intro:                                 # print message once, only
        chronicles.info info & ": Resuming download session",
          nStates=session.nStates
        intro = true

      if p.tag != Untagged:                         # ignore assembled data
        sdb.addAccountArchive p.coverage.per256()   # set archived coverage
      else:
        tchInx.add n                                # collect, re-process below

    if tchInx.len == 0:                             # nothing to do?
      bodyRc = typeof(bodyRc).ok()                  # DB is ok
      break body

    # Loop over states with time stamp in oldest-first order. Processing in
    # that order, current time stamps (aka `Moment.now()`) can be used when
    # importing into the state DB cache. This way, the oldest-first order
    # will be preserved on the cache.
    session.nStates = tchInx.len
    for n in (tchInx.len - 1).countdown(0):
      let p = byTouch[tchInx[n]]
      session.stateInx = tchInx.len - n             # ranges `1`..`tchInx.len`

      # Create record on state DB cache
      session.state = sdb.register(p.root, p.hash, p.number, info)

      # Walk account for the current state root
      for w in adb.walkAccounts(p.root):
        if 0 < w.error.len:
          chronicles.info info & ": Bad accounts record ignored",
            error=w.error, root=session.state.rootStr
          continue

        # Print keep alive messages and allow thread switch
        let rc = session.sessionTicker(info):
          debug info & ": Recovering states cache..", stateInx=session.stateInx,
            nStates=session.nStates, root=session.state.rootStr
        if rc.isSome():
          break body                                # system termination?

        # Register seen accounts in state record
        sdb.setAccountRange(session.state, w.start, w.limit, Moment.now())

        # Register unprocessed storages per account
        for acc in w.accounts:
          session.storageRecover(acc, info).isOkOr:
            break body                              # system termination?

        # Register unprocessed codes for the current account list
        session.codesRecover(w.accounts, info)

    debug info & ": Download session restored",
      coverage=sdb.accountsCoverage.pcStr,
      archived=sdb.archivedCoverage.pcStr

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
