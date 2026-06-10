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
  pkg/[chronicles, chronos, metrics, stint],
  pkg/stew/[byteutils, interval_set],
  ../[helpers, mpt, state_db, worker_desc],
  ./[session_analyse, session_helpers]

declareGauge nec_snap_merged_mpt_coverage, "" &
  "Factor of accumulated account ranges covered when assembling MPT"

const
  UnconditionallyClearCache = false or true

type
  RecoveryStatus = enum
    NewAssembly
    PartiallyAssembled
    AllAssembled

  MkTrieSession = object of SessionTicker
    ctx: SnapCtxRef
    db: MptAsmRef

    nStates: int                                    # total of available states
    stateInx: int                                   # index of current state
    state: WalkStateData                            # current state data
    distance: uint64                                # distance to pivot state

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

proc mptTablesClear(ctx: SnapCtxRef, info: static[string]): Opt[void] =
  let db = ctx.pool.mptAsm
  db.clearAccKvt().isOkOr:
    error info & ": Cannot reset accounts MPT", `error`=error
    return err()
  db.clearStoKvt().isOkOr:
    error info & ": Cannot reset slots MPT", `error`=error
    return err()
  db.clearCodeKvt().isOkOr:
    error info & ": Cannot reset receipts table", `error`=error
    return err()
  ok()

func dist(a, b: WalkStateData): uint64 =
  ## Block number distance between two states.
  ##
  if a.number < b.number:
    b.number - a.number
  else:
    a.number - b.number

func isPivot(session: MkTrieSession): bool =
  session.stateInx == 0

func maxCoverage(w: openArray[WalkStateData]): WalkStateData =
  ## Get state with maximal coverage, either by label (from an earlier
  ## session) or by calculating it.
  ##
  for state in w:
    if state.error.len == 0:
      if state.tag == PivotOnTrie:
        return state                                # previously set, already
      if result.coverage < state.coverage:
        result = state

func getRecoveryStatus(w: openArray[WalkStateData]): RecoveryStatus =
  ## Check whether/how the cache structure needs to be cleaned up from a
  ## previos session.
  ##
  case w[0].tag:
  of Untagged:
    for n in 1 ..< w.len:
      if w[n].tag != Untagged:
        return PartiallyAssembled
    return NewAssembly                              # all tags `Untagged`
  of PivotOnTrie, PivotMptAnalysed:
    for n in 1 ..< w.len:
      if w[n].tag != OnTrie:
        return PartiallyAssembled
    return AllAssembled                             # partial MPT done
  of OnTrie:
    discard
  PartiallyAssembled

proc updateCoverageMetrics(session: var MkTrieSession) =
  discard session.fullCov.merge session.accRange    # completed ranges
  metrics.set(nec_snap_merged_mpt_coverage, session.fullCov.totalRatio)

# -----------

proc incompleteAccounts(
    session: MkTrieSession;
    accList: openArray[KppTriple];
      ): seq[KpPair] =
  var kpRc: seq[KpPair]
  for (key,path,pyl) in accList:
    block checkAccount:
      let a = pyl.decodeAccount().valueOr:
        break checkAccount

      if a.storageRoot != EMPTY_ROOT_HASH:
        let ok = session.db.hasStoKvt(path, a.storageRoot.data).valueOr:
          break checkAccount
        if not ok:
          break checkAccount

      if a.codeHash != EMPTY_CODE_HASH:
        let ok = session.db.hasCodeKvt(a.codeHash).valueOr:
          break checkAccount
        if not ok:
          break checkAccount
      continue                                      # all checks successful
    kpRc.add (key,@(path.data))                     # some check unsuccessful
    # End `for()`

  move kpRc

proc matchDnglAccLinks(
    session: MkTrieSession;
    keys: openArray[seq[byte]];
      ): Result[seq[seq[byte]],string] =
  ## Find all keys from the argument list `keys` that are also cached in the
  ## list of dangling links.
  ##
  var matches: seq[seq[byte]]
  for key in keys:
    let ok = session.db.hasAccDnglKvt(key).valueOr:
      return err(error)
    if ok:
      matches.add key
  ok(move matches)

proc updatehDnglAccLinks(
    session: MkTrieSession;
    resolved: openArray[seq[byte]];                 # remove from dngl cache
    incomplete: openArray[(seq[byte],seq[byte])];   # always store on dngl cache
    dangling: openArray[(seq[byte],seq[byte])];     # store when needed
      ): Result[uint,string] =
  ## Remove keys from argument `resolved` from the list of dangling links. And
  ## add  keys from argument `dangling` to the list of dangling links if they
  ## are not in the accounts KVT.
  ##
  ## The function returns the dangling links from the `dangling` argument
  ## that were already resolved.
  ##
  # Clear already `resolved` links
  session.db.delAccDnglKvt(resolved).isOkOr:
    return err(error)

  # Unconditionally store `incomplete` links
  for (key,path) in incomplete:
    session.db.putAccDnglKvt(key,path).isOkOr:
      return err(error)

  # Store `dangling` links if they are not on merged MPT cache
  var resolved = 0u
  for (key,path) in dangling:
    let ok = session.db.hasAccKvt(key).valueOr:
      return err(error)
    if ok:
      resolved.inc
    else:
      session.db.putAccDnglKvt(key,path).isOkOr:
        return err(error)

  ok(move resolved)

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
      session.db.putStoKvt(acc.accHash, mpt.knPairs()).isOkOr:
        error info & ": cannot store slot on trie", stateInx, nStates, root,
          distance, peerID, accKey, stoRoot, nProof=w.proof.len,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len, `error`=error
      # End `for()`

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

    # Match the validated partial accounts MPT against cache of dangling links
    # of the merged accounts MPT on disk. The result is a list of dangling
    # links that will be resolved by merging the validated package.
    let
      knPairs = mpt.knPairs()                       # list of `(key,node)` pairs
      matches = block:                              # resolved dngl link keys
        let rc = session.matchDnglAccLinks knPairs.mapIt(it[0])
        if rc.isErr:
          error info & ": Error accessing dangling links",
            stateInx, nStates, distance, root, error=rc.error
          # Stay, and import partial MPT
          seq[seq[byte]].default                    # empty key list
        elif rc.value.len == 0 and not session.isPivot:
          # Data package would not resolve any dangling links on pivot MPT
          break body                                # not doing anything
        else:
          rc.value

    # Merge `(key,node)` list on the accounts MPT on disk.
    session.db.putAccKvt(knPairs).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx, nStates, root,
        distance, peerID, nAccounts, nProof, iv, `error`=error
      bodyRc = Opt.some(ETrieError)
      break body

    if 0 < nAccounts:
      # Process storage slots
      for n in 0 ..< nAccounts:
        if not accData.accounts[n].accBody.storageRoot.isEmpty:
          session.mkStoTrie(n, info).isErrOr():
            if value == ECancelledError:            # check for shutdown..
              bodyRc = Opt.some(value)              # ..otherwise ignore for now
              break body

    # Some accounting for merged accounts ranges
    session.updateCoverageMetrics()                 # full coverage metrics

    # There is not much one can do with accounting errors, below
    bodyRc = Opt.none(ErrorType)                    # all clean so far

    # Collect lists of `(key,path)` pairs needed to update the dangling
    # links cache.
    let
      leafs = mpt.leafKpp()
      incomplete = session.incompleteAccounts(leafs)
      danglings = mpt.danglingKp()

    # Update cache of dangling links:
    # * remove links from `matches[]`
    # * add links from `incomplete[]` list of account leafs
    # * add links from `danglings[]` list if they are also dangling on the
    #   merged accounts MPT on disk
    session.updatehDnglAccLinks(matches, incomplete, danglings).isOkOr:
      error info & ": Error updating dangling links",
        stateInx, nStates, distance, root, `error`=error

    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionMkTrieInit*(ctx: SnapCtxRef) =
  # Reset metrics
  metrics.set(nec_snap_merged_mpt_coverage, 0f)

template sessionMkTrie*(ctx: SnapCtxRef; info: static[string]): auto =
  ## Async/template
  ##
  ## Build patial MPT by merging downloaded snap packets.
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
    template distance: auto = session.distance
    template accData: auto = session.accData
    template accRange: auto = session.accRange

    # Sort states by its distance from pivot, smallest distance first
    byDist.sort proc(x,y: WalkStateData): int = cmp(x.dist pivot,y.dist pivot)

    # FIXME -- begin (will go away) ------------------------------------------
    when UnconditionallyClearCache:
      byDist[0].tag = Untagged                      # => restart from scratch
    # FIXME -- end (will go away) --------------------------------------------

    # If necessary, update state data record pretending the cache is empty if
    # the pivot state tag has changed. Otherwise proceed with an interrupted
    # session with the `Untagged` states.
    #
    # Not implemented:
    #   One could use `sessionAnalyseAccounts()` for restoring the dangling
    #   links cache so that one can continue at an arbitrary state, referably
    #   the last one fully processed.
    #
    case byDist.getRecoveryStatus():
    of AllAssembled:
      ctx.pool.pivot = Opt.some(pivot.root)         # set pivot
      bodyRc = typeof(bodyRc).ok(ZeroDuration)
      break body
    of PartiallyAssembled:
      chronicles.info info & ": Clear MPT and dangling links", nStates
      ctx.pool.pivot = Opt.none(StateRoot)          # clear
      for n in 0 ..< byDist.len:
        byDist[n].tag = Untagged                    # reset all states
      discard ctx.mptTablesClear info               # rebuild MPT tables
      discard ctx.sessionAnalyseClear info          # ..
    of NewAssembly:
      ctx.pool.pivot = Opt.none(StateRoot)          # clear (if any)
      discard ctx.sessionAnalyseClear info

    chronicles.info info & ": Assembling MPT from archived data", nStates

    # Process states: pivot first, then states with increasing distances
    for n in 0 ..< nStates:
      state = byDist[n]                             # update descriptor fields
      stateInx = n                                  # ditto
      distance = state.dist(pivot)                  # ..

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

      debug info & ": Done this state", stateInx, nStates, root, distance,
        covered=session.fullCov.totalRatio.pcStr
      # End `for walkStateData()`

    let elapsed = Moment.now() - start
    bodyRc = typeof(bodyRc).ok(elapsed)

    chronicles.info info & ": Done all states", nStates, pivot=pivot.toStr,
      coverage=session.fullCov.totalRatio.pcStr, elapsed=elapsed.toStr

    # Publish pivot for MPT analysis and healing
    ctx.pool.pivot = Opt.some(pivot.root)
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
