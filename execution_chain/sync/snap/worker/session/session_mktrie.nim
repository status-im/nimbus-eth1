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
  std/sets,
  pkg/[chronicles, chronos, stew/interval_set],
  ../[helpers, mpt, state_db, worker_desc]

import
  ./debug

type
  MkTrieResult* = Result[Duration,SnapError]
    ## Shortcut

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mkStoTrie(
    ctx: SnapCtxRef;
    state: StateDataRef;
    acc: SnapAccount;
    info: static[string];
      ) =
  let storageRoot = acc.accBody.storageRoot
  if not storageRoot.isEmpty:
    let
      sdb = ctx.pool.stateDB
      adb = ctx.pool.mptAsm
      stoRoot = storageRoot.to(StoreRoot)
      accKey = acc.accHash.to(ItemKey)
      left = ItemKeyRangeSet.init ItemKeyRangeMax

    for w in ctx.pool.mptAsm.walkStoSlot(state.stateRoot, accKey):
      let mpt = stoRoot.validate(w.start, w.slot, w.proof).valueOr:
        debug info & ": slot validation failed", stoRoot=stoRoot.toStr,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len,
          nProof=w.proof.len, stateDB=sdb.toStr
        doAssert dumpStoFailFile.dumpToFile(        # FIXME -- will go away
          stoRoot, w.start, w.slot, w.proof)        # FIXME -- will go away
        continue

      # Store `(key,node)` list on trie
      adb.putStoTrie(mpt.pairs()).isOkOr:
        debug info & ": cannot store slot on trie", stoRoot=stoRoot.toStr,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len,
          nProof=w.proof.len,`error`=error, stateDB=sdb.toStr
        continue
      discard left.reduce(w.start, w.limit)

      adb.delStoSlot(state.stateRoot, accKey, w.start).isOkOr:
        debug info & ": error deleting packet", stoRoot=stoRoot.toStr,
          iv=(w.start,w.limit).to(float).toStr, nSlot=w.slot.len,
          nProof=w.proof.len,`error`=error, stateDB=sdb.toStr
        discard

    # Get the least point in the range it there is any. Unprocessed storage
    # was filled up linearly left to right (with increasing min point entry.)
    let iv = left.ge().valueOr:
      return
    state.register(accKey, stoRoot, ItemKeyRange.new(iv.minPt, high(ItemKey)))

proc mkCodesList(
    ctx: SnapCtxRef;
    state: StateDataRef;
    lst: openArray[SnapAccount];
    info: static[string];
      ) =
  if 0 < lst.len:
    let
      sdb = ctx.pool.stateDB
      adb = ctx.pool.mptAsm
      accMin = lst[0].accHash.to(ItemKey)
      accMax = lst[^1].accHash.to(ItemKey)

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in ctx.pool.mptAsm.walkByteCode(state.stateRoot, accMin):
      if accMax < w.limit:
        break
      var thisOneOk = true
      for (key,val) in w.codes:
        adb.putCodeList(key,val).isOkOr:
          debug info & ": cannot store slot on trie", root=state.rootStr,
            # key.toStr,
            # nData=val.to(seq[byte]).len,
            `error`=error,
            stateDB=sdb.toStr
          thisOneOk = false
          continue
        found.incl key
      if thisOneOk:
        discard adb.delByteCode(state.stateRoot, w.start)

    # Check for unprocessed byte codes
    for w in lst:
      let
        snapHash = w.accBody.codeHash
        codeHash = snapHash.to(CodeHash)
      if not snapHash.isEmpty and codeHash notin found:
        state.register(w.accHash.to(ItemKey), codeHash)

proc mkTrieImpl(
    ctx: SnapCtxRef;
    state: StateDataRef;
    start: ItemKey;
    limit: ItemKey;
    accounts: openArray[SnapAccount];
    proof: openArray[ProofNode];
    info: static[string];
      ) =
  ## Process accounts range. Validate raw packet and store it as a
  ## list of `(key,node)` pairs.
  ##
  ## The function returns `true` if some accounts coud be re-queued,
  ## successfully or not.
  ##
  let
    sdb = ctx.pool.stateDB
    adb = ctx.pool.mptAsm
    root = state.stateRoot

  block doAccList:
    block accListRollBack:
      # Validate packet
      let mpt = root.validate(start, accounts, proof).valueOr:
        debug info & ": accounts validation failed", root=root.toStr,
          iv=(start,limit).to(float).toStr, nAccounts=accounts.len,
          nProof=proof.len, stateDB=sdb.toStr
        doAssert dumpAccFailFile.dumpToFile(        # FIXME -- will go away
          root, start, accounts, proof)             # FIXME -- will go away
        break accListRollBack

      # Store `(key,node)` list on trie
      adb.putAccTrie(mpt.pairs()).isOkOr:
        debug info & ": cannot store accounts on trie", root=root.toStr,
          iv=(start,limit).to(float).toStr, nAccounts=accounts.len,
          nProof=proof.len,`error`=error, stateDB=sdb.toStr
        break accListRollBack

      # Process storage slots
      for acc in accounts:
        ctx.mkStoTrie(state, acc, info)

      # Process code list
      ctx.mkCodesList(state, accounts, info)

      break doAccList                               # done ok
      # End block: `accListRollBack`

    # Roll back/re-register unprocessed data
    sdb.setAccountRange(state, start, limit, low Moment) # re-add to state db
    # End block: `doAccList`

  # Delete accounts record
  adb.delAccounts(root, start).isOkOr:
    debug info & ": error deleting packet", root=root.toStr,
      iv=(start,limit).to(float).toStr, nAccounts=accounts.len,
      nProof=proof.len,`error`=error, stateDB=sdb.toStr
    discard

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionMkTrie*(
    ctx: SnapCtxRef;
    state: StateDataRef;
    info: static[string];
      ): MkTrieResult =
  ## Async/template
  ##
  var bodyRc = MkTrieResult.ok(chronos.nanoseconds(0))
  block body:
    var
      start = Moment.now()
      ela = chronos.nanoseconds(0)

    let
      adb = ctx.pool.mptAsm
      root = state.stateRoot

      sdb {.used.} = ctx.pool.stateDB               # logging only

    adb.putAccRoot(root, 0u8).isOkOr:
      const blurb = "cannot store state root"
      ela = Moment.now() - start
      error info & ": " & blurb, root=root.toStr, ela, stateDB=sdb.toStr
      bodyRc = MkTrieResult.err((ETrieError,"putAccRoot",blurb,ela))
      break body

    # Walk over `pivot` account ranges
    for w in adb.walkAccounts(root):
      if 0 < w.error.len:
        debug info & ": accounts walk error", root=root.toStr,
          stateDB=sdb.toStr
        continue

      ctx.mkTrieImpl(state, w.start, w.limit, w.accounts, w.proof, info)
      ela += Moment.now() - start

      try:
        await sleepAsync threadSwitchTimeSlot
      except CancelledError as e:
        bodyRc = MkTrieResult.err((ECancelledError,$e.name,e.msg,ela))
        break body

      start = Moment.now()

    state.setHealingReady()
    bodyRc = MkTrieResult.ok(ela)
    # End block `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
