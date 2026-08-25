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
# Private functions
# ------------------------------------------------------------------------------

proc setStoNoneMissing(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[CacheStoMissingIntvData] =
  var data: CacheStoMissingIntvData
  data.ranges = ItemKeyRangeSet.init()
  ?db.putStoMissingIntv(accPath, data, info)
  ok(move data)

proc setAccMissing(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[void] =
  ?db.delStoMissingIntv(accPath, info)              # delete storage accounting
  ?db.delFlatSlot(accPath, info)                    # delete all slots
  ?db.delFlatCode(accPath, info)                    # delete contract code
  ?db.delFlatAcc(accPath, info)                     # remove account record

  var accState = ?db.getAccMissingIntv(info)
  let accKey = accPath.to(ItemKey)
  discard accState.ranges.merge(accKey, accKey)
  ?db.putAccMissingIntv(accState, info)             # update bookkeeping
  ok()

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc applySlotChanges(
    db: CacheDbRef;
    accPath: Hash32;
    slots: openArray[SlotChanges];
    info: static[string];
      ): Opt[bool] =
  ## Apply BAL to storage slots. Returns `true` if changes could be alloed,
  ## and `false` if the storage sub-MPT was cleared.
  ##
  let stoState = (?db.getStoMissingIntv(accPath, info)).valueOr:
    # This is a new account with additional storage chages.
    ?db.setStoNoneMissing(accPath, info)

  # There is no way to reliably update partial MPTs. So all that can be done
  # is to clear them and re-download.
  if stoState.ranges.total != 0 or                  # 0 mod 2^256 => 0 or 2^256
     stoState.ranges.chunks != 0:                   # intervals => 2^256 => all
    return ok(false)

  # So there is a full MPT which can be updated.
  for w in slots:
    if w.changes.len != 0:
      let
        slotKey = w.slot.computeSlotKey()
        slotValue = w.changes[^1].newValue
      if slotValue == 0:
        ?db.delFlatSlot(accPath, slotKey, info)
      else:
        ?db.putFlatSlot(accPath, slotKey, slotValue, info)

  ok(true)

proc applyCodeChange(
    db: CacheDbRef;
    accPath: Hash32;
    code: openArray[CodeChange];
    info: static[string];
      ): Opt[Hash32] =
  ## Apply BAL to contract code
  ##
  ?db.delMissingBlob(accPath, info)
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

  var acc = db.getFlatAcc(accPath, info).valueOr:
    emptyFlatAccData                                # new account

  # Apply change list to account and cache DB
  if 0 < chng.storageChanges.len:
    if ?db.applySlotChanges(accPath, chng.storageChanges, info):
      # Some changes apply to a full sub-MPT
      acc.dirtyStorage = true                       # mark it changed
      acc.account.storageRoot = zeroHash32          # no storage root known
    else:
      # Sub-MPT has become unusable. Remove sub-MPT and corresponding account.
      ?db.setAccMissing(accPath, info)
      return ok(true)

  if 0 < chng.codeChanges.len:
    acc.account.codeHash = ?db.applyCodeChange(accPath, chng.codeChanges, info)

  if 0 < chng.nonceChanges.len:
    acc.account.nonce = chng.nonceChanges[^1].newNonce

  if 0 < chng.balanceChanges.len:
    acc.account.balance = chng.balanceChanges[^1].postBalance

  ?db.putFlatAcc(accPath, acc, info)                # update account
  ok(true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
