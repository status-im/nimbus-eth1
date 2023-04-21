# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch and install contract codes
## ================================
##
## Pretty straight forward


{.push raises: [].}

import
  std/tables,
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/keyed_queue,
  "../../.."/[sync_desc, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_byte_codes],
  ../db/snapdb_contracts

logScope:
  topics = "snap-con"

type
  SnapCtraKVP = KeyedQueuePair[Hash256,NodeKey]

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Contracts fetch " & info

proc fetchCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string {.used.} =
  "{" &
    "piv=" & env.stateHeader.blockNumber.toStr & "," &
    "ctl=" & $buddy.ctrl.state & "," &
    "nConQ=" & $env.fetchContracts.len & "," &
    "nCon="  & $env.nContracts & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noKeyErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg


proc getUnprocessed(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
    ign: HashSet[NodeKey];
      ): (seq[NodeKey],Table[Hash256,NodeKey]) =
  ## Fetch contracy hashes from the batch queue. Full entries will be removed
  ## from the batch queue and returned as second return code value.
  for w in env.fetchContracts.nextPairs:
    let key = w.key.to(NodeKey)
    if key notin ign:
      result[0].add key
      result[1][w.key] = w.data
      env.fetchContracts.del w.key # safe for `keyedQueue`
      if fetchRequestContractsMax <= result[0].len:
        break


proc putUnprocessed(
    env: SnapPivotRef;
    tab: Table[Hash256,NodeKey];
      ) =
  ## Push back some items
  for (key,val) in tab.pairs:
    # Use LRU mode which moves an item to the right end in case it is a
    # duplicate. It might have been added by some other peer which could
    # happen with a duplicate account (e.g. the one returned beyond an empty
    # range.)
    if env.fetchContracts.lruFetch(key).isErr:
      discard env.fetchContracts.append(key,val)

proc putUnprocessed(
    env: SnapPivotRef;                      # Current pivot environment
    select: seq[NodeKey];                   # List of codeHash keys to re-queue
    value: Table[Hash256,NodeKey];          # Value for codeHash keys
      ): HashSet[NodeKey]  =
  ## Variant of `putUnprocessed()`
  noKeyErrorOops("putUnprocessed"):
    for key in select:
      let hashKey = key.to(Hash256)
      if env.fetchContracts.lruFetch(hashKey).isErr:
        discard env.fetchContracts.append(hashKey, value[hashKey])
      result.incl key

# ------------------------------------------------------------------------------
#  Private functions
# ------------------------------------------------------------------------------

proc rangeFetchContractsImpl(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
    ign: HashSet[NodeKey];
      ): Future[(HashSet[NodeKey],bool)]
      {.async.} =
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Get a range of accounts to fetch from
  let (hashKeys, parking) = buddy.getUnprocessed(env,ign)
  if hashKeys.len == 0:
    when extraTraceMessages:
      trace logTxt "currently all processed", peer, ctx=buddy.fetchCtx(env)
      return

  # Fetch data from the network
  let dd = block:
    let rc = await buddy.getByteCodes hashKeys
    if rc.isErr:
      # Restore batch queue
      env.putUnprocessed parking
      if await buddy.ctrl.stopAfterSeriousComError(rc.error, buddy.only.errors):
        error logTxt "fetch error", peer, ctx=buddy.fetchCtx(env),
          nHashKeys=hashKeys.len, error=rc.error
        discard
      return (hashKeys.toHashSet, true)
    rc.value

  # Import keys
  block:
    let rc = ctx.pool.snapDb.importContracts(peer, dd.kvPairs)
    if rc.isErr:
      error logTxt "import failed", peer, ctx=buddy.fetchCtx(env),
        nHashKeys=hashKeys.len, error=rc.error
      return

  # Statistics
  env.nContracts.inc(dd.kvPairs.len)

  # Update left overs
  let leftOverKeys = env.putUnprocessed(dd.leftOver, parking)

  return (leftOverKeys, true)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchContracts*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch contract codes and store them in the database.
  trace logTxt "start", peer=buddy.peer, ctx=buddy.fetchCtx(env)

  var
    nFetchContracts = 0             # for logging
    ignore: HashSet[NodeKey]        # avoid duplicate failures on this peer
  while buddy.ctrl.running and
        0 < env.fetchContracts.len and
        not env.archived:

    # May repeat fetching batch
    let (leftOver,ok) = await buddy.rangeFetchContractsImpl(env,ignore)
    if not ok:
      break

    for w in leftOver:
      ignore.incl w
    nFetchContracts.inc

    when extraTraceMessages:
      trace logTxt "looping", peer=buddy.peer, ctx=buddy.fetchCtx(env),
        nFetchContracts, nLeftOver=leftOver.len

  trace logTxt "done", peer=buddy.peer, ctx=buddy.fetchCtx(env), nFetchContracts

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
