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
  pkg/[chronicles, eth/common, stew/interval_set],
  ../../[mpt, state_db, worker_desc]

logScope:
    topics = "snap sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc applySlotChanges(
    db: CacheDbRef;
    accPath: Hash32;
    slots: openArray[SlotChanges];
    info: static[string];
      ): Opt[void] =
  ## Apply BAL to storage slots. Returns the number of changes
  let
    maybeStats = ?db.getStoMissingIntv(accPath, info)
    stoMissing = if maybeStats.isNone(): ItemKeyRangeSet(nil)
                 else: maybeStats.unsafeGet().ranges
  for w in slots:
    if w.changes.len == 0:
      continue
    let slotKey = w.slot.computeSlotKey()
    if not stoMissing.isNil and
       stoMissing.covered(slotKey.to(ItemKey)):
      continue
    let slotValue = w.changes[^1].newValue
    if slotValue == 0:
      ?db.delFlatSlot(accPath, slotKey, info)
    else:
      ?db.putFlatSlot(accPath, slotKey, slotValue, info)

  ok()

proc applyCodeChange(
    db: CacheDbRef;
    accPath: Hash32;
    code: openArray[CodeChange];
    info: static[string];
      ): Opt[Hash32] =
  ## Apply BAL to contract code
  if code.len == 0:
    return ok(EMPTY_CODE_HASH)

  let newCode = code[^1].newCode
  ?db.putFlatCode(accPath, newCode, info)
  ok(newCode.keccak256)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc applyAccountChanges*(
    db: CacheDbRef;
    chng: AccountChanges;
    accExcl: ItemKeyRangeSet;
    info: static[string];
      ): Opt[bool] =
  ## Apply BAL to account. Returns `true` if there were some changes.
  if chng.storageChanges.len == 0 and
     chng.balanceChanges.len == 0 and
     chng.nonceChanges.len == 0 and
     chng.codeChanges.len == 0:
    return ok(false)                                # nothing to do

  # Check for existing accounts that have not been fetched, yet
  let accPath = chng.address.computeAccPath
  if accExcl.covered(accPath.to(ItemKey)):
    return ok(false)                                # ignore for now

  var acc = (?db.getFlatAcc(accPath, info)).valueOr:
    emptyFlatAccData                                # new account

  # Apply change list to database
  if 0 < chng.nonceChanges.len:
    acc.account.nonce = chng.nonceChanges[^1].newNonce

  if 0 < chng.balanceChanges.len:
    acc.account.balance = chng.balanceChanges[^1].postBalance

  if 0 < chng.codeChanges.len:
    acc.account.codeHash = ?db.applyCodeChange(accPath, chng.codeChanges, info)

  if 0 < chng.storageChanges.len:
    ?db.applySlotChanges(accPath, chng.storageChanges, info)
    acc.dirtyStorage = true                         # mark it changed
    acc.account.storageRoot = zeroHash32            # no storage root yet

  ?db.putFlatAcc(accPath, acc, info)                # update account
  ok(true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
