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
  ../[helpers, mpt, state_db, worker_desc],
  ./session_helpers

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

    keys: HashSet[seq[byte]]                        # from pivot proofs
    nKeys: uint                                     # num mergend into `keys[]`

    accData: WalkAccounts                           # accounts range from cache
    accRange: ItemKeyRange                          # avoid repeated calculation

    elapsed: array[6,Duration]                      # collected times

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc init(
    w: var MkTrieSession;
    ctx: SnapCtxRef;
    nStates: int;
      ) =
  procCall init(SessionTicker(w))                   # base method initialiser
  w.ctx = ctx
  w.db = ctx.pool.mptAsm
  w.nStates = nStates

func toStr(state: WalkStateData): string =
  state.root.toStr & "(" & $state.number & ")"

func dist(a, b: WalkStateData): uint64 =
  ## Block number distance between two states.
  ##
  if a.number < b.number:
    b.number - a.number
  else:
    a.number - b.number

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

proc updateCoverage(cov: ItemKeyRangeSet; iv: ItemKeyRange) =
  discard cov.merge iv                              # completed ranges
  metrics.set(nec_snap_merged_mpt_coverage, cov.totalRatio)

# -------------------

template mkStoTrie(
    session: MkTrieSession;                         # used as var parameter
    accInx: int;                                    # inx of account to process
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    let
      acc = session.accData.accounts[accInx]
      storageRoot = acc.accBody.storageRoot.to(StoreRoot)

      stateInx {.inject,used.} = $session.stateInx  # logging only
      nStates {.inject,used.} = $session.nStates    # logging only
      distance {.inject,used} = $session.distance   # logging only
      root {.inject,used.} = session.state.toStr    # logging only
      accKey {.inject,used.} = acc.accHash.to(ItemKey).flStr
      stoRoot {.inject,used.} = storageRoot.toStr   # logging only
      peerID {.inject,used.} = session.accData.peerID.short

    # Loop over storage slots for particular account
    for w in session.db.walkStoSlot(
                             session.accData.root, acc.accHash.to(ItemKey)):

      # Print keep alive messages and allow thread switch
      bodyRc = session.sessionTicker(info):
        debug info & ": Processing storage slots..", stateInx, nStates, root,
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
        debug info & ": Processing storage slots..", stateInx, nStates, root,
          distance, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      # Store `(key,node)` list on trie
      session.db.putStoTrie(mpt.kvPairs()).isOkOr:
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
    let
      accMin = session.accData.accounts[0].accHash.to(ItemKey)
      accMax = session.accData.accounts[^1].accHash.to(ItemKey)

      stateInx {.inject,used.} = $session.stateInx  # logging only
      nStates {.inject,used.} = $session.nStates    # logging only
      distance {.inject,used} = $session.distance   # logging only
      root {.inject,used.} = session.state.toStr    # logging only

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in session.db.walkByteCode(session.accData.root, accMin):
      if accMax < w.limit:
        break

      # Print keep alive messages and allow thread switch
      bodyRc = session.sessionTicker(info):
        debug info & ": Processing code lists ..", stateInx, nStates, root,
          distance
      if bodyRc.isSome():
        break body

      for (key,val) in w.codes:
        let hash = CodeHash(val.distinctBase.keccak256.data)
        if hash != key:
          error info & ": Code key mismatch", stateInx, nStates, root,
            distance, key=key.toStr, expected=hash.toStr,
            nData=val.to(seq[byte]).len

        session.db.putCodeList(key,val).isOkOr:
          error info & ": Cannot store on DB code table", stateInx, nStates,
            root, distance, key=key.toStr, nData=val.to(seq[byte]).len,
            `error`=error
          continue
        found.incl key

  bodyRc

template mkTrieImpl(
    session: MkTrieSession;                         # used as var parameter
    cov: ItemKeyRangeSet;
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
    let
      stateInx {.inject,used.} = $session.stateInx  # logging only
      nStates {.inject,used.} = $session.nStates    # logging only
      distance {.inject,used} = $session.distance   # logging only
      root {.inject,used.} = session.state.toStr    # logging only
      peerID {.inject,used.} = session.accData.peerID.short
      nAccounts {.inject,used.} = session.accData.accounts.len
      nProof {.inject,used.} = session.accData.proof.len
      iv {.inject,used.} = session.accRange.flStr   # logging only

    # Validate packet, get a list of `(key,node)` pairs
    let mpt = session.accData.root.validate(
         session.accData.start, session.accData.accounts,
         session.accData.proof).valueOr:
      error info & ": Accounts validation failed", stateInx, nStates, root,
        distance, peerID, nAccounts, nProof, iv
      bodyRc = Opt.some(ETrieError)
      break body

    # Merge proof node keys for pivot state
    if session.stateInx == 1:                       # pivot state has index 1
      for w in mpt.proofKeys:
        session.nKeys.inc
        session.keys.incl w

    # Print keep alive messages and allow thread switch
    bodyRc = session.sessionTicker(info):
      debug info & ": Processing accounts..", stateInx, nStates, root,
        distance, nAccounts, nProof, covered=cov.totalRatio.pcStr
    if bodyRc.isSome():
      break body

    # Store `(key,node)` list on trie
    session.db.putAccTrie(mpt.kvPairs()).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx, nStates, root,
        distance, peerID, nAccounts, nProof, iv, `error`=error
      bodyRc = Opt.some(ETrieError)
      break body

    # Some accounting, register completed range
    cov.updateCoverage session.accRange

    # Process storage slots
    for n in 0 ..< session.accData.accounts.len:
      if not session.accData.accounts[n].accBody.storageRoot.isEmpty:
        session.mkStoTrie(n, info).isErrOr():
          if value == ECancelledError:              # check for shutdown..
            bodyRc = Opt.some(value)                # ..otherwise ignore for now
            break body

    # Process code list
    if 0 < session.accData.accounts.len:
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
    let
      start = Moment.now()
    var
      byDist = ctx.pool.mptAsm.walkStateData().toSeq()
      pivot = byDist.maxCoverage()                   # assign pivot state
      cov = ItemKeyRangeSet.init()                   # collect account ranges
      session = MkTrieSession()                      # session environment

      nStates {.inject.} = $byDist.len               # logging only

    chronicles.info info & ": Assembling MPT from archived data", nStates

    # Initialise session environment
    session.init(ctx, byDist.len)

    # Sort states by its distance from pivot, smallest distance first
    byDist.sort proc(x,y: WalkStateData): int = cmp(x.dist pivot,y.dist pivot)

    # Process states: pivot first, then states with increasing distances
    for n in 0 ..< byDist.len:
      session.state = byDist[n]                      # update descriptor
      session.stateInx = n + 1                       # ditto
      session.distance = session.state.dist(pivot)   # ..

      let
        stateInx {.inject,used.} = $session.stateInx # logging only
        distance {.inject,used} = $session.distance  # logging only
        root {.inject,used} = session.state.toStr    # logging only

      if 0 < session.state.error.len:
        chronicles.info info & ": Bad state record ignored", stateInx, nStates
        continue

      # Walk account for the current state root
      for accData in session.db.walkAccounts(session.state.root):
        session.accData = accData                   # update descriptor
        session.accRange = ItemKeyRange.new(        # ditto
          accData.start, accData.limit)             # ..

        if 0 < accData.error.len:
          chronicles.info info & ": Bad accounts record ignored",
            stateInx, nStates, root, distance, error=accData.error
          continue

        if session.state.tag != Untagged:
          cov.updateCoverage session.accRange       # completed range accounting
          continue

        # Check whether the account range was fully covered, already
        if cov.covered(session.accRange) == session.accRange.len:
          debug info & ": Accounts range fully covered, already", stateInx,
            nStates, root, distance, accRange=session.accRange.flStr
          continue

        session.mkTrieImpl(cov, info).isErrOr:
          if value == ECancelledError:              # check for shutdown
            break body                              # otherwise ignore for now
        # End `for walkAccounts()`

      if session.state.tag == Untagged:             # Register updated state
        session.state.tag = (if session.state==pivot: PivotOnTrie else: OnTrie)
        discard session.db.putStateData(session.state)

      trace info & ": Done this state", stateInx, nStates, root,
        distance, tag=session.state.tag,
        covered=cov.totalRatio.pcStr, elapsed=(Moment.now() - start).toStr
      # End `for walkStateData()`

    bodyRc = typeof(bodyRc).ok(Moment.now() - start)

    debug info & ": Done all states", nStates, pivot=pivot.toStr,
      coverage=cov.totalRatio.pcStr, elapsed=bodyRc.value.toStr
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
