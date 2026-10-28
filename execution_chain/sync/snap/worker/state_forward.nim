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
  pkg/[chronicles, chronos, eth/common],
  pkg/stew/[byteutils, interval_set],
  ./[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func isFullRange(itrs: ItemKeyRangeSet): bool =
  # Defensive encoding of a full range check. Solely testing `total; == 0`
  # leaves room for the case that the range is empty which is an illegal
  # situation but it can handled with savely.
  itrs.total == 0 and                               # => 0 or 2^256
  itrs.chunks == 1                                  # => one intv => full MPT

template applySlotChanges(
    adb: CacheDbRef;
    accPath: Hash32;
    slots: seq[SlotChanges];
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
    let stoState = adb.getStoMissingIntv(accPath, info).valueOr:
      break body                                    # err()
    stoState.isErrOr:
      if stoState.unsafeGet().ranges.isFullRange():
        bodyRc = typeof(bodyRc).ok()
        break body

    for w in slots:
      if w.changes.len == 0:
        continue

      # Check whether the slot key is in the unprocessed ranges.
      let slotKey = w.slot.computeSlotKey()
      stoState.isErrOr:
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
  var bodyRc = Opt[Hash32].err()
  block body:
    doAssert 0 < code.len
    let newCode = code[^1].newCode

    if newCode.len == 0:
      adb.delFlatCode(accPath, info).isOkOr:
        break body                                  # err()
      adb.delMissingBlob(accPath, info).isOkOr:     # no more missing (if any)
        break body
      bodyRc = typeof(bodyRc).ok(EMPTY_CODE_HASH)
      break body

    adb.putFlatCode(accPath, newCode, info).isOkOr:
      break body
    adb.delMissingBlob(accPath, info).isOkOr:       # no more missing (if any)
      break body

    bodyRc = typeof(bodyRc).ok(newCode.keccak256)
    # End `block body`
  bodyRc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template applyAccountChanges(
    ctx: SnapCtxRef;
    chng: AccountChanges;
    timer: TimerDataRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Apply BAL to account.
  ##
  var bodyRc = Opt[void].err()
  block body:
    if chng.storageChanges.len == 0 and
       chng.balanceChanges.len == 0 and
       chng.nonceChanges.len == 0 and
       chng.codeChanges.len == 0:
      bodyRc = typeof(bodyRc).ok()
      break body                                    # nothing to do

    # Check for accounts in the downloaded range, i.e. they are not registered
    # for downloading. If an account is in the downloaded range, it is a new
    # account and must be added. Otherwise, there is no knowledge whether this
    # is a new account, or a partial update.
    let
      adb = ctx.pool.cacheDB
      accPath = chng.address.computeAccPath
      accState = adb.getAccMissingIntv(info).valueOr:
        break body                                  # failed

      # Fetch account data record (might not exisit.)
      maybeAcc = adb.getFlatAcc(accPath).valueOr:
        error info & ": Failed to fetch account", accPath=accPath.toStr,
          `error`=error
        break body                                  # failed

    # Get or create account data record.
    var acc = maybeAcc.valueOr:
      # A new account will be created if it is not in the range of accounts
      # to be fetched, anyway
      if accState.ranges.covered(accPath.to(ItemKey)):
        bodyRc = typeof(bodyRc).ok()
        break body                                  # ignore for now
      emptyFlatAccData                              # new account

    timer.yieldThread()

    # Apply change list to account and cache DB
    if 0 < chng.storageChanges.len:
      acc.account.storageRoot = zeroHash32          # no sto. root known anymore
      adb.applySlotChanges(accPath, chng.storageChanges, timer, info).isOkOr:
        break body                                  # failed

    if 0 < chng.codeChanges.len:
      acc.account.codeHash =
        adb.applyCodeChange(accPath, chng.codeChanges, info).valueOr:
          break body                                # failed

    if 0 < chng.nonceChanges.len:
      acc.account.nonce = chng.nonceChanges[^1].newNonce

    if 0 < chng.balanceChanges.len:
      acc.account.balance = chng.balanceChanges[^1].postBalance

    adb.putFlatAcc(accPath, acc, info).isOkOr:      # update account
      break body                                    # failed

    bodyRc = typeof(bodyRc).ok()
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
  var bodyRc = Opt[void].err()
  block body:
    let
      adb = ctx.pool.cacheDB
      accState = adb.getAccMissingIntv(info).valueOr:
        break body                                  # failed
      pivotNum = accState.number

    var
      number = pivotNum
      timer = TimerDataRef(time: Moment.now())
    template dist: untyped = (number-pivotNum)

    while true:
      if nBalsMax <= dist:
        chronicles.info info & ": some BALs applied", pivotNum, number, dist
        break
      number.inc
      let bal = adb.getBal(number, info).valueOr:
        number.dec
        chronicles.info info & ": all BALs applied", pivotNum, number, dist
        break

      for w in bal[]:
        ctx.applyAccountChanges(w, timer, info).isOkOr:
          error info & ": Error applying BAL account changes", pivotNum, number,
            dist, accAddr=($w.address), accPath=w.address.computeAccPath.toStr
          break body                                # failed

    # Update pivot and forward block numbers if there was some progress
    if pivotNum < number:
      adb.updAccMissingIntv(number, info).isOkOr:
        break body                                  # failed
      ctx.pool.pivotNum = number
      ctx.pool.forwardNum = number

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
