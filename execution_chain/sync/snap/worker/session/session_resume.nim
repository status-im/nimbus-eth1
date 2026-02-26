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
  std/sets,
  pkg/[chronicles, stew/interval_set],
  ../../../wire_protocol,
  ../[mpt, state_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getOrMakeState(ctx: SnapCtxRef, root: StateRoot): Opt[StateDataRef] =
  let sdb = ctx.pool.stateDB
  sdb.get(root).isErrOr:
    return ok value
  let (hash,number) = ctx.pool.mptAsm.getBlockData(root).valueOr:
    return err()
  ok sdb.register(root, hash, number)

proc storageRecover(ctx: SnapCtxRef, state: StateDataRef, acc: SnapAccount) =
  let storageRoot = acc.accBody.storageRoot
  if not storageRoot.isEmpty:
    let
      stoRoot = storageRoot.to(StoreRoot)
      accKey = acc.accHash.to(ItemKey)
      left = ItemKeyRangeSet.init ItemKeyRangeMax

    for w in ctx.pool.mptAsm.walkRawStoSlot(state.stateRoot, accKey):
      discard left.reduce(w.start, w.limit)

    # Get the least point in the range it there is any. Unprocessed storage
    # was filled up linearly left to right (with increasing min point entry.)
    let iv = left.ge().valueOr:
      return
    state.register(accKey, stoRoot, ItemKeyRange.new(iv.minPt, high(ItemKey)))

proc codesRecover(ctx: SnapCtxRef, state: StateDataRef, lst: seq[SnapAccount]) =
  if 0 < lst.len:
    let
      accMin = lst[0].accHash.to(ItemKey)
      accMax = lst[^1].accHash.to(ItemKey)

    # Find all available `CodeHash` keys
    var found: HashSet[CodeHash]
    for w in ctx.pool.mptAsm.walkRawByteCode(state.stateRoot, accMin):
      if accMax < w.limit:
        break
      for (key,_) in w.codes:
        found.incl key

    # Check for unprocessed byte codes
    for w in lst:
      let codeHash = w.accBody.codeHash
      if not w.accBody.codeHash.isEmpty:
        if codeHash.to(CodeHash) notin found:
          state.register(w.accHash.to(ItemKey), codeHash.to(CodeHash))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionResumeDownload*(ctx: SnapCtxRef; info: static[string]): bool =
  let
    sdb = ctx.pool.stateDB
    adb = ctx.pool.mptAsm

  block recoverStates:
    var
      resumedOk = false
      ignRoot = StateRoot(zeroHash32)               # some error mitigation

    for w in adb.walkRawAccounts(): # WalkRawAccounts
      if 0 < w.error.len:
        error info & ": Corrupt data, resetting cache", error=w.error
        break recoverStates

      # Some failed state root records
      if ignRoot == w.root:
        continue

      # Get state record (with all accounts unprocessed when created)
      var state = ctx.getOrMakeState(w.root).valueOr:
        # Cannot resolve, ignore this state root
        ignRoot = w.root
        continue

      resumedOk = true

      # Register seen accounts in state record
      sdb.setAccountRange(state, w.start, w.limit)

      # Register unprocessed storages per account
      for acc in w.accounts:
        ctx.storageRecover(state, acc)

      # Register unprocessed codes for the current account list
      ctx.codesRecover(state, w.accounts)

    return resumedOk

  # Any reset must take place outside the assembly DB iterator.
  sdb.clear()                                       # flush/reset state DB
  if not adb.clear(info):                           # ditto for assembly DB
    raiseAssert info & ": Cannot clear cache DB"
  # false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
