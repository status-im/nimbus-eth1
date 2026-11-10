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
  std/[sequtils, sets],
  pkg/[chronicles, chronos, eth/common],
  pkg/stew/[byteutils, interval_set],
  ./[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template applySlotChanges(
    adb: CacheDbRef;
    accPath: Hash32;
    slots: seq[SlotChanges];
    stoMiss: Opt[CacheStoMissingIntvData];
    timer: TimerDataRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Apply BAL to storage slots. Partially downloaded MPTs are updated within
  ## the range of covered/downloaded intervals.
  ##
  var bodyRc = Opt[void].err()
  block body:
    stoMiss.isErrOr:
      if stoMiss.unsafeGet().ranges.isFullRange():
        bodyRc = typeof(bodyRc).ok()
        break body

    for w in slots:
      if w.changes.len == 0:
        continue

      # Check whether the slot key is in the unprocessed ranges.
      let slotKey = w.slot.computeSlotKey()
      stoMiss.isErrOr():
        if value.ranges.covered slotKey.to(ItemKey):
          # Well, it is. Not updating, will be downloaded at a later stage
          continue

      let slotValue = w.changes[^1].newValue
      if slotValue == 0:
        adb.delFlatSlot(accPath, slotKey, info).isOkOr:
          break body                                # err()
      else:
        adb.putFlatSlot(accPath, slotKey, slotValue, info).isOkOr:
          break body                                # err()
      timer.yieldThread()

    bodyRc = typeof(bodyRc).ok()
    # End `block body`
  bodyRc

template applyCodeChange(
    adb: CacheDbRef;
    accPath: Hash32;
    code: openArray[CodeChange];
    info: static[string];
      ): auto =
  ## Apply BAL to contract code
  ##
  ## Returns `true` if a contract code was added or updated.
  ##
  var bodyRc = Opt[bool].err()
  block body:
    doAssert 0 < code.len
    let newCode = code[^1].newCode

    if newCode.len == 0:
      adb.delFlatCode(accPath, info).isOkOr:
        break body                                  # err()
      adb.delMissingBlob(accPath, info).isOkOr:     # no more missing (if any)
        break body
      bodyRc = typeof(bodyRc).ok(false)             # deleted
      break body

    adb.putFlatCode(accPath, newCode, info).isOkOr:
      break body
    adb.delMissingBlob(accPath, info).isOkOr:       # no more missing (if any)
      break body

    bodyRc = typeof(bodyRc).ok(true)
    # End `block body`
  bodyRc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template applyAccChanges(
    ctx: SnapCtxRef;
    chng: AccountChanges;
    timer: TimerDataRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Apply BAL to account, returns `true` if the storage root was reset to
  ## zero. In that case, the accounts record must be reloaded and updated
  ## later in the state download phase.
  ##
  var bodyRc = Opt[bool].err()
  block body:
    let
      adb = ctx.pool.cacheDB
      accPath = chng.address.computeAccPath
      accMiss = adb.getAccMissingIntv(info).valueOr:
        break body                                  # failed

      # Fetch account data record (might not exisit.)
      maybeAcc = adb.getFlatAcc(accPath).valueOr:
        error info & ": Failed to fetch account", accPath=accPath.toStr,
          `error`=error
        break body                                  # failed

    # Get or create and account record to be modified.
    var
      resetHashOk = false                           # storageRoot or codeHash
      acc = maybeAcc.valueOr:
        # If this account record does not exists yet and is to be fetched
        # in the next download round, then there is nothing to do, here.
        if accMiss.ranges.covered(accPath.to(ItemKey)):
          bodyRc = typeof(bodyRc).ok(false)
          break body                                # ignore for now
        # A new account will be created and silently added if it is not in
        # the range of accounts to be fetched.
        emptyFlatAccData                            # new account

    timer.yieldThread()

    # Apply BAL storage change list to storage sub-MPT
    if 0 < chng.storageChanges.len:
      let stoMiss = adb.getStoMissingIntv(accPath, info).valueOr:
        break body                                  # err()
      adb.applySlotChanges(
             accPath, chng.storageChanges, stoMiss, timer, info).isOkOr:
        break body                                  # failed

      acc.account.storageRoot = zeroHash32          # no sto. root known anymore
      if stoMiss.isSome():
        # For a partial sub-MPT, an account update is needed to complete it,
        # because the `storageRoot` has become unavailable for the current
        # pivot state.
        resetHashOk = true                         # req state download resolve
      else:
        # No need to force an account update. If the `zeroHash32` survives
        # until core DB assembly, the `storageRoot` will be assembled from
        # scratch.
        discard

        # Note, that for debugging purposes, an account update can be forced
        # by setting `resetHashOk = true`, So all storage sub-MPTs will come
        # with corresponding `storageRoot` set for  core DB assembly.

    # Apply BAL contract code change list
    if 0 < chng.codeChanges.len:
      let updatesOk =
        adb.applyCodeChange(accPath, chng.codeChanges, info).valueOr:
          break body
      if updatesOk:
        # No need to force an account update. If the `zeroHash32` survives
        # until core DB assembly, the `codeHash` will be assembled from
        # scratch.
        acc.account.codeHash = zeroHash32

        # Note, that for debugging purposes, an account update can be forced
        # by setting `resetHashOk = true`. So all contract codes will come
        # with corresponding `codeHash` set for  core DB assembly.
      else:
        acc.account.codeHash = EMPTY_CODE_HASH

    # Apply other BAL change lists to the account sub-entries.
    if 0 < chng.nonceChanges.len:
      acc.account.nonce = chng.nonceChanges[^1].newNonce

    if 0 < chng.balanceChanges.len:
      acc.account.balance = chng.balanceChanges[^1].postBalance

    # Don't create empty accounts in flat state, see EIP-161.
    # (ackn: Geth bal_apply.go:275.)
    if acc.account.nonce == default(AccountNonce) and
       acc.account.balance == default(UInt256) and
       acc.account.codeHash == EMPTY_CODE_HASH:

      if maybeAcc.isSome():
        # Existing account got fully drained (e.g., pre-funded address that
        # gets deployed to with init code that self-destructs). Delete the
        # entry so the trie generation doesn't pick it up as an empty leaf
        # (ackn: Geth bal_apply.go:283.)
        let storageRoot = acc.account.storageRoot
        if storageRoot != EMPTY_ROOT_HASH:
          # The storage wiping shouldn't occur since the EIP-6780. Moan
          # loudly if it happens (ackn: Geth bal_apply.go:292.)
          warn info & ": Drained account, storage root not empty",
            accPath=accPath.toStr, stoRoot=storageRoot.toStr
          adb.delStoMissingIntv(accPath, info).isOkOr: # del storage accounting
            break body
          adb.clearFlatSlot(accPath, info).isOkOr:  # delete all storage slots
            break body
        else:
          debug info & ": Drained account", accPath=accPath.toStr

        adb.delFlatAcc(accPath, info).isOkOr:       # remove account record
          break body
        discard accMiss.ranges.merge(accPath.to(ItemKey))
        adb.putAccMissingIntv(accMiss, info).isOkOr: # update on cache DB
          break body

      else:
        # If this was a new account. This clause covers cases where the account
        # is created and destroyed within the same transaction, or where its
        # net state change across the block is zero. The empty->empty transition
        # should be excluded from account update (ackn: Geth bal_apply.go:279.)

        if 0 < chng.storageChanges.len:
          # Make sure that the cache is clean. So subsequent usage of the
          # same account is not pre-loaded with rubbish.
          debug info & ": Drained account slots", accPath=accPath.toStr
          adb.clearFlatSlot(accPath, info).isOkOr:  # delete all account slots
            break body

      bodyRc = typeof(bodyRc).ok(false)             # nothing to do
      break body

    adb.putFlatAcc(accPath, acc, info).isOkOr:      # persist account record
      break body                                    # failed

    bodyRc = typeof(bodyRc).ok(resetHashOk)
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template stateForward*(
    ctx: SnapCtxRef;
    info: static[string];
    nBalsMax = high(uint);
      ): auto =
  ## Async template
  ##
  ## Apply stored BALs to the downloaded flat account and storage tables.
  ##
  ## The maximal number of BAs to apply can be passed as argument `nBalsMax`.
  ## In that case, the function can be called repeatedly until the BALs
  ## are exhausted. The latter can be detected if the return value stays
  ## the same.
  ##
  var bodyRc = Opt[seq[Address]].err()
  block body:
    let
      adb = ctx.pool.cacheDB
      accState = adb.getAccMissingIntv(info).valueOr:
        break body                                  # failed
      pivotNum = accState.number

    var
      changed: HashSet[Address]
      number = pivotNum
      timer = TimerDataRef(time: Moment.now())
    template dist: untyped = (number-pivotNum)

    while true:
      if nBalsMax <= dist:
        chronicles.info info & ": Some BALs applied",
          pivot=pivotNum, newState=number, dist
        break
      number.inc
      let bal = adb.getBal(number, info).valueOr:
        number.dec
        chronicles.info info & ": New pivot state after BALs applied",
          pivot=pivotNum, newState=number, dist
        break

      for w in bal[]:
        let changedOk = ctx.applyAccChanges(w, timer, info).valueOr:
          error info & ": Error applying BAL account changes", pivot=pivotNum,
            newState=number, dist, accAddr=($w.address),
            accPath=w.address.computeAccPath.toStr
          break body                                # failed
        if changedOk:
          changed.incl w.address

    # Update pivot and forward block numbers if there was some progress
    if pivotNum < number:
      adb.updAccMissingIntv(number, info).isOkOr:
        break body                                  # failed
      ctx.pool.pivotNum = number
      ctx.pool.forwardNum = number

    bodyRc = typeof(bodyRc).ok(changed.toSeq)
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
