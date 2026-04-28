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
  std/[sets, sequtils, strutils, typetraits],
  pkg/[chronicles, chronos, stew/interval_set],
  ../[helpers, mpt, state_db, worker_desc]

type
  MkTrieStatus = tuple
    stateInx: int
    nStates: int
    msgAt: Moment                                   # message while looping
    napAt: Moment                                   # allow for thread switch
    error: Opt[ErrorType]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toStr(pid: Hash): string =
  pid.toHex.toLowerAscii

template allowThreadSwitch(
    napAt: Moment;
    info: static[string];
      ): Opt[Moment] =
  var bodyRc: Opt[Moment] = Opt.some(napAt)
  block body:
    if napAt < Moment.now():
      try:
        await sleepAsync threadSwitchTimeSlot
      except CancelledError as e:
        chronicles.error info & ": Resuming session cancelled",
          error=($e.name & "(" & e.msg & ")")
        bodyRc = Opt.none(Moment)
        break body
      bodyRc = Opt.some(Moment.now() + threadSwitchRunLimit)
  bodyRc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template mkStoTrie(
    ctx: SnapCtxRef;
    wAcc: WalkAccounts;
    accInx: int;
    status: MkTrieStatus;
    info: static[string];
      ): MkTrieStatus =
  ## Async/template
  ##
  var bodyRc = status
  block body:
    let acc = wAcc.accounts[accInx]
    if acc.accBody.storageRoot.isEmpty:
      break body
    let
      adb = ctx.pool.mptAsm
      storageRoot = acc.accBody.storageRoot.to(StoreRoot)

      stateInx {.inject,used.} = status.stateInx    # logging only
      nStates {.inject,used.} = status.nStates      # logging only
      root {.inject,used.} = wAcc.root.toStr        # logging only
      accKey {.inject,used.} = acc.accHash.to(ItemKey).flStr
      stoRoot {.inject,used.} = storageRoot.toStr   # logging only
      peerID {.inject,used.} = wAcc.peerID.toStr    # logging only

    # Loop over storage slots for particular account
    for w in ctx.pool.mptAsm.walkStoSlot(wAcc.root, acc.accHash.to(ItemKey)):

      # Print keep alive messages and possible thread switch
      if bodyRc.msgAt < Moment.now():
        debug info & ": Processing storage slots..", stateInx, nStates, root,
          blockNumber, accKey, stoRoot, nSlot=w.slot.len
        bodyRc.msgAt = Moment.now() + threadLogTimeLimit
      bodyRc.napAt = bodyRc.napAt.allowThreadSwitch(info).valueOr:
        bodyRc.error = Opt.some(ECancelledError)
        break body

      let mpt = storageRoot.validate(w.start, w.slot, w.proof).valueOr:
        error info & ": slot validation failed", stateInx, nStates, peerID,
          root, blockNumber, accKey, stoRoot,
          iv=(w.start,w.limit).flStr, nSlot=w.slot.len,
          nProof=w.proof.len
        continue

      # Print keep alive messages and possible thread switch
      if bodyRc.msgAt < Moment.now():
        debug info & ": Processing storage slots..", stateInx, nStates, root,
          blockNumber, accKey, stoRoot, nSlot=w.slot.len
        bodyRc.msgAt = Moment.now() + threadLogTimeLimit
      bodyRc.napAt = bodyRc.napAt.allowThreadSwitch(info).valueOr:
        bodyRc.error = Opt.some(ECancelledError)
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
    status: MkTrieStatus;
    info: static[string];
      ): MkTrieStatus =
  ## Async/template
  ##
  var bodyRc = status
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

      # Print keep alive messages and possible thread switch
      if bodyRc.msgAt < Moment.now():
        debug info & ": Processing code lists ..", stateInx=status.stateInx,
          nStates=status.nStates, root, blockNumber
        bodyRc.msgAt = Moment.now() + threadLogTimeLimit
      bodyRc.napAt = bodyRc.napAt.allowThreadSwitch(info).valueOr:
        bodyRc.error = Opt.some(ECancelledError)
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
    status: MkTrieStatus;
    info: static[string];
      ): MkTrieStatus =
  ## Async/template
  ##
  ## Process accounts range. Validate raw packet and store it as a
  ## list of `(key,node)` pairs.
  ##
  ## The function returns `(xx,xx,Opt.none ErrorType)` if some accounts coud be
  ## re-queued,# successfully or not.
  ##
  var bodyRc = status
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
        nStates=status.nStates, peerID=wAcc.peerID.toStr, root, blockNumber,
        iv, nAccounts, nProof
      bodyRc.error = Opt.some(ETrieError)
      break body

    # Print keep alive messages and possible thread switch
    if bodyRc.msgAt < Moment.now():
      debug info & ": Processing accounts..", stateInx=status.stateInx,
        nStates=status.nStates, root, blockNumber, nAccounts, nProof
      bodyRc.msgAt = Moment.now() + threadLogTimeLimit
    bodyRc.napAt = bodyRc.napAt.allowThreadSwitch(info).valueOr:
      bodyRc.error = Opt.some(ECancelledError)
      break body

    # Store `(key,node)` list on trie
    let adb = ctx.pool.mptAsm
    adb.putAccTrie(mpt.kvPairs()).isOkOr:
      error info & ": Cannot store accounts on trie", stateInx=status.stateInx,
        nStates=status.nStates, peerID=wAcc.peerID.toStr, root, blockNumber,
        iv, nAccounts, nProof, `error`=error
      bodyRc.error = Opt.some(ETrieError)
      break body

    discard covered.merge(wAcc.start, wAcc.limit)   # completed range accounting

    # Process storage slots
    for n in 0 ..< wAcc.accounts.len:
      bodyRc = ctx.mkStoTrie(wAcc, n, bodyRc, info)

    # Process code list
    bodyRc = ctx.mkCodesList(wAcc.root, number, wAcc.accounts,  bodyRc, info)

    bodyRc.error = Opt.none(ErrorType)
    # End block `body`

  bodyRc
    
# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionMkTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Duration =
  ## Async/template
  ##
  var bodyRc = ZeroDuration
  block body:
    let
      adb = ctx.pool.mptAsm
    var
      start = Moment.now()
      status: MkTrieStatus
      pivot = StateRoot(zeroHash32)                 # max accounts range state
      pvNumber = BlockNumber(0)
      pvCoverage = low(UInt256)                     # for coverage maximising

    status.msgAt = Moment.now() + threadLogTimeLimit
    status.napAt = Moment.now() + threadSwitchRunLimit
    status.nStates = adb.walkStateData().toSeq().len

    chronicles.info info & ": Assembing MPT from archived data",
      nStates=status.nStates

    for p in adb.walkStateData():
      status.stateInx.inc
      status.error = Opt.none(ErrorType)

      if p.onTrie:
        trace info & ": State fully assembled, already",
          stateInx=status.stateInx, nStates=status.nStates,
          root=p.root.toStr, number=p.number
        continue

      # Walk account for the current state root
      let covered = ItemKeyRangeSet.init()          # collect account ranges
      for w in adb.walkAccounts(p.root):

        if 0 < w.error.len:
          debug info & ": Accounts walk error", stateInx=status.stateInx,
            nStates=status.nStates, root=p.root.toStr, number=p.number,
            error=w.error
          continue

        status = ctx.mkTrieImpl(w, p.number, covered, status, info)
        if status.error.isSome():                   # FIXME: bound to change
          break body

      # Find state with largest accounts coverage. For states with the same
      # maximal coverage, use the one related to the gratest block number.
      var covSize = covered.total()
      if covSize == 0 and                           # => range is `0` or `2^256
         0 < covered.chunks():                      # => `2^256`
        covSize = high(UInt256)                     # collapse with `2^256-1`
      if pvCoverage <= covSize or                   # maximise `pvCoverage`
         pvNumber == 0:                             # safe initialisation
        pivot = p.root
        pvNumber = p.number
        pvCoverage = covSize
      # End `for walkAccounts()`

      # Update
      if status.error.isNone():
        discard adb.putStateData(                 # Register updated trie
          p.root, p.hash, p.number, p.touch, onTrie=true, covSize)

      trace info & ": Done this state", stateInx=status.stateInx,
        nStates=status.nStates, root=p.root.toStr, number=p.number,
        elapsed=(Moment.now() - start).toStr

      # End `for walkStateData()`

    ctx.updateSyncHealing()
    bodyRc = Moment.now() - start

    debug info & ": Done all states", pivot=pivot.toStr, pvNumber,
      coverage=pvCoverage.flStr, nStates=status.nStates, elapsed=bodyRc.toStr
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
