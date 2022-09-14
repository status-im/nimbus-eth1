# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[get_account_range, get_error, get_storage_ranges, get_trie_nodes],
  ./accounts_db

when snapAccountsDumpEnable:
  import ../../../tests/replay/[undump_accounts, undump_storages]

{.push raises: [Defect].}


logScope:
  topics = "snap-fetch"

const
  maxTimeoutErrors = 2
    ## maximal number of non-resonses accepted in a row

# ------------------------------------------------------------------------------
# Private debugging
# ------------------------------------------------------------------------------

proc dumpBegin(
    buddy: SnapBuddyRef;
    iv: LeafRange;
    dd: GetAccountRange;
    error = NothingSerious) =
  # For debuging, will go away
  discard
  when snapAccountsDumpEnable:
    let ctx = buddy.ctx
    if ctx.data.proofDumpOk:
      let
        peer = buddy.peer
        env = ctx.data.pivotEnv
        stateRoot = env.stateHeader.stateRoot
      trace " Snap proofs dump", peer, enabled=ctx.data.proofDumpOk, iv
      var
        fd = ctx.data.proofDumpFile
      try:
        if error != NothingSerious:
          fd.write "  # Error: base=" & $iv.minPt & " msg=" & $error & "\n"
        fd.write "# count ", $ctx.data.proofDumpInx & "\n"
        fd.write stateRoot.dumpAccounts(iv.minPt, dd.data) & "\n"
      except CatchableError:
        discard
      ctx.data.proofDumpInx.inc

proc dumpStorage(buddy: SnapBuddyRef; data: AccountStorageRange) =
  # For debuging, will go away
  discard
  when snapAccountsDumpEnable:
    let ctx = buddy.ctx
    if ctx.data.proofDumpOk:
      let
        peer = buddy.peer
        env = ctx.data.pivotEnv
        stateRoot = env.stateHeader.stateRoot
      var
        fd = ctx.data.proofDumpFile
      try:
        fd.write stateRoot.dumpStorages(data) & "\n"
      except CatchableError:
        discard

proc dumpEnd(buddy: SnapBuddyRef) =
  # For debuging, will go away
  discard
  when snapAccountsDumpEnable:
    let ctx = buddy.ctx
    if ctx.data.proofDumpOk:
      var fd = ctx.data.proofDumpFile
      fd.flushFile

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
  ## Shortcut
  discard buddy.ctx.data.pivotEnv.availAccounts.merge(iv)

proc delUnprocessed(buddy: SnapBuddyRef; iv: LeafRange) =
  ## Shortcut
  discard buddy.ctx.data.pivotEnv.availAccounts.reduce(iv)


proc waitAfterError(buddy: SnapBuddyRef; error: ComError): bool =
  ## Error handling after data protocol failed.
  case error:
  of ComResponseTimeout:
    if maxTimeoutErrors <= buddy.data.errors.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      buddy.ctrl.zombie = true
    else:
      # Otherwise try again some time later
      buddy.data.errors.nTimeouts.inc
      result = true

  of ComNetworkProblem,
     ComMissingProof,
     ComAccountsMinTooSmall,
     ComAccountsMaxTooLarge:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.data.stats.major.networkErrors.inc()
    buddy.ctrl.zombie = true

  of ComEmptyAccountsArguments,
     ComEmptyRequestArguments,
     ComNothingSerious:
    discard

  of ComNoAccountsForStateRoot,
     ComNoStorageForAccounts,
     ComNoByteCodesAvailable,
     ComNoTrieNodesAvailable,
     ComTooManyByteCodes,
     ComTooManyStorageSlots,
     ComTooManyTrieNodes:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.ctrl.zombie = true


proc processStorageSlots(
    buddy: SnapBuddyRef;
    reqSpecs: seq[AccountSlotsHeader];
      ): Future[Result[SnapSlotQueueItemRef,ComError]]
      {.async.} =
  ## Fetch storage slots data from the network, store it on disk and
  ## return yet unprocessed data.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Get storage slots
  let storage = block:
    let rc = await buddy.getStorageRanges(stateRoot, reqSpecs)
    if rc.isErr:
      return err(rc.error)
    rc.value

  # -----------------------------
  buddy.dumpStorage(storage.data)
  # -----------------------------

  # Verify/process data and save to disk
  block:
    let rc = ctx.data.accountsDb.importStorages(peer, storage.data)

    if rc.isErr:
      # Push back parts of the error item
      for w in rc.error:
        if 0 <= w[0]:
          # Reset any partial requests by not copying the `firstSlot` field. So
          # all the storage slots are re-fetched completely for this account.
          storage.leftOver.q.add AccountSlotsHeader(
            accHash:     storage.data.storages[w[0]].account.accHash,
            storageRoot: storage.data.storages[w[0]].account.storageRoot)

      if rc.error[^1][0] < 0:
        discard
        # TODO: disk storage failed or something else happend, so what?

  # Return the remaining part to be processed later
  return ok(storage.leftOver)


proc processAccountsAndStorageSlots(
    buddy: SnapBuddyRef;
    iv: LeafRange;                    ## Accounts range requested
    dd: GetAccountRange;              ## Accounts received
      ) {.async.} =
  ## Process accounts and storage bt bulk download on the current envirinment
  # Reset error counts for detecting repeated timeouts
  buddy.data.errors.nTimeouts = 0

  # Process accounts
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
    nAccounts = dd.data.accounts.len
    nStorage = dd.withStorage.len

  trace "Start fetching accounts", peer, stateRoot, iv,
    repairState=env.repairState

  block:
    let rc = ctx.data.accountsDb.importAccounts(
      peer, stateRoot, iv.minPt, dd.data)
    if rc.isErr:
      # Bad data, just try another peer
      buddy.putUnprocessed(iv)
      buddy.ctrl.zombie = true
      trace "Import failed, restoring unprocessed accounts", peer, stateRoot,
        range=dd.consumed, nAccounts, nStorage, error=rc.error

      buddy.dumpBegin(iv, dd, rc.error)  # FIXME: Debugging (will go away)
      buddy.dumpEnd()                    # FIXME: Debugging (will go away)
      return

  buddy.dumpBegin(iv, dd)                # FIXME: Debugging (will go away)

  # Statistics
  env.nAccounts.inc(nAccounts)
  env.nStorage.inc(nStorage)

  # Register consumed intervals on the accumulator over all state roots
  discard buddy.ctx.data.coveredAccounts.merge(dd.consumed)

  # Register consumed and bulk-imported (well, not yet) accounts range
  block registerConsumed:
    block:
      # Both intervals `min(iv)` and `min(dd.consumed)` are equal
      let rc = iv - dd.consumed
      if rc.isOk:
        # Now, `dd.consumed` < `iv`, return some unused range
        buddy.putUnprocessed(rc.value)
        break registerConsumed
    block:
      # The processed interval might be a bit larger
      let rc = dd.consumed - iv
      if rc.isOk:
        # Remove from unprocessed data. If it is not unprocessed, anymore
        # then it was doubly processed which is ok.
        buddy.delUnprocessed(rc.value)
        break registerConsumed
    # End registerConsumed

  # Fetch storage data and save it on disk. Storage requests are managed by
  # a request queue for handling partioal replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.
  discard env.leftOver.append SnapSlotQueueItemRef(q: dd.withStorage)

  trace "Start fetching storages", peer, nAccounts=env.leftOver.len,
    repairState=env.repairState

  while true:
    # Pull out the next request item from the queue
    let req = block:
      let rc = env.leftOver.shift
      if rc.isErr:
        buddy.dumpEnd()                  # FIXME: Debugging (will go away)
        return
      rc.value

    block:
      # Fetch and store account storage slots. On some sort of success,
      # the `rc` return value contains a list of left-over items to be
      # re-processed.
      let rc = await buddy.processStorageSlots(req.q)

      if rc.isErr:
        # Save accounts/storage list to be processed later, then stop
        discard env.leftOver.append req
        if buddy.waitAfterError(rc.error):
          buddy.dumpEnd() # FIXME: Debugging (will go away)
          await sleepAsync(5.seconds)
          return
        elif buddy.ctrl.zombie:
          return

      elif 0 < rc.value.q.len:
        # Handle queue left-overs for processing in the next cycle
        if rc.value.q[0].firstSlot == Hash256.default and
           0 < env.leftOver.len:
          # Appending to last queue item is preferred over adding new item
          let item = env.leftOver.first.value
          item.q = item.q & rc.value.q
        else:
          # Put back as-is.
          discard env.leftOver.append rc.value
    # End while

  buddy.dumpEnd()                        # FIXME: Debugging (will go away)


proc accountsTrieHealing(buddy: SnapBuddyRef; env: SnapPivotRef) {.async.} =
  ## ...
  # Starting with a given set of potentially dangling nodes, this set is
  # updated.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot

  trace "Start healing", peer, repairState=env.repairState

  while env.repairState != Done and
        (env.dangling.len != 0 or env.repairState == Pristine):

    let needNodes = block:
      let rc = ctx.data.accountsDb.inspectAccountsTrie(
        peer, stateRoot, env.dangling)
      if rc.isErr:
        let error = rc.error
        trace "accountsTrieHealing failed", peer, repairState=env.repairState,
          nDangling=env.dangling.len, error
        return # TODO: error/loop handling
      rc.value.dangling

    # Clear dangling nodes register so that other processes would not fetch
    # the same list simultaneously.
    env.dangling.setLen(0)

    # Noting to anymore
    if needNodes.len == 0:
      env.repairState = Done
      return

    let lastState = env.repairState
    env.repairState = KeepGoing

    trace "Need nodes for healing", peer, repairState=env.repairState,
      nDangling=env.dangling.len, nNodes=needNodes.len

    # Fetch nodes
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, needNodes.mapIt(@[it]))
      if rc.isErr:
        env.dangling = needNodes
        env.repairState = lastState
        if buddy.waitAfterError(rc.error):
          await sleepAsync(5.seconds)
          return
        elif buddy.ctrl.zombie:
          return
      rc.value

    # Store to disk and register left overs for the next pass
    block:
      let rc = ctx.data.accountsDb.importRawNodes(peer, dd.nodes)
      if rc.isOk:
        env.dangling = dd.leftOver.mapIt(it[0])
      elif 0 < rc.error.len and rc.error[^1][0] < 0:
        # negative index => storage error
        env.dangling = needNodes
      else:
        let nodeKeys = rc.error.mapIt(dd.nodes[it[0]])
        env.dangling = dd.leftOver.mapIt(it[0]) & nodeKeys
    # End while

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchAccounts*(buddy: SnapBuddyRef) {.async.} =
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
      # Start healing for sporadic nodes missing
      if env.repairState != Done:
        await buddy.accountsTrieHealing(env)
      return
    rc.value

  # Fetch data for this range delegated to `fetchAccounts()`
  let dd = block:
    let rc = await buddy.getAccountRange(stateRoot, iv)
    if rc.isErr:
      buddy.putUnprocessed(iv) # fail => interval back to pool
      if buddy.waitAfterError(rc.error):
        await sleepAsync(5.seconds)
        return
      elif buddy.ctrl.zombie:
        return
    rc.value

  # Process received accounts and receive storage slots
  await buddy.processAccountsAndStorageSlots(iv, dd)

  # Check whether there is some previous environment that can be completed by
  # Patricia Merkle Tree healing.
  let prvEnv = ctx.data.prevEnv
  if not prvEnv.isNil:
    # Continue with the healing process
    await buddy.accountsTrieHealing(prvEnv)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
