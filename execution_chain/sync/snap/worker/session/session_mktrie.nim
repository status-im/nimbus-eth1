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
  pkg/[chronicles, chronos, stew/interval_set],
  ../[helpers, mpt, state_db, worker_desc],
  ./session_helpers

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template mkStoTrie(
    ctx: SnapCtxRef;
    wAcc: WalkAccounts;
    accInx: int;
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

      stateInx {.inject,used.} = status.stateInx    # logging only
      nStates {.inject,used.} = status.nStates      # logging only
      root {.inject,used.} = wAcc.root.toStr        # logging only
      accKey {.inject,used.} = acc.accHash.to(ItemKey).flStr
      stoRoot {.inject,used.} = storageRoot.toStr   # logging only
      peerID {.inject,used.} = wAcc.peerID.short    # logging only

    # Loop over storage slots for particular account
    for w in ctx.pool.mptAsm.walkStoSlot(wAcc.root, acc.accHash.to(ItemKey)):

      # Print keep alive messages and allow thread switch
      bodyRc = status.sessionTicker(info):
        debug info & ": Processing storage slots..", stateInx, nStates,
          root, blockNumber, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      let mpt = storageRoot.validate(w.start, w.slot, w.proof).valueOr:
        error info & ": slot validation failed", stateInx, nStates, peerID,
          root, blockNumber, accKey, stoRoot,
          iv=(w.start,w.limit).flStr, nSlot=w.slot.len,
          nProof=w.proof.len
        continue

      # Print keep alive messages and allow thread switch
      bodyRc = status.sessionTicker(info):
        debug info & ": Processing storage slots..", stateInx, nStates, root,
          blockNumber, accKey, stoRoot, nSlot=w.slot.len
      if bodyRc.isSome():
        break body

      # Store `(key,node)` list on trie
      adb.putStoTrie(mpt.kvPairs()).isOkOr:
        error info & ": cannot store slot on trie", stateInx, nStates,
          peerID, root, blockNumber, accKey, stoRoot,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len,
          nProof=w.proof.len, `error`=error

      # End `for()`

  bodyRc

template mkCodesList(
    ctx: SnapCtxRef;
    stateRoot: StateRoot;
    number: BlockNumber;
    lst: openArray[SnapAccount];
    status: SessionTicker;                          # used as var parameter
    info: static[string];
      ): Opt[ErrorType] =
  ## Async/template
  ##
  var bodyRc = Opt.none(ErrorType)
  block body:
    if lst.len == 0:
      break body
    let
      adb = ctx.pool.mptAsm
      accMin = lst[0].accHash.to(ItemKey)
      accMax = lst[^1].accHash.to(ItemKey)

      root {.inject,used.} = stateRoot.toStr        # logging only
      blockNumber {.inject,used.} = number          # logging only

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in ctx.pool.mptAsm.walkByteCode(stateRoot, accMin):
      if accMax < w.limit:
        break

      # Print keep alive messages and allow thread switch
      bodyRc = status.sessionTicker(info):
        debug info & ": Processing code lists ..", stateInx=status.stateInx,
          nStates=status.nStates, root, blockNumber
      if bodyRc.isSome():
        break body

      for (key,val) in w.codes:
        let hash = CodeHash(val.distinctBase.keccak256.data)
        if hash != key:
          error info & ": Code key mismatch", stateInx=status.stateInx,
            nStates=status.nStates, root, blockNumber, key=key.toStr,
            expected=hash.toStr, nData=val.to(seq[byte]).len
        adb.putCodeList(key,val).isOkOr:
          error info & ": Cannot store on DB code table",
            stateInx=status.stateInx, nStates=status.nStates, root,
            blockNumber, key=key.toStr, nData=val.to(seq[byte]).len,
            `error`=error
          continue
        found.incl key

  bodyRc

template mkTrieImpl(
    ctx: SnapCtxRef;
    wAcc: WalkAccounts;
    number: BlockNumber;
    covered: ItemKeyRangeSet;
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
      root {.inject,used.} = wAcc.root.toStr        # logging only
      blockNumber {.inject,used.} = number          # logging only
      nAccounts {.inject,used.} = wAcc.accounts.len # logging only
      nProof {.inject,used.} = wAcc.proof.len       # logging only
      iv {.inject,used.} = (wAcc.start,wAcc.limit).to(float).toStr

    # Validate packet, get a list of `(key,node)` pairs
    let mpt = wAcc.root.validate(wAcc.start, wAcc.accounts, wAcc.proof).valueOr:
      error info & ": Accounts validation failed", stateInx=status.stateInx,
        nStates=status.nStates, peerID=wAcc.peerID.short, root, blockNumber,
        iv, nAccounts, nProof
      bodyRc = Opt.some(ETrieError)
      break body

    # Print keep alive messages and allow thread switch
    bodyRc = status.sessionTicker(info):
      debug info & ": Processing accounts..", stateInx=status.stateInx,
        nStates=status.nStates, root, blockNumber, nAccounts, nProof
    if bodyRc.isSome():
      break body

    # Store `(key,node)` list on trie
    let adb = ctx.pool.mptAsm
    adb.putAccTrie(mpt.kvPairs()).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx=status.stateInx,
        nStates=status.nStates, peerID=wAcc.peerID.short, root, blockNumber,
        iv, nAccounts, nProof, `error`=error
      bodyRc = Opt.some(ETrieError)
      break body

    discard covered.merge(wAcc.start, wAcc.limit)   # completed range accounting

    # Process storage slots
    for n in 0 ..< wAcc.accounts.len:
      if not wAcc.accounts[n].accBody.storageRoot.isEmpty:
        ctx.mkStoTrie(wAcc, n, status, info).isErrOr():
          if value == ECancelledError:              # check for shutdown..
            bodyRc = Opt.some(value)                # ..otherwise ignore for now
            break body

    # Process code list
    ctx.mkCodesList(wAcc.root, number, wAcc.accounts,  status, info).isErrOr():
      if value == ECancelledError:                  # check for shutdown..
        bodyRc = Opt.some(value)                    # ..otherwise ignore for now
        break body

    bodyRc = Opt.none(ErrorType)
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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
      byCov = adb.walkStateData().toSeq()           # list to be sorted, below
      status = SessionTicker.init(byCov.len)        # for logging/thread switch

    chronicles.info info & ": Assembling MPT from archived data",
      nStates=status.nStates

    # Process states by its coverage size, greates first
    byCov.sort proc(x,y: WalkStateData): int = cmp(y.coverage,x.coverage)
    for n in 0 ..< byCov.len:
      let p = byCov[n]
      status.stateInx = n + 1                       # for logging

      if 0 < p.error.len:
        chronicles.info info & ": Bad state record ignored",
          stateInx=status.stateInx, nStates=status.nStates
        continue

      if p.onTrie:
        trace info & ": State fully assembled, already",
          stateInx=status.stateInx, nStates=status.nStates,
          root=p.root.toStr, number=p.number
        continue

      # Walk account for the current state root
      let covered = ItemKeyRangeSet.init()          # collect account ranges
      for w in adb.walkAccounts(p.root):

        if 0 < w.error.len:
          chronicles.info info & ": Bad accounts record ignored",
            stateInx=status.stateInx, nStates=status.nStates,
            root=p.root.toStr, number=p.number, error=w.error
          continue

        ctx.mkTrieImpl(w, p.number, covered, status, info).isErrOr:
          if value == ECancelledError:              # check for shutdown
            break body                              # otherwise ignore for now
        # End `for walkAccounts()`

      # Find state with largest accounts coverage. For states with the same
      # maximal coverage, use the one related to the gratest block number.
      byCov[n].coverage = covered.total()
      if byCov[n].coverage == 0 and                 # => range is `0` or `2^256
         0 < covered.chunks():                      # => `2^256`
        byCov[n].coverage = high(UInt256)           # collapse with `2^256-1`

      # Update
      discard adb.putStateData(                     # Register updated trie
        p.root, p.hash, p.number, p.touch, onTrie=true, byCov[n].coverage)

      trace info & ": Done this state", stateInx=status.stateInx,
        nStates=status.nStates, root=p.root.toStr, number=p.number,
        elapsed=(Moment.now() - start).toStr
      # End `for walkStateData()`

    ctx.updateSyncHealing()
    bodyRc = typeof(bodyRc).ok(Moment.now() - start)

    debug info & ": Done all states", pivot=byCov[0].root.toStr,
      pvNumber=byCov[0].number, coverage=byCov[0].coverage.flStr,
      nStates=status.nStates, elapsed=bodyRc.value.toStr
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
