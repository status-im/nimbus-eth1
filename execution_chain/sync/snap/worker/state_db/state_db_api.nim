# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[hashes, sequtils, sets, strformat, strutils, tables],
  pkg/[chronicles, eth/common, metrics],
  pkg/stew/[interval_set, sorted_set],
  ../[helpers, worker_const],
  ./[state_identifiers, state_item_key, state_rank_index,
     state_unproc_item_keys]

logScope:
  topics = "snap sync"

declareGauge nec_snap_accumulated_state_coverage, "" &
  "Factor of accumulated accounts covered over all state root records"

declareGauge nec_snap_pivot_state_coverage, "" &
  "Max factor of accounts covered related to a single state root"

declareGauge nec_snap_active_states, "" &
  "Number of active state root indexed caches to download to"

type
  StateByRank = SortedSet[StateRankIndex,StateDataRef]
    ## List of incomplete states downloaded from the `snap` network

  WalkByRank = SortedSetWalkRef[StateRankIndex,StateDataRef]
    ## Quick traversal descriptor

  StateByRoot = Table[StateRoot,StateDataRef]
    ## Same list as above, indexed by state root

  StateByHash = Table[BlockHash,StateDataRef]
    ## Same list as above, indexed by block hashes

  DataByAccount = SortedSet[ItemKey,AccDataRef]
    ## For storage slots book keeping

  AccDataRef* = ref object
    ## Incompleteed download states db for storage slots. For storage
    ## slots, there is a single interval for unprocessed slots. That
    ## means, that storage slots for the same account can only be fetched
    ## and prossessed by a sigle peer at a time.
    stoRoot*: StoreRoot                 ## Account storage root (for mpt)
    stoLeft*: ItemKeyRange              ## Unprocessed storage slots
    code*: CodeHash                     ## Code hash (for mpt)

  StateDataRef* = ref object
    ## Single download state organises unprocessed accounts, and unprocessed
    ## storage slots for alrady ownloaded accounts
    stateRoot*: StateRoot               ## Dedicated sub-type for `Hash32`
    blockHash*: BlockHash               ## Corresponds to `stateRoot`
    blockNumber*: BlockNumber           ## Corresponds to `stateRoot`
    unproc: UnprocItemKeys              ## Unprocessed accounts
    byAccount: DataByAccount            ## List of storage/code states to fetch
    healingReady: bool                  ## Ready for healing if `true`
    deadState: bool                     ## State was evicted from database

  StateDbRef* = ref object
    ## Download states db
    unproc: ItemKeyRangeSet             ## Globally unprocessed accounts
    carryOver: float                    ## Number of `unproc` resets/re-inits
    topNum: BlockNumber                 ## Latest observed block number
    byRank: StateByRank                 ## States indexed by some ranking
    byHash: StateByHash                 ## States indexed by block hash
    byRoot: StateByRoot                 ## States indexed by state root

func accountsCoverage*(db: StateDbRef): float

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func rankIndex(state: StateDataRef): StateRankIndex =
  (state.unproc.total(), state.blockNumber).to(StateRankIndex)

proc updateRank(
    db: StateDbRef;
    oldInx: StateRankIndex;
    state: StateDataRef) =
  ## Update DB ranking index. The argument `oldInx` is the index of
  ## argument `state` (i.e. `state.rankIndex` prior to any change.
  let newInx = state.rankIndex
  if oldInx != newInx:
    discard db.byRank.delete oldInx
    db.byRank.findOrInsert(newInx).value.data = state

proc rollBackAccounts(db: StateDbRef, state: StateDataRef) =
  ## Roll back global unproc register (as best as possible)
  var carry = 0.u256
  for iv in state.unproc.unprocessed.complement.increasing:
    carry += (iv.len - db.unproc.merge iv)        # hand back processed ranges
  db.carryOver -= carry.per256                    # adjust by carry over field
  let totalRatio = db.unproc.totalRatio
  if db.carryOver < totalRatio - 1f:              # maybe some rounding errors?
    db.carryOver = totalRatio - 1f

proc evict(db: StateDbRef, state: StateDataRef, info: static[string]) =
  ## Remove state from database and update range accounting. This may
  ## reset the `db.pivot` state to `nil`.
  ##
  discard db.byRank.delete state.rankIndex          # ditto
  db.byHash.del state.blockHash                     # ..
  db.byRoot.del state.stateRoot
  state.deadState = true                            # mark it evicted
  db.rollBackAccounts state


proc resetMetrics(db: StateDbRef) =
  metrics.set(nec_snap_accumulated_state_coverage, 0f)
  metrics.set(nec_snap_pivot_state_coverage, 0f)
  metrics.set(nec_snap_active_states, 0)

proc updateMetrics(db: StateDbRef) =
  metrics.set(nec_snap_accumulated_state_coverage, db.accountsCoverage())
  metrics.set(nec_snap_active_states, db.byRoot.len)
  db.byRank.ge(low StateRankIndex).isErrOr():
    metrics.set(nec_snap_pivot_state_coverage,
                (1f - value.data.unproc.totalRatio))

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type StateDbRef): T =
  let db = T(
    unproc:   ItemKeyRangeSet.init ItemKeyRangeMax,
    byRank:    StateByRank.init state_rank_index.cmp)
  db.resetMetrics()
  db

proc clear*(db: StateDbRef) =
  db.carryOver = 0f
  db.topNum = BlockNumber(0)
  db.unproc.clear
  db.byRank.clear
  db.byHash.clear
  db.byRoot.clear
  db.resetMetrics()

# ------------------------------------------------------------------------------
# Public database root state functions
# ------------------------------------------------------------------------------

proc register*(
    db: StateDbRef;
    root: StateRoot;
    hash: BlockHash;
    number: BlockNumber;
    info: static[string];
      ): StateDataRef =
  ## Update or register new account state record on database. The result is
  ## the current state record, or the new one created (not `nil`.)
  ##
  db.byRoot.withValue(root, value):
      return value[]                                # nothing to do

  if db.topNum < number:                            # largest known block num
    db.topNum = number

  # New state record
  var newState = StateDataRef(
    stateRoot:   root,
    blockHash:   hash,
    blockNumber: number,
    byAccount:   DataByAccount.init())
  newState.unproc.init ItemKeyRangeMax

  # Move block height window when necessary.
  if stateDbCapacity <= db.byRoot.len:
    # Clear item with the largest unprocessed data range
    let lowest = db.byRank.le(high StateRankIndex).value.data
    db.evict(lowest, info)                          # remove index columns

  # Add `newState` to database
  db.byRank.findOrInsert(newState.rankIndex).value.data = newState
  db.byHash[hash] = newState
  db.byRoot[root] = newState

  newState                                          # return state record


func hasKey*(db: StateDbRef ; hash: BlockHash): bool =
  db.byHash.hasKey(hash)

func hasKey*(db: StateDbRef; root: StateRoot): bool =
  db.byRoot.hasKey(root)

func get*(db: StateDbRef; hash: BlockHash): Opt[StateDataRef] =
  db.byHash.withValue(hash, value):
    return ok value[]
  err()

func get*(db: StateDbRef; root: StateRoot): Opt[StateDataRef] =
  db.byRoot.withValue(root, value):
    return ok value[]
  err()

func pivot*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with a minimal unprocessed interval range.
  db.byRank.ge(low StateRankIndex).isErrOr():
    return ok value.data
  err()

func lowest*(db: StateDbRef): Opt[StateDataRef] =
  ## Return lowest ranked state, ot `nil` if the DB is empty
  db.byRank.le(high StateRankIndex).isErrOr():
    return ok value.data
  err()

func top*(db: StateDbRef): BlockNumber =
  ## If positive, the function returns the largest block number known to the
  ## DB. This number will not refer to a retrievable state from the DB if the
  ## state was evicted.
  db.topNum

func len*(db: StateDbRef): int =
  db.byRank.len


proc setHealingReady*(state: StateDataRef) =
  state.healingReady = true

proc getHealingReady*(state: StateDataRef): bool =
  state.healingReady


proc isOperable*(state: StateDataRef): bool =
  ## Check whether the state has not been evicted
  not state.deadState

proc isComplete*(state: StateDataRef): bool =
  ## Check whether the state is complete
  if not state.deadState and
     state.unproc.unprocessed.chunks() == 0 and     # all accounts done with
     0 < state.byAccount.len:                       # no more slots or code
    return true
  # false

func accountsCoverage*(db: StateDbRef): float =
  ## Coverage of accounts over all states
  max(0f, 1f - db.unproc.totalRatio + db.carryOver)

func accountsCoverage*(state: StateDataRef): float =
  ## Coverage of accounts for a particular state
  if not state.deadState:
    return 1f - state.unproc.unprocessed.totalRatio # ignores `borrowed` items
  # 0f

# ------------------------------------------------------------------------------
# Public unprocessed account ranges administration
# -----------------------------------------------------------------------------

proc fetchAccountRange*(
    db: StateDbRef;
    state: StateDataRef;                            # current state record
      ): Opt[ItemKeyRange] =
  ## Fetch an interval from the list of unprocessed account ranges. The
  ## returned account intervals for different `state` arguments will not
  ## overlap up until the range `0..2^256` is fully covered.
  ##
  ## If the state was evicted from the database, `err()` (for `none`) is
  ## returned.
  ##
  if state.deadState or                             # evicted
     state.unproc.avail().isErr():                  # all done this state
    return err()

  # Carry over empty register and re-initialise
  if db.unproc.chunks == 0:
    db.carryOver += 1f
    db.unproc = ItemKeyRangeSet.init ItemKeyRangeMax

  # Fetch interval from state, coordinated by the global register. This results
  # in minimal overlap of processed intervals over all active states.
  var
    restore: seq[ItemKeyRange]                      # temp. blocked items
    iRange: ItemKeyRange                            # return value
  while true:
    let giv = db.unproc.fetchLeast(unprocAccountsRangeMax).valueOr:
      # No overlapping data, fetch directly from `state`
      iRange = state.unproc.fetchLeast(unprocAccountsRangeMax)
                           .expect "Valid state range"
      break
    # Fetch this interval from local range set
    state.unproc.fetchSubRange(giv).isErrOr:
      iRange = value
      # Unused ranges, subsets of `giv`
      if giv.minPt < value.minPt:
        discard db.unproc.merge(giv.minPt, value.minPt-1)
      if value.maxPt < giv.maxPt:
        discard db.unproc.merge(value.maxPt+1, giv.maxPt)
      break
    restore.add giv

  # Restore temporarily locked intervals
  for iv in restore:
    discard db.unproc.merge iv                      # restore global range

  ok iRange

proc rollbackAccountRange*(
    db: StateDbRef;
    state: StateDataRef;                            # current state record
    iv: ItemKeyRange;                               # from `fetchAccountRange()`
      ) =
  ## Pass back the argument`iv` (as returned from `fetchAccountRange()`) to
  ## the registry managing unprocessed ranges.
  ##
  if not state.deadState:
    state.unproc.commit(iv, iv)
    discard db.unproc.merge(iv)

proc commitAccountRange*(
    db: StateDbRef;
    state: StateDataRef;                            # current state record
    iv: ItemKeyRange;                               # from `fetchAccountRange()`
    limit: ItemKey;                                 # greatst account fetched
      ) =
  ## Remove the completed interval `iv.minPt..limit`, and restore non-completed
  ## parts `limit+1..iv.maxPt` on the registry managing unprocessed ranges.
  ##
  ## This function also updates the ranking.
  ##`
  if not state.deadState:
    let oldInx = state.rankIndex
    if limit < iv.maxPt:
      state.unproc.commit(iv, limit + 1, iv.maxPt)
      discard db.unproc.merge(limit + 1, iv.maxPt)

    elif iv.maxPt < limit:
      state.unproc.commit(iv)
      state.unproc.overCommit(iv.maxPt + 1, limit)
      discard db.unproc.reduce(iv.maxPt + 1, limit)

    else: # iv.maxPt == limit
      state.unproc.commit(iv)

    # Carry over empty register and re-initialise
    if db.unproc.chunks == 0:
      db.carryOver += 1f
      db.unproc = ItemKeyRangeSet.init ItemKeyRangeMax

    db.updateRank(oldInx, state)                    # update ranking
    db.updateMetrics()

proc setAccountRange*(
    db: StateDbRef;
    state: StateDataRef;
    start: ItemKey;
    limit: ItemKey;
      ) =
  ## The function sets an account range and commits it immediately.
  ##
  if not state.deadState:
    let oldInx = state.rankIndex
    state.unproc.overCommit(start, limit)
    db.carryOver += (limit - start + 1 - db.unproc.reduce(start, limit)).per256

    # Carry over empty register and re-initialise
    if db.unproc.chunks == 0:
      db.carryOver += 1f
      db.unproc = ItemKeyRangeSet.init ItemKeyRangeMax

    db.updateRank(oldInx, state)                    # update ranking
    db.updateMetrics()

# ------------------------------------------------------------------------------
# Public storage slots and code database function(s)
# ------------------------------------------------------------------------------

proc register*(
    state: StateDataRef,
    account: ItemKey,
    stoRoot: StoreRoot,
    iv = ItemKeyRangeMax) =
  ## Add storage slots to an account (if any.)
  ##
  if not state.deadState and
     stoRoot != StoreRoot(EMPTY_ROOT_HASH):
    var data: AccDataRef
    let rc = state.byAccount.eq(account)
    if rc.isOk:
      data = rc.value.data
    else:
      data = AccDataRef(code: CodeHash(EMPTY_CODE_HASH))
      state.byAccount.insert(account).value.data = data
    data.stoRoot = stoRoot
    data.stoLeft = iv

proc register*(
    state: StateDataRef,
    account: ItemKey,
    codeHash: CodeHash) =
  ## Add contract hash to an account (if any.)
  ##
  if not state.deadState and
     codeHash != CodeHash(EMPTY_CODE_HASH):
    var data: AccDataRef
    let rc = state.byAccount.eq(account)
    if rc.isOk:
      data = rc.value.data
    else:
      data = AccDataRef(stoRoot: StoreRoot(EMPTY_ROOT_HASH))
      state.byAccount.insert(account).value.data = data
    data.code = codeHash


func get*(state: StateDataRef, account: ItemKey): Opt[AccDataRef] =
  if not state.deadState:
    state.byAccount.eq(account).isErrOr:
      return ok(value.data)
  err()

func hasKey*(state: StateDataRef, account: ItemKey): bool =
  not state.deadState and state.byAccount.eq(account).isOk()


proc delStorage*(state: StateDataRef, account: ItemKey) =
  if not state.deadState:
    let kv = state.byAccount.eq(account).valueOr:
      return
    if kv.data.code == CodeHash(EMPTY_CODE_HASH):
      discard state.byAccount.delete account
    else:
      kv.data.stoRoot = StoreRoot(EMPTY_ROOT_HASH)

proc delCode*(state: StateDataRef, account: ItemKey) =
  if not state.deadState:
    let kv = state.byAccount.eq(account).valueOr:
      return
    if kv.data.stoRoot == StoreRoot(EMPTY_ROOT_HASH):
      discard state.byAccount.delete account
    else:
      kv.data.code = CodeHash(EMPTY_CODE_HASH)

func hasCodeOrStorage*(state: StateDataRef): bool =
  not state.deadState and 0 < state.byAccount.len

# ------------------------------------------------------------------------------
# Public iterator(s)
# ------------------------------------------------------------------------------

iterator stoItems*(
    state: StateDataRef;
    maxItems = high(int);
      ): tuple[key: ItemKey, data: AccDataRef] =
  ## Iterate over all account entries with increasing `ItemKey` keys and
  ## return non-empty storage tree information.
  ##
  ## This iterator is resilient against changes of the code base. Yet, after
  ## adding entries with keys smaller than the last returned `key`, these
  ## entries will be missed through the current cycle.
  ##
  var
    count = 0
    rc = state.byAccount.ge(low ItemKey)
  while rc.isOk and count < maxItems:
    count.inc
    let (key, data) = (rc.value.key, rc.value.data)
    if data.stoRoot != StoreRoot(EMPTY_ROOT_HASH):
      yield (key, data)
    rc = state.byAccount.gt(key)

iterator codeItems*(
    state: StateDataRef;
    maxItems = high(int);
      ): tuple[key: ItemKey, data: AccDataRef] =
  ## Similar to `stoItems()` but for codes.
  ##
  var
    count = 0
    rc = state.byAccount.ge(low ItemKey)
  while rc.isOk and count < maxItems:
    count.inc
    let (key, data) = (rc.value.key, rc.value.data)
    if data.code != CodeHash(EMPTY_CODE_HASH):
      yield (key, data)
    rc = state.byAccount.gt(key)

iterator items*(
    db: StateDbRef;
    startWith = seq[StateRoot].default;
      ): StateDataRef =
  ## Iterate over all `db` entries with decreasing rank, the pivot state
  ## first which has the hihgest rank.
  ##
  ## If the argument `startWith` is set, the corresponding records are yielded
  ## first, followed by the rest of the database entries without the
  ## `startWith` entries.
  ##
  var seenItems: HashSet[BlockNumber]
  for w in startWith.items:
    db.byRoot.withValue(w,value):
      if value.blockNumber notin seenItems:
        seenItems.incl value.blockNumber
        yield value[]

  var rc = db.byRank.ge(low StateRankIndex)
  while rc.isOk:
    let (key, data) = (rc.value.key, rc.value.data)
    if data.blockNumber notin seenItems:
      yield data
    rc = db.byRank.gt(key)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

func bnStr*(state: StateDataRef): string =
  $state.blockNumber

func bnStr*(rc: Opt[StateDataRef]): string =
  if rc.isErr: "n/a" else: $rc.value.blockNumber

func rootStr*(state: StateDataRef): string =
  state.stateRoot.Hash32.short & "(" & $state.blockNumber & ")"

func toStr*(db: seq[StateDataRef]): string =
  ## Print a list of processed ranges for the argument stats.
  "{" & db.mapIt(
    $it.blockNumber & "^" &
    it.unproc.unprocessed.complement.toStr).join(",") & "}"

func toStr*(db: StateDbRef): string =
  if db.byRank.len == 0:
    return "n/a"

  let
    base2 = (db.topNum div 100) * 100
    base3 = (db.topNum div 1000) * 1000
    base4 = (db.topNum div 10000) * 10000

  var walk = WalkByRank.init(db.byRank)
  defer: walk.destroy()

  result = $db.topNum & "->{"
  var rc = walk.first
  while rc.isOk:
    let state = rc.value.data
    rc = walk.next

    if 0 < base2 and base2 <= state.blockNumber:
      result &= &"{(state.blockNumber - base2):02}"
    elif 0 < base3 and base3 <= state.blockNumber:
      result &= &"{(state.blockNumber - base3):03}"
    elif 0 < base4 and base4 <= state.blockNumber:
      result &= &"{(state.blockNumber - base4):04}"
    else:
      result &= $state.blockNumber

    result &= ":" & state.accountsCoverage.toPC(6)
    result &= "+" & $state.byAccount.len
    result &= ","
  result[^1] = '}'

  result &= ":" & db.accountsCoverage.toPC(6)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
