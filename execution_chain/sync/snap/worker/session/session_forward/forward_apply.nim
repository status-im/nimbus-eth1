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
  ../../[mpt, worker_desc]

logScope:
    topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc applySlotChanges(
    adb: CacheDbRef;
    accPath: Hash32;
    slots: openArray[SlotChanges];
    info: static[string];
      ): Opt[void] =
  ## Apply BAL to storage slots. This assumes to have partial storage sub-MPTs
  ## cleared. But it would matter if there were a stray one as it would still
  ## be partial and be cleared later.
  ##
  for w in slots:
    if w.changes.len != 0:
      let
        slotKey = w.slot.computeSlotKey()
        slotValue = w.changes[^1].newValue
      if slotValue == 0:
        ?adb.delFlatSlot(accPath, slotKey, info)
      else:
        ?adb.putFlatSlot(accPath, slotKey, slotValue, info)
  ok()

proc applyCodeChange(
    adb: CacheDbRef;
    accPath: Hash32;
    code: openArray[CodeChange];
    info: static[string];
      ): Opt[Hash32] =
  ## Apply BAL to contract code
  ##
  if code.len == 0:
    return ok(EMPTY_CODE_HASH)

  let newCode = code[^1].newCode
  ?adb.putFlatCode(accPath, newCode, info)
  ok(newCode.keccak256)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc applyAccountChanges*(
    ctx: SnapCtxRef;
    chng: AccountChanges;
    info: static[string];
      ): Opt[void] =
  ## Apply BAL to account.
  if chng.storageChanges.len == 0 and
     chng.balanceChanges.len == 0 and
     chng.nonceChanges.len == 0 and
     chng.codeChanges.len == 0:
    return ok()                                     # nothing to do

  # Check for existing accounts that have not been fetched, yet
  let
    adb = ctx.pool.cacheDB
    accPath = chng.address.computeAccPath
  if (?adb.getAccMissingIntv(info)).ranges.covered(accPath.to(ItemKey)):
    return ok()                                     # ignore for now

  var acc = adb.getFlatAcc(accPath, info).valueOr:
    emptyFlatAccData                                # new account

  # Apply change list to account and cache DB
  if 0 < chng.storageChanges.len:
    acc.account.storageRoot = zeroHash32            # no sto root known anymore
    ?adb.applySlotChanges(accPath, chng.storageChanges, info)

  if 0 < chng.codeChanges.len:
    acc.dirtyCode = false
    acc.account.codeHash = ?adb.applyCodeChange(accPath, chng.codeChanges, info)

  if 0 < chng.nonceChanges.len:
    acc.account.nonce = chng.nonceChanges[^1].newNonce

  if 0 < chng.balanceChanges.len:
    acc.account.balance = chng.balanceChanges[^1].postBalance

  ?adb.putFlatAcc(accPath, acc, info)               # update account
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
