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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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
  ## Get state with maximal coverage.
  ##
  ## Note that `NIM 2.2.10` provides a `max()` function with generic `cmp`
  ## argument that could be used, here. Cuurent `NIM` version is `2.2.4`.
  ##
  for state in w:
    if state.error.len == 0:
      if state.tag == PivotOnTrie:
        return state                                # previously set, already
      if result.coverage < state.coverage:
        result = state

# -------------------

template mkStoTrie(
    ctx: SnapCtxRef;
    state: WalkStateData;                           # used for logging, only
    wAcc: WalkAccounts;
    accInx: int;                                    # inx of account to process
    status: SessionTicker;                          # used as var parameter
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    let
      adb = ctx.pool.mptAsm
      acc = wAcc.accounts[accInx]
      storageRoot = acc.accBody.storageRoot.to(StoreRoot)

      stateInx {.inject,used.} = $status.stateInx   # logging only
      nStates {.inject,used.} = $status.nStates     # logging only
      distance {.inject,used} = $status.distance    # logging only
      root {.inject,used.} = state.toStr            # logging only
      accKey {.inject,used.} = acc.accHash.to(ItemKey).flStr
      stoRoot {.inject,used.} = storageRoot.toStr   # logging only
      peerID {.inject,used.} = wAcc.peerID.short    # logging only

    # Loop over storage slots for particular account
    for w in ctx.pool.mptAsm.walkStoSlot(wAcc.root, acc.accHash.to(ItemKey)):

      # Print keep alive messages and allow thread switch
      bodyRc = status.sessionTicker(info):
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
      bodyRc = status.sessionTicker(info):
        debug info & ": Processing storage slots..", stateInx, nStates, root,
          distance, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      # Store `(key,node)` list on trie
      adb.putStoTrie(mpt.kvPairs()).isOkOr:
        error info & ": cannot store slot on trie", stateInx, nStates, root,
          distance, peerID, accKey, stoRoot, nProof=w.proof.len,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len, `error`=error

      # End `for()`

  bodyRc

template mkCodesList(
    ctx: SnapCtxRef;
    state: WalkStateData;                           # used for logging, only
    wAcc: WalkAccounts;
    status: SessionTicker;                          # used as var parameter
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    let
      adb = ctx.pool.mptAsm
      accMin = wAcc.accounts[0].accHash.to(ItemKey)
      accMax =  wAcc.accounts[^1].accHash.to(ItemKey)

      stateInx {.inject,used.} = $status.stateInx   # logging only
      nStates {.inject,used.} = $status.nStates     # logging only
      distance {.inject,used} = $status.distance    # logging only
      root {.inject,used.} = state.toStr            # logging only

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in ctx.pool.mptAsm.walkByteCode(wAcc.root, accMin):
      if accMax < w.limit:
        break

      # Print keep alive messages and allow thread switch
      bodyRc = status.sessionTicker(info):
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
        adb.putCodeList(key,val).isOkOr:
          error info & ": Cannot store on DB code table", stateInx, nStates,
            root, distance, key=key.toStr, nData=val.to(seq[byte]).len,
            `error`=error
          continue
        found.incl key

  bodyRc

template mkTrieImpl(
    ctx: SnapCtxRef;
    state: WalkStateData;
    wAcc: WalkAccounts;
    cov: ItemKeyRangeSet;
    status: SessionTicker;                          # used as var parameter
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
      stateInx {.inject,used.} = $status.stateInx   # logging only
      nStates {.inject,used.} = $status.nStates     # logging only
      distance {.inject,used} = $status.distance    # logging only
      root {.inject,used.} = state.toStr            # logging only
      nAccounts {.inject,used.} = wAcc.accounts.len # logging only
      nProof {.inject,used.} = wAcc.proof.len       # logging only
      iv {.inject,used.} = (wAcc.start,wAcc.limit).to(float).toStr

    # Validate packet, get a list of `(key,node)` pairs
    let mpt = wAcc.root.validate(wAcc.start, wAcc.accounts, wAcc.proof).valueOr:
      error info & ": Accounts validation failed", stateInx, nStates, root,
        distance, peerID=wAcc.peerID.short, iv, nAccounts, nProof
      bodyRc = Opt.some(ETrieError)
      break body

    # Print keep alive messages and allow thread switch
    bodyRc = status.sessionTicker(info):
      debug info & ": Processing accounts..", stateInx, nStates, root,
        distance, nAccounts, nProof, covered=cov.totalRatio.pcStr
    if bodyRc.isSome():
      break body

    # Store `(key,node)` list on trie
    let adb = ctx.pool.mptAsm
    adb.putAccTrie(mpt.kvPairs()).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx, nStates, root,
        distance, peerID=wAcc.peerID.short, iv, nAccounts, nProof, `error`=error
      bodyRc = Opt.some(ETrieError)
      break body

    discard cov.merge(wAcc.start, wAcc.limit)       # completed range accounting

    # Update metrics
    metrics.set(nec_snap_merged_mpt_coverage, cov.totalRatio)

    # Process storage slots
    for n in 0 ..< wAcc.accounts.len:
      if not wAcc.accounts[n].accBody.storageRoot.isEmpty:
        ctx.mkStoTrie(state, wAcc, n, status, info).isErrOr():
          if value == ECancelledError:              # check for shutdown..
            bodyRc = Opt.some(value)                # ..otherwise ignore for now
            break body

    # Process code list
    if 0 < wAcc.accounts.len:
      ctx.mkCodesList(state, wAcc, status, info).isErrOr():
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
      adb = ctx.pool.mptAsm
      start = Moment.now()
    var
      byDist = adb.walkStateData().toSeq()           # list to be sorted, below
      pivot = byDist.maxCoverage()                   # assign pivot state
      cov = ItemKeyRangeSet.init()                   # collect account ranges
      status = SessionTicker.init(byDist.len)        # for logging/thread switch

      nStates {.inject.} = $status.nStates           # logging only

    chronicles.info info & ": Assembling MPT from archived data", nStates

    # Sort states by its distance from pivot, smallest distance first
    byDist.sort proc(x,y: WalkStateData): int = cmp(x.dist pivot,y.dist pivot)

    # Process states: pivot first, then states with increasing distances
    for n in 0 ..< byDist.len:
      let p = byDist[n]
      status.stateInx = n + 1                       # for logging
      status.distance = p.dist(pivot)               # for logging

      let
        stateInx {.inject,used.} = $status.stateInx # logging only
        distance {.inject,used} = $status.distance  # logging only
        root {.inject,used} = p.toStr               # logging only

      if 0 < p.error.len:
        chronicles.info info & ": Bad state record ignored", stateInx, nStates
        continue

      if p.tag != Untagged:
        trace info & ": State processed, already", stateInx, nStates, root,
          distance, tag=p.tag
        continue

      # Walk account for the current state root
      for w in adb.walkAccounts(p.root):

        if 0 < w.error.len:
          chronicles.info info & ": Bad accounts record ignored",
            stateInx, nStates, root, distance, error=w.error
          continue

        # Check whether the account range was fully covered, already
        if cov.covered(w.start, w.limit) == w.limit - w.start + 1:
          debug info & ": Accounts range fully covered, already",
            stateInx, nStates, root, distance,
            nAccounts=(w.limit - w.start + 1).per256.pcStr
          continue

        ctx.mkTrieImpl(p, w, cov, status, info).isErrOr:
          if value == ECancelledError:              # check for shutdown
            break body                              # otherwise ignore for now
        # End `for walkAccounts()`

      let tag = (if p == pivot: PivotOnTrie else: OnTrie)
      discard adb.putStateData(                     # Register updated state
        p.root, p.hash, p.number, p.touch, tag, p.coverage)

      trace info & ": Done this state", stateInx, nStates, root,
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
