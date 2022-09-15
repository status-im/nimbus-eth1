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


proc stopAfterError(
    buddy: SnapBuddyRef;
    error: ComError;
      ): Future[bool]
      {.async.} =
  ## Error handling after data protocol failed.
  case error:
  of ComResponseTimeout:
    if maxTimeoutErrors <= buddy.data.errors.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      buddy.ctrl.zombie = true
    else:
      # Otherwise try again some time later. Nevertheless, stop the
      # current action.
      buddy.data.errors.nTimeouts.inc
      await sleepAsync(5.seconds)
    return true

  of ComNetworkProblem,
     ComMissingProof,
     ComAccountsMinTooSmall,
     ComAccountsMaxTooLarge:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    buddy.data.stats.major.networkErrors.inc()
    buddy.ctrl.zombie = true
    return true

  of ComEmptyAccountsArguments,
     ComEmptyRequestArguments,
     ComInspectDbFailed,
     ComImportAccountsFailed,
     ComNoDataForProof,
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
    return true

# ------------------------------------------------------------------------------
# Private functions: accounts
# ------------------------------------------------------------------------------

proc processAccounts(
    buddy: SnapBuddyRef;
    iv: LeafRange;                    ## Accounts range to process
      ): Future[Result[void,ComError]]
      {.async.} =
  ## Process accounts and storage by bulk download on the current envirinment
  # Reset error counts for detecting repeated timeouts
  buddy.data.errors.nTimeouts = 0

  # Process accounts
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Fetch data for this range delegated to `fetchAccounts()`
  let dd = block:
    let rc = await buddy.getAccountRange(stateRoot, iv)
    if rc.isErr:
      buddy.putUnprocessed(iv) # fail => interval back to pool
      return err(rc.error)
    rc.value

  let
    nAccounts = dd.data.accounts.len
    nStorage = dd.withStorage.len

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
      return err(ComImportAccountsFailed)

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

  # Store accounts on the storage TODO list.
  discard env.leftOver.append SnapSlotQueueItemRef(q: dd.withStorage)

  return ok()

# ------------------------------------------------------------------------------
# Private functions: accounts storage
# ------------------------------------------------------------------------------

proc fetchAndImportStorageSlots(
    buddy: SnapBuddyRef;
    reqSpecs: seq[AccountSlotsHeader];
      ): Future[Result[seq[SnapSlotQueueItemRef],ComError]]
      {.async.} =
  ## Fetch storage slots data from the network, store it on disk and
  ## return yet unprocessed data.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Get storage slots
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, reqSpecs)
    if rc.isErr:
      return err(rc.error)
    rc.value

  if 0 < stoRange.data.storages.len:
    # ------------------------------
    buddy.dumpStorage(stoRange.data)
    # ------------------------------

    # Verify/process data and save to disk
    block:
      let rc = ctx.data.accountsDb.importStorages(peer, stoRange.data)

      if rc.isErr:
        # Push back parts of the error item
        for w in rc.error:
          if 0 <= w[0]:
            # Reset any partial requests by not copying the `firstSlot` field.
            # So all the storage slots are re-fetched completely for this
            # account.
            stoRange.addLeftOver AccountSlotsHeader(
              accHash:     stoRange.data.storages[w[0]].account.accHash,
              storageRoot: stoRange.data.storages[w[0]].account.storageRoot)

        if rc.error[^1][0] < 0:
          discard
          # TODO: disk storage failed or something else happend, so what?

  # Return the remaining part to be processed later
  return ok(stoRange.leftOver)


proc processStorageSlots(
    buddy: SnapBuddyRef;
      ): Future[Result[void,ComError]]
      {.async.} =
  ## Fetch storage data and save it on disk. Storage requests are managed by
  ## a request queue for handling partioal replies and re-fetch issues. For
  ## all practical puroses, this request queue should mostly be empty.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  while true:
    # Pull out the next request item from the queue
    let req = block:
      let rc = env.leftOver.shift
      if rc.isErr:
        return ok()
      rc.value

    block:
      # Fetch and store account storage slots. On some sort of success,
      # the `rc` return value contains a list of left-over items to be
      # re-processed.
      let rc = await buddy.fetchAndImportStorageSlots(req.q)

      if rc.isErr:
        # Save accounts/storage list to be processed later, then stop
        discard env.leftOver.append req
        return err(rc.error)

      for qLo in rc.value:
        # Handle queue left-overs for processing in the next cycle
        if qLo.q[0].firstSlot == Hash256.default and 0 < env.leftOver.len:
          # Appending to last queue item is preferred over adding new item
          let item = env.leftOver.first.value
          item.q = item.q & qLo.q
        else:
          # Put back as-is.
          discard env.leftOver.append qLo
    # End while

  return ok()

# ------------------------------------------------------------------------------
# Private functions: healing
# ------------------------------------------------------------------------------

proc accountsTrieHealing(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
    envSource: string;
      ): Future[Result[void,ComError]]
      {.async.} =
  ## ...
  # Starting with a given set of potentially dangling nodes, this set is
  # updated.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot

  while env.repairState != Done and
        (env.dangling.len != 0 or env.repairState == Pristine):

    trace "Accounts healing loop", peer, repairState=env.repairState,
      envSource, nDangling=env.dangling.len

    let needNodes = block:
      let rc = ctx.data.accountsDb.inspectAccountsTrie(
        peer, stateRoot, env.dangling)
      if rc.isErr:
        let error = rc.error
        trace "Accounts healing failed", peer, repairState=env.repairState,
          envSource, nDangling=env.dangling.len, error
        return err(ComInspectDbFailed)
      rc.value.dangling

    # Clear dangling nodes register so that other processes would not fetch
    # the same list simultaneously.
    env.dangling.setLen(0)

    # Noting to anymore
    if needNodes.len == 0:
      if env.repairState != Pristine:
        env.repairState = Done
      trace "Done accounts healing for now", peer, repairState=env.repairState,
        envSource, nDangling=env.dangling.len
      return ok()

    let lastState = env.repairState
    env.repairState = KeepGoing

    trace "Need nodes for healing", peer, repairState=env.repairState,
      envSource, nDangling=env.dangling.len, nNodes=needNodes.len

    # Fetch nodes
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, needNodes.mapIt(@[it]))
      if rc.isErr:
        env.dangling = needNodes
        env.repairState = lastState
        return err(rc.error)
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

  return ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchAccounts*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch accounts and data and store them in the database.
  ##
  ## TODO: Healing for storages. Currently, healing in only run for accounts.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
  var
    # Complete the previous environment by trie database healing (if any)
    healingEnvs = if not ctx.data.prevEnv.isNil: @[ctx.data.prevEnv] else: @[]

  block processAccountsFrame:
    # Get a range of accounts to fetch from
    let iv = block:
      let rc = buddy.getUnprocessed()
      if rc.isErr:
        # Although there are no accounts left to process, the other peer might
        # still work on some accounts. As a general rule, not all from an
        # account range gets served so the remaining range will magically
        # reappear on the unprocessed ranges database.
        trace "No more unprocessed accounts (maybe)", peer, stateRoot

        # Complete healing for sporadic nodes missing.
        healingEnvs.add env
        break processAccountsFrame
      rc.value

    trace "Start fetching accounts", peer, stateRoot, iv,
      repairState=env.repairState

    # Process received accounts and stash storage slots to fetch later
    block:
      let rc = await buddy.processAccounts(iv)
      if rc.isErr:
        let error = rc.error
        if await buddy.stopAfterError(error):
          buddy.dumpEnd()                   # FIXME: Debugging (will go away)
          trace "Stop fetching cycle", peer, repairState=env.repairState,
            processing="accounts", error
          return
        break processAccountsFrame

    # End `block processAccountsFrame`

  trace "Start fetching storages", peer, nAccounts=env.leftOver.len,
    repairState=env.repairState

  # Process storage slots from environment batch
  block:
    let rc = await buddy.processStorageSlots()
    if rc.isErr:
      let error = rc.error
      if await buddy.stopAfterError(error):
        buddy.dumpEnd()                     # FIXME: Debugging (will go away)
        trace "Stop fetching cycle", peer, repairState=env.repairState,
          processing="storage", error
        return

  # Check whether there is some environment that can be completed by
  # Patricia Merkle Tree healing.
  for w in healingEnvs:
    let envSource = if env == ctx.data.pivotEnv: "pivot" else: "retro"
    trace "Start accounts healing", peer, repairState=env.repairState,
      envSource, dangling=w.dangling.len

    let rc = await buddy.accountsTrieHealing(w, envSource)
    if rc.isErr:
      let error = rc.error
      if await buddy.stopAfterError(error):
        buddy.dumpEnd()                     # FIXME: Debugging (will go away)
        trace "Stop fetching cycle", peer, repairState=env.repairState,
          processing="healing", dangling=w.dangling.len, error
        return

  buddy.dumpEnd()                           # FIXME: Debugging (will go away)
  trace "Done fetching cycle", peer, repairState=env.repairState

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
