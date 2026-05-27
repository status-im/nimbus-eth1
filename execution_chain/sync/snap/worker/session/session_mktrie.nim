# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sets, sequtils, typetraits],
  pkg/[chronicles, chronos, metrics, stew/interval_set, stint],
  pkg/stew/byteutils,
  ../[helpers, mpt, state_db, worker_desc],
  ./[session_analyse, session_helpers]

declareGauge nec_snap_merged_mpt_coverage, "" &
  "Factor of accumulated account ranges covered when assembling MPT"

type
  MkTrieSession = object of SessionTicker
    ctx: SnapCtxRef
    db: MptAsmRef

    nStates: int                                    # total of available states
    stateInx: int                                   # index of current state
    state: WalkStateData                            # current state data
    distance: uint64                                # distance to pivot state
    mergedOk: bool                                  # per state, merged accounts

    accData: WalkAccounts                           # accounts range from cache
    accRange: ItemKeyRange                          # avoid repeated calculation

    fullCov: ItemKeyRangeSet                        # collect all ranges

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toStr(state: WalkStateData): string =
  state.root.toStr & "(" & $state.number & ")"

# -----------

proc init(
    w: var MkTrieSession;
    ctx: SnapCtxRef;
    nStates: int;
      ) =
  procCall init(SessionTicker(w))                   # base method initialiser
  w.ctx = ctx
  w.db = ctx.pool.mptAsm
  w.nStates = nStates
  w.fullCov = ItemKeyRangeSet.init()

func dist(a, b: WalkStateData): uint64 =
  ## Block number distance between two states.
  ##
  if a.number < b.number:
    b.number - a.number
  else:
    a.number - b.number

func isPivot(session: MkTrieSession): bool =
  session.stateInx == 0

func maxCoverage(w: seq[WalkStateData]): WalkStateData =
  ## Get state with maximal coverage, either by label (from an earlier
  ## session) or by calculating it.
  ##
  for state in w:
    if state.error.len == 0:
      if state.tag == PivotOnTrie:
        return state                                # previously set, already
      if result.coverage < state.coverage:
        result = state

proc updateCoverageMetrics(session: var MkTrieSession) =
  discard session.fullCov.merge session.accRange    # completed ranges
  metrics.set(nec_snap_merged_mpt_coverage, session.fullCov.totalRatio)

# -----------

proc matchDanglingLink(
    session: MkTrieSession;
    keys: openArray[seq[byte]];
      ): Result[bool,string] =
  ## Find all keys from the argument list `keys` that are also cached in the
  ## list of dangling links.
  ##
  for w in keys:
    let ok = session.db.hasAccDnglKvt(w).valueOr:
      return err(error)
    if ok:
      return ok(true)
  ok(false)

template updateDanglingPivotLinks(
    session: MkTrieSession;
    info: static[string];
      ): auto =
  ## Async template
  ##
  var bodyRc = Result[void,int].err(0)
  block body:
    session.ctx.sessionAnalyseAccounts(info).isOkOr:
      bodyRc = typeof(bodyRc).err((error[1]))
      break body
    bodyRc = typeof(bodyRc).ok()
  bodyRc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template mkStoTrie(
    session: MkTrieSession;                         # used as var parameter
    accInx: int;                                    # inx of account to process
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    # Some shortcuts
    template state: auto = session.state
    template stateInx: auto = session.stateInx
    template nStates: auto = session.nStates
    template distance: auto = session.distance
    template accData: auto = session.accData

    let
      acc = accData.accounts[accInx]
      storageRoot = acc.accBody.storageRoot.to(StoreRoot)

      root {.inject,used.} = state.toStr            # logging only
      accKey {.inject,used.} = acc.accHash.to(ItemKey).flStr
      stoRoot {.inject,used.} = storageRoot.toStr   # logging only
      peerID {.inject,used.} = accData.peerID.short # logging only

    # Loop over storage slots for particular account
    for w in session.db.walkStoSlot(accData.root, acc.accHash.to(ItemKey)):

      # Print keep alive messages and allow thread switch
      bodyRc = session.sessionTicker(info):
        trace info & ": Processing storage slots..", stateInx, nStates, root,
          distance, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      let mpt = storageRoot.validate(w.start, w.slot, w.proof).valueOr:
        error info & ": slot validation failed", stateInx, nStates, root,
          distance, peerID, accKey, stoRoot, iv=(w.start,w.limit).flStr,
          nSlot=w.slot.len, nProof=w.proof.len
        continue

      # Print keep alive messages and allow thread switch
      bodyRc = session.sessionTicker(info):
        trace info & ": Processing storage slots..", stateInx, nStates, root,
          distance, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      # Store `(key,node)` list on trie
      session.db.putStoKvt(mpt.kvPairs()).isOkOr:
        error info & ": cannot store slot on trie", stateInx, nStates, root,
          distance, peerID, accKey, stoRoot, nProof=w.proof.len,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len, `error`=error

      # End `for()`

  bodyRc

template mkCodesList(
    session: MkTrieSession;                         # used as var parameter
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    # Some shortcuts
    template state: auto = session.state
    template stateInx: auto = session.stateInx
    template nStates: auto = session.nStates
    template distance: auto = session.distance
    template accData: auto = session.accData

    let
      accMin = accData.accounts[0].accHash.to(ItemKey)
      accMax = accData.accounts[^1].accHash.to(ItemKey)

      root {.inject,used.} = state.toStr            # logging only

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in session.db.walkByteCode(session.accData.root, accMin):
      if accMax < w.limit:
        break

      # Print keep alive messages and allow thread switch
      bodyRc = session.sessionTicker(info):
        trace info & ": Processing code lists ..", stateInx, nStates, root,
          distance
      if bodyRc.isSome():
        break body

      for (key,val) in w.codes:
        let hash = CodeHash(val.distinctBase.keccak256.data)
        if hash != key:
          error info & ": Code key mismatch", stateInx, nStates, root,
            distance, key=key.toStr, expected=hash.toStr,
            nData=val.to(seq[byte]).len

        session.db.putCodeKvt(key,val).isOkOr:
          error info & ": Cannot store on DB code table", stateInx, nStates,
            root, distance, key=key.toStr, nData=val.to(seq[byte]).len,
            `error`=error
          continue
        found.incl key

  bodyRc

template mkTrieImpl(
    session: MkTrieSession;                         # used as var parameter
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  ## Process accounts range. Validate raw packet and store it as a
  ## list of `(key,node)` pairs.
  ##
  ## The function returns `(xx,xx,Opt.none ErrorType)` if some accounts coud be
  ## re-queued,# successfully or not.
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    # Some shortcuts
    template state: auto = session.state
    template stateInx: auto = session.stateInx
    template nStates: auto = session.nStates
    template mergedOk: auto = session.mergedOk
    template distance: auto = session.distance
    template accData: auto = session.accData
    template accRange: auto = session.accRange
    template nAccounts: auto = accData.accounts.len
    template nProof: auto = accData.proof.len

    var
      start = Moment.now()
    let
      root {.inject,used.} = state.toStr            # logging only
      peerID {.inject,used.} = accData.peerID.short # logging only
      iv {.inject,used.} = accRange.flStr           # logging only

    # Validate packet, prepare for `(key,node)` extraction
    let mpt = session.accData.root.validate(
         accData.start, accData.accounts, accData.proof).valueOr:
      error info & ": Accounts validation failed", stateInx, nStates, root,
        distance, peerID, nAccounts, nProof, iv
      bodyRc = Opt.some(ETrieError)
      break body

    # Print keep alive messages and allow thread switch
    bodyRc = session.sessionTicker(info):
      trace info & ": Processing accounts..", stateInx, nStates, root,
        distance, nAccounts, nProof, covered=session.fullCov.totalRatio.pcStr
    if bodyRc.isSome():
      break body

    start = Moment.now()

    # Check whether the `dangling[]` cache is up to date. If so, then
    # check current MPT accounts package against current dangling cache.
    let kvPairs = mpt.kvPairs()
    if not session.isPivot:
      let rc = session.matchDanglingLink kvPairs.mapIt(it[0])
      if rc.isErr:
        chronicles.`error` info & ": Error accessing dangling pivot links",
          stateInx, nStates, distance, root, error=rc.error
        # Stay, and import partial MPT
      elif not rc.value:
        # Data package would not resolve any dangling links
        break body                                  # not doing anything

    # Store `(key,node)` list on trie
    session.db.putAccKvt(kvPairs).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx, nStates, root,
        distance, peerID, nAccounts, nProof, iv, `error`=error
      bodyRc = Opt.some(ETrieError)
      break body

    # Some accounting for merged accounts ranges
    mergedOk = true                                 # mark current state used
    session.updateCoverageMetrics()                 # full coverage metrics

    if 0 < nAccounts:
      # Process storage slots
      for n in 0 ..< nAccounts:
        if not accData.accounts[n].accBody.storageRoot.isEmpty:
          session.mkStoTrie(n, info).isErrOr():
            if value == ECancelledError:            # check for shutdown..
              bodyRc = Opt.some(value)              # ..otherwise ignore for now
              break body

      # Process code list
      session.mkCodesList(info).isErrOr():
        if value == ECancelledError:                # check for shutdown..
          bodyRc = Opt.some(value)                  # ..otherwise ignore for now
          break body

    bodyRc = Opt.none(ErrorType)
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionMkTrieInit*( ctx: SnapCtxRef) =
  # Reset metrics
  metrics.set(nec_snap_merged_mpt_coverage, 0f)

template sessionMkTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[Duration] =
  ## Async/template
  ##
  var bodyRc = Opt[Duration].err()
  block body:
    var
      byDist = ctx.pool.mptAsm.walkStateData().toSeq()
      session = MkTrieSession()                      # session environment
    let
      pivot = byDist.maxCoverage()                   # assign pivot state
      start = Moment.now()

    if byDist.len == 0:
      chronicles.info info & ": No states to assemble MPT from"
      bodyRc = typeof(bodyRc).ok(ZeroDuration)
      break body

    # Initialise session environment
    session.init(ctx, byDist.len)

    # Some shortcuts
    template state: auto = session.state
    template stateInx: auto = session.stateInx
    template nStates: auto = session.nStates
    template mergedOk: auto = session.mergedOk
    template distance: auto = session.distance
    template accData: auto = session.accData
    template accRange: auto = session.accRange

    chronicles.info info & ": Assembling MPT from archived data", nStates

    # Sort states by its distance from pivot, smallest distance first
    byDist.sort proc(x,y: WalkStateData): int = cmp(x.dist pivot,y.dist pivot)

    # Reset MPT data cache if download sample tagging has changed
    if byDist[0].tag != PivotOnTrie:
      if byDist[0].tag != Untagged:                 # job might take some time
        chronicles.info info & ": Clearing state accounts cache", nStates
      for n in 0 ..< byDist.len:
        byDist[n].tag = Untagged

    # Process states: pivot first, then states with increasing distances
    for n in 0 ..< nStates:
      state = byDist[n]                             # update descriptor fields
      stateInx = n                                  # ditto
      mergedOk = false                              # ..
      distance = state.dist(pivot)

      if 0 < state.error.len:
        chronicles.info info & ": Bad state record ignored", stateInx, nStates
        continue

      let root {.inject,used} = state.toStr         # logging only

      # Walk account for the current state root
      for w in session.db.walkAccounts(state.root):
        accData = w                                 # update descriptor fields
        accRange = ItemKeyRange.new(w.start, w.limit)

        if 0 < accData.error.len:
          chronicles.info info & ": Bad accounts record ignored",
            stateInx, nStates, root, distance, error=accData.error
          continue

        # Check for recovery of an interrupted previous session
        if state.tag != Untagged:
          session.updateCoverageMetrics()           # full coverage metrics
          continue

        session.mkTrieImpl(info).isErrOr:
          if value == ECancelledError:              # check for shutdown
            break body                              # otherwise ignore for now
        # End `for walkAccounts()`

      if state.tag == Untagged:                     # Register updated state
        state.tag = (if session.isPivot: PivotOnTrie else: OnTrie)
        discard session.db.putStateData(state)

      if stateInx < nStates-1 and mergedOk:         # did something at all?
        session.updateDanglingPivotLinks(info).isOkOr:
          error info & ": Accounts dangling links for pivot failed",
            stateInx, nStates, root, nErrors=error
          break body                                # makes no sense to proceed

      debug info & ": Done this state", stateInx, nStates, root, distance,
        tag=state.tag, covered=session.fullCov.totalRatio.pcStr, mergedOk
      # End `for walkStateData()`

    let elapsed = Moment.now() - start
    bodyRc = typeof(bodyRc).ok(elapsed)

    chronicles.info info & ": Done all states", nStates, pivot=pivot.toStr,
      coverage=session.fullCov.totalRatio.pcStr, elapsed=elapsed.toStr
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
