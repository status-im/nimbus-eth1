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
  "."/[accounts_db, get_account_range]

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
  let maxlen =
    if buddy.ctx.data.pivotEnv.proofDumpOk: snapAccountsDumpRange
    else: buddy.ctx.data.accountRangeMax
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchAccounts*(buddy: SnapBuddyRef): Future[bool] {.async.} =
  ## Fetch accounts data and store them in the database. The function returns
  ## `true` if there are no more unprocessed accounts.
  ##
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
      case rc.error:
      of ResponseTimeout:
        if maxTimeoutErrors <=  buddy.data.errors.nTimeouts:
          # Mark this peer dead, i.e. avoid fetching from this peer for a while
          buddy.ctrl.zombie = true
        else:
          buddy.data.errors.nTimeouts.inc
          await sleepAsync(5.seconds)
      of NetworkProblem, MissingProof, AccountsMinTooSmall, AccountsMaxTooLarge:
        # Mark this peer dead, i.e. avoid fetching from this peer for a while
        buddy.data.stats.major.networkErrors.inc()
        buddy.ctrl.zombie = true
      of GetAccountRangeError.NothingSerious:
        discard
      of NoAccountsForStateRoot:
        # Mark this peer dead, i.e. avoid fetching from this peer for a while
        buddy.ctrl.zombie = true
      return
    rc.value

  # Reset error counts
  buddy.data.errors.nTimeouts = 0


  # Process accounts data
  let
    nAccounts = dd.data.accounts.len
    rc = ctx.data.accountsDb.importAccounts(
      peer, stateRoot, iv.minPt, dd.data, storeData = true)
  if rc.isErr:
    # TODO: Prevent deadlock in case there is a problem with the approval
    #       data which is not in production state, yet.
    trace "Import failed, restoring unprocessed accounts", peer, stateRoot,
      range=dd.consumed, nAccounts, error=rc.error

    # Just try another peer
    buddy.ctrl.zombie = true
  else:
    # Statistics
    env.nAccounts.inc(nAccounts)

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

    # ----
    # For dumping data ready to be used in unit tests
    if env.proofDumpOk:
      var fd = ctx.data.proofDumpFile
      if env.proofDumpInx == 0:
        fd.write dumpRoot(stateRoot)
      fd.write "\n"
      if rc.isErr:
        fd.write "  # Error: base=" & $iv.minPt & " msg=" & $rc.error & "\n"
      fd.write dumpSnapAccountRange(
        iv.minPt, dd.data, "snapProofData" & $env.proofDumpInx & "*")
      fd.flushFile
      env.proofDumpInx.inc
      if snapAccountsDumpMax <= env.proofDumpInx:
        env.proofDumpOk = false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
