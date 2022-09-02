# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stew/[interval_set, keyed_queue],
  stint,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  "."/[accounts_db, get_account_range, get_storage_ranges]

when snapAccountsDumpEnable:
  import ../../../tests/replay/[undump_accounts, undump_storages]

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  accRangeMaxLen = ##\
    ## Ask for that many accounts at once (not the range is sparse)
    (high(NodeTag) - low(NodeTag)) div 1000

  maxTimeoutErrors = ##\
    ## maximal number of non-resonses accepted in a row
    2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc withMaxLen(buddy: SnapBuddyRef; iv: LeafRange): LeafRange =
  ## Reduce accounts interval to maximal size
  let maxlen = buddy.ctx.data.accountRangeMax
  if 0 < iv.len and iv.len <= maxLen:
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + (maxLen - 1.u256))

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getUnprocessed(buddy: SnapBuddyRef): Result[LeafRange,void] =
  ## Fetch an interval from the account range list. Use the `pivotAccount`
  ## value as a start entry to fetch data from, wrapping around if necessary.
  let
    ctx = buddy.ctx
    env = ctx.data.pivotEnv
    pivotPt = env.pivotAccount

  block:
    # Take the next interval to the right (aka ge) `pivotPt`
    let rc = env.availAccounts.ge(pivotPt)
    if rc.isOk:
      let iv = buddy.withMaxLen(rc.value)
      discard env.availAccounts.reduce(iv)
      return ok(iv)

  block:
    # Check whether the `pivotPt` is in the middle of an interval
    let rc = env.availAccounts.envelope(pivotPt)
    if rc.isOk:
      let iv = buddy.withMaxLen(LeafRange.new(pivotPt, rc.value.maxPt))
      discard env.availAccounts.reduce(iv)
      return ok(iv)

  block:
    # Otherwise wrap around
    let rc = env.availAccounts.ge()
    if rc.isOk:
      let iv = buddy.withMaxLen(rc.value)
      discard env.availAccounts.reduce(iv)
      return ok(iv)

  err()

proc putUnprocessed(buddy: SnapBuddyRef; iv: LeafRange) =
  discard buddy.ctx.data.pivotEnv.availAccounts.merge(iv)

proc delUnprocessed(buddy: SnapBuddyRef; iv: LeafRange) =
  discard buddy.ctx.data.pivotEnv.availAccounts.reduce(iv)

# -----

proc waitAfterError(buddy: SnapBuddyRef; error: GetAccountRangeError): bool =
  ## Error handling after `GetAccountRange` failed.
  case error:
  of GareResponseTimeout:
    if maxTimeoutErrors <= buddy.data.errors.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      buddy.ctrl.zombie = true
    else:
      # Otherwise try again some time later
      buddy.data.errors.nTimeouts.inc
      result = true

  of GareNetworkProblem,
     GareMissingProof,
     GareAccountsMinTooSmall,
     GareAccountsMaxTooLarge:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.data.stats.major.networkErrors.inc()
    buddy.ctrl.zombie = true

  of GareNothingSerious:
    discard

  of GareNoAccountsForStateRoot:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.ctrl.zombie = true


proc waitAfterError(buddy: SnapBuddyRef; error: GetStorageRangesError): bool =
  ## Error handling after `GetStorageRanges` failed.
  case error:
  of GsreResponseTimeout:
    if maxTimeoutErrors <= buddy.data.errors.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      buddy.ctrl.zombie = true
    else:
      # Otherwise try again some time later
      buddy.data.errors.nTimeouts.inc
      result = true

  of GsreNetworkProblem,
     GsreTooManyStorageSlots:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.data.stats.major.networkErrors.inc()
    buddy.ctrl.zombie = true

  of GsreNothingSerious:
    discard

  of GsreNoStorageForAccounts:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchAccounts*(buddy: SnapBuddyRef): Future[bool] {.async.} =
  ## Fetch accounts data and store them in the database. The function returns
  ## `true` if there are no more unprocessed accounts.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Get a range of accounts to fetch from
  let iv = block:
    let rc = buddy.getUnprocessed()
    if rc.isErr:
      trace "No more unprocessed accounts", peer, stateRoot
      return true
    rc.value

  # Fetch data for this range delegated to `fetchAccounts()`
  let dd = block:
    let rc = await buddy.getAccountRange(stateRoot, iv)
    if rc.isErr:
      buddy.putUnprocessed(iv) # fail => interval back to pool
      if buddy.waitAfterError(rc.error):
        await sleepAsync(5.seconds)
      return false
    rc.value

  # Reset error counts
  buddy.data.errors.nTimeouts = 0

  # Process accounts data
  let
    nAccounts = dd.data.accounts.len
    nStorage = dd.withStorage.len
    rc = ctx.data.accountsDb.importAccounts(
      peer, stateRoot, iv.minPt, dd.data, storeData = true)
  if rc.isErr:
    # Bad data, just try another peer
    buddy.putUnprocessed(iv)
    buddy.ctrl.zombie = true

    trace "Import failed, restoring unprocessed accounts", peer, stateRoot,
      range=dd.consumed, nAccounts, nStorage, error=rc.error
  else:
    # Statistics
    env.nAccounts.inc(nAccounts)
    env.nStorage.inc(nStorage)

    # Register consumed intervals on the accumulator over all state roots
    discard buddy.ctx.data.coveredAccounts.merge(dd.consumed)

    # Register consumed and bulk-imported (well, not yet) accounts range
    let rx = iv - dd.consumed
    if rx.isOk:
      # Return some unused range
      buddy.putUnprocessed(rx.value)
    else:
      # The processed interval might be a bit larger
      let ry = dd.consumed - iv
      if ry.isOk:
        # Remove from unprocessed data. If it is not unprocessed, anymore then
        # it was double processed which if ok.
        buddy.delUnprocessed(ry.value)

    # --------------------
    # For dumping data ready to be used in unit tests
    when snapAccountsDumpEnable:
      trace " Snap proofs dump", peer, enabled=ctx.data.proofDumpOk, iv
      if ctx.data.proofDumpOk:
        var fd = ctx.data.proofDumpFile
        if rc.isErr:
          fd.write "  # Error: base=" & $iv.minPt & " msg=" & $rc.error & "\n"
        fd.write "# count ", $ctx.data.proofDumpInx & "\n"
        fd.write stateRoot.dumpAccounts(iv.minPt, dd.data) & "\n"
        # TBC ...
    # --------------------

    # Fetch storage data
    block:
      var leftOver = env.leftOver & dd.withStorage
      env.leftOver.setlen(0)
      while 0 < leftOver.len:
        # Note that `getStorageRanges()` guarantees that any returned left
        # over list is smaller than the argument length.
        let rc = await buddy.getStorageRanges(stateRoot, leftOver)
        if rc.isOk:
          let storage = rc.value.data
          leftOver = rc.value.leftOver
          # --------------------
          # For dumping data ready to be used in unit tests
          when snapAccountsDumpEnable:
            if ctx.data.proofDumpOk:
              var fd = ctx.data.proofDumpFile
              fd.write stateRoot.dumpStorages(storage) & "\n"
              # TBC ...
          # --------------------

          # TODO: store in database
        else:
          # Save accounts/storage list to be processed later
          env.leftOver.add leftOver
          if buddy.waitAfterError(rc.error):
            await sleepAsync(5.seconds)
          break

    # --------------------
    # For dumping data ready to be used in unit tests
    when snapAccountsDumpEnable:
      if ctx.data.proofDumpOk:
        var fd = ctx.data.proofDumpFile
        fd.flushFile
        ctx.data.proofDumpInx.inc
        # Done this time
    # --------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
