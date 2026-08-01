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
  pkg/[chronicles, eth/common],
  ../../[mpt, worker_desc]

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
  for w in slots:
    if 0 < w.changes.len:
      let
        slotKey = w.slot.computeSlotKey()
        slotValue = w.changes[^1].newValue
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
    info: static[string];
      ): Opt[bool] =
  ## Apply BAL to account. Returns `true` if there were some changes.
  if chng.storageChanges.len == 0 and
     chng.balanceChanges.len == 0 and
     chng.nonceChanges.len == 0 and
     chng.codeChanges.len == 0:
    return ok(false)                                # nothing to do

  let
    accPath = chng.address.computeAccPath
    maybeAcc = ?db.getFlatAcc(accPath, info)
  var
    acc = maybeAcc.valueOr: emptyFlatAccData

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
