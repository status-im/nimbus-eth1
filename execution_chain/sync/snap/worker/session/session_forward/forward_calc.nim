# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production.
## -------------------
##
## State root calculations depend on memory-only based MPT builder, which
## has a heavy memory footprint.
##
{.push raises: [].}

import
  pkg/[chronicles, eth/common],
  ../../[helpers, mpt, worker_desc]

logScope:
  topics = "snap sync"

type
  FlatStats* = tuple
    nAccounts: uint
    nAccUpdated: uint

  FlatInfo* = tuple
    stateRoot: Hash32
    stats: FlatStats

const
  EmptyFlatInfo* = FlatInfo.default

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc calcStorageRootImpl(
    db: CacheDbRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[Hash32] =
  ## This function is for debugging only: The way the storage root is compiled
  ## might result in a heavy memory footprint.
  ##
  var nSlots = 0u
  let mpt = NodeTrieRef.init()
  for w in db.walkFlatSlot(accPath):
    if 0 < w.error.len:
      error info & ": Error walking storage slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=w.error
      return err()
    mpt.merge(w.slotKey, w.data).isOkOr:
      trace info & ": Failed building storage MPT", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr
      return err()
    nSlots.inc

  if nSlots == 0:
    return ok(EMPTY_ROOT_HASH)                      # empty storage tree

  var stoRoot = mpt.finalised().valueOr:
    error info & ": Failed calculating storage root",
      accPath=accPath.toStr, nSlots
    return err()
  ok(stoRoot.to(Hash32))

proc calcStateRootImpl(
    db: CacheDbRef;
    info: static[string];
      ): Opt[Hash32] =
  ## This function is for debugging only: The way the state root is compiled
  ## might result in a heavy memory footprint.
  ##
  var nAcc = 0u
  let mpt = NodeTrieRef.init()
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts", accPath=w.accPath.toStr,
        nAccSoFar=nAcc, `error`=w.error
      return err()
    mpt.merge(w.accPath, w.data.account).isOkOr:
      error info & ": Failed building accounts MPT", accPath=w.accPath.toStr,
        nAccSoFar=nAcc
      return err()
    nAcc.inc

  if nAcc == 0:
    return ok(EMPTY_ROOT_HASH)                      # empty accounts trie

  var stateRoot = mpt.finalised().valueOr:
    error info & ": Failed calculating state root", nAcc
    return err()
  ok(stateRoot.to(Hash32))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc calcStateRoot*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[FlatInfo] =
  # Verify that there are no missing accounts
  if ?db.hasAccMissingIntv(info):
    trace info & ": Flat accounts DB incoplete"
    return ok(EmptyFlatInfo)                        # not computable yet

  var u: FlatInfo
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts",
        accPath=w.accPath.toStr, nAccSoFar=u.stats.nAccounts, `error`=w.error
      return err()

    # Verify that there are no storage slots missing.
    if ?db.hasStoMissingIntv(w.accPath, info):
      trace info & ": Flat storage slots DB incoplete", accPath=w.accPath.toStr
      return ok(EmptyFlatInfo)                      # not computable yet

    # Verify that the code hash is available or not needed.
    if w.data.dirtyCode:                            # not ready yet?
      trace info & ": Flat contract code DB incoplete", accPath=w.accPath.toStr
      return ok(EmptyFlatInfo)                      # nothing more to do

    # Handle storage sub-MPT. The storage root is updated only if available
    # after MPT calculation.
    var accData = w.data
    if w.data.dirtyStorage:
      # Update extended account record on flat table.
      accData.account.storageRoot = ?db.calcStorageRootImpl(w.accPath, info)
      accData.dirtyStorage = false
      ?db.putFlatAcc(w.accPath, accData, info)
      u.stats.nAccUpdated.inc

    doAssert accData.account.codeHash != zeroHash32
    doAssert accData.account.storageRoot != zeroHash32
    u.stats.nAccounts.inc

  if u.stats.nAccounts == 0:
    return ok(EmptyFlatInfo)

  u.stateRoot = ?db.calcStateRootImpl(info)
  ok(u)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
