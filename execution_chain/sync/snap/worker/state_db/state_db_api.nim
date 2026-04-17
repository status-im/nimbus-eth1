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
  std/[hashes, sequtils, sets, strutils, tables],
  pkg/[chronicles, chronos, eth/common, metrics],
  pkg/stew/[interval_set, sorted_set],
  ../[helpers, worker_const],
  ./[state_identifiers, state_item_key, state_rank_index,
     state_unproc_item_keys]

logScope:
  topics = "snap sync"

declareGauge nec_snap_accumulated_states_coverage, "" &
  "Factor of accumulated account ranges covered over all state root records"

declareGauge nec_snap_pivot_state_coverage, "" &
  "Max factor of account ranges covered related to a single state root"

declareGauge nec_snap_archived_states_coverage, "" &
  "Factor of archived account ranges covered"

declareGauge nec_snap_active_states, "" &
  "Number of active state root indexed caches to download to"

type
  StateByRank = SortedSet[StateRankIndex,StateDataRef]
    ## List of incomplete states downloaded from the `snap` network

  WalkByRank = SortedSetWalkRef[StateRankIndex,StateDataRef]
    ## Quick traversal descriptor

  StateByRoot = Table[StateRoot,StateDataRef]
    ## Similar list as above, indexed by state root

  StateByTouch = SortedSet[Moment,StateDataRef]
    ## Similar list as above, indexed by state root

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
    touch*: Moment                      ## Last time the record was changed
    unproc: UnprocItemKeys              ## Unprocessed accounts
    byAccount: DataByAccount            ## List of storage/code states to fetch
    healingReady: bool                  ## Ready for healing if `true`
    deadState: bool                     ## State was evicted from database

  StateDbRef* = ref object
    ## Download states db
    allUnproc: ItemKeyRangeSet          ## Globally unprocessed accounts
    carryOver: float                    ## Overflow coverage
    archived: float                     ## Evicted states coverage
    start: Moment                       ## Initalisation time
    topNum: BlockNumber                 ## Latest observed block number
    byRank: StateByRank                 ## States indexed by some ranking
    byRoot: StateByRoot                 ## States indexed by state root
    byTouch: StateByTouch               ## States indexed by last update

func rootStr*(state: StateDataRef): string
func accountsCoverage*(db: StateDbRef): float
func accountsCoverage*(state: StateDataRef): float

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc toStr(state: StateDataRef, db: StateDbRef, stateRootOk: bool): string =
  let cov = state.accountsCoverage
  if stateRootOk:
    result = state.rootStr
  else:
    result = $state.blockNumber
  result &=
    "^" & $(db.topNum - state.blockNumber) &
    "@" & (state.touch - db.start).toStr &
    ":" & (if cov == 0f: "0" else: cov.toPC(6)) &
    "+" & $state.byAccount.len

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func rankIndex(state: StateDataRef): StateRankIndex =
  (state.unproc.total(), state.blockNumber).to(StateRankIndex)

proc insert(
    db: StateDbRef;
    state: StateDataRef;
    ignoreRoot: static[bool] = false;
      ) =
  ## Savely a new state to the DB. If the argument `ignoreRoot` is passed as
  ## `false`, the root table `byRoot[]` will be ignored and not be saved.
  ##
  when not ignoreRoot:
    db.byRoot[state.stateRoot] = state

  # An index collision of rank keys is avoided by having the block number as
  # part of the `rankIndex` key.
  db.byRank.insert(state.rankIndex).value.data = state

  block safeInsert:
    while true:
      # Make sure that the time stamp is not used, yet.
      db.byTouch.insert(state.touch).isErrOr:
        value.data = state
        break safeInsert
      state.touch += chronos.nanoseconds(1)

proc updateRankAndTouch(
    db: StateDbRef;
    oldInx: StateRankIndex;
    state: StateDataRef;
    touch: Moment;
      ) =
  ## Update DB ranking index. The argument `oldInx` is the index of
  ## argument `state` (i.e. `state.rankIndex` prior to any change.
  ##
  let newInx = state.rankIndex
  if oldInx != newInx:
    discard db.byRank.delete oldInx
    discard db.byTouch.delete state.touch
    state.touch = touch
    db.insert(state, ignoreRoot=true)

proc evict(db: StateDbRef, state: StateDataRef, info: static[string]) =
  ## Remove state from database and update range accounting. This may
  ## reset the `db.pivot` state to `nil`.
  ##
  discard db.byTouch.delete state.touch             # remove state index
  discard db.byRank.delete state.rankIndex          # ditto
  db.byRoot.del state.stateRoot                     # ..

  # Roll back global `allUnproc`/`carryOver` registers. The acoounting goes as
  # follows:
  #
  # * Processed intervals are not turned back as intervals, but the total
  #   ratio is removed from the `carryOver` register.
  #
  # * The same total ratio is added to the archived register.
  #
  var processedRatio = 1f - state.unproc.totalRatio()
  db.carryOver -= processedRatio                    # roll back
  db.archived += processedRatio                     # roll forward
  state.deadState = true                            # mark state evicted


proc allUnprocRollOverIfEmpty(db: StateDbRef) =
  ## Roll over empty register and re-initialise
  if db.allUnproc.chunks == 0:
    db.carryOver += 1f
    db.allUnproc = ItemKeyRangeSet.init ItemKeyRangeMax

proc resetMetrics(db: StateDbRef) =
  metrics.set(nec_snap_archived_states_coverage, 0f)
  metrics.set(nec_snap_accumulated_states_coverage, 0f)
  metrics.set(nec_snap_active_states, 0)
  metrics.set(nec_snap_pivot_state_coverage, 0f)

proc updateMetrics(db: StateDbRef) =
  metrics.set(nec_snap_archived_states_coverage, db.archived)
  metrics.set(nec_snap_accumulated_states_coverage, db.accountsCoverage())
  metrics.set(nec_snap_active_states, db.byRoot.len)
  db.byRank.ge(low StateRankIndex).isErrOr():
    metrics.set(nec_snap_pivot_state_coverage,
                (1f - value.data.unproc.totalRatio))

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type StateDbRef): T =
  let db = T(
    start:     Moment.now(),
    allUnproc: ItemKeyRangeSet.init ItemKeyRangeMax,
    byTouch:   StateByTouch.init(),
    byRank:    StateByRank.init state_rank_index.cmp)
  db.resetMetrics()
  db

proc clear*(db: StateDbRef) =
  db.start = Moment.now()
  db.carryOver = 0f
  db.archived = 0f
  db.topNum = BlockNumber(0)
  db.allUnproc.clear
  db.byRank.clear
  db.byRoot.clear
  db.byTouch.clear
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
    return value[]                                  # nothing to do

  if db.topNum < number:                            # largest known block num
    db.topNum = number

  let now = Moment.now()

  # Make certain that there is space on the DB
  if stateDbCapacity <= db.byRoot.len:
    # Make space for a new record.
    #
    # * If there most idle state was last updated before
    # `stateIdleTimeBeforeEviction`, then remove this one.
    #
    # * Otherwise, if there lowest rank record is completely untouched (i.e.
    #   no account ranges processed, yet), then remove this one.
    #
    # * Oterwise remove the most idle state (even if it was not idle for
    #   the time of `stateIdleTimeBeforeEviction`.)
    #
    var state = db.byTouch.ge(low Moment).value.data
    if now <= state.touch + stateIdleTimeBeforeEviction:
      # Try whether there is some low rank unused record
      let leastRank = db.byRank.le(high StateRankIndex).value
      if leastRank.key.total ==  high(UInt256):     # all unprocessed?
        state = leastRank.data
    db.evict(state, info)                           # remove index columns

  # Add new state record to database
  var newState = StateDataRef(
    touch:       now,
    stateRoot:   root,
    blockHash:   hash,
    blockNumber: number,
    byAccount:   DataByAccount.init())
  newState.unproc.init ItemKeyRangeMax
  db.insert newState

  newState                                          # return state record


func hasKey*(db: StateDbRef; root: StateRoot): bool =
  db.byRoot.hasKey root

func get*(db: StateDbRef; root: StateRoot): Opt[StateDataRef] =
  db.byRoot.withValue(root, value):
    return ok value[]
  err()

func pivot*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with a minimal unprocessed interval range.
  db.byRank.ge(low StateRankIndex).isErrOr():
    return ok value.data
  err()

func top*(db: StateDbRef): BlockNumber =
  ## If positive, the function returns the largest block number known to the
  ## DB. This number will not refer to a retrievable state from the DB if the
  ## state was evicted.
  db.topNum

func len*(db: StateDbRef): int =
  db.byRoot.len


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

func archivedCoverage*(db: StateDbRef): float =
  ## Coverage of accounts over all states stored on disk
  db.archived

func accountsCoverage*(db: StateDbRef): float =
  ## Coverage of cached accounts over all states
  max(0f, 1f - db.allUnproc.totalRatio + db.carryOver)

func accountsCoverage*(state: StateDataRef): float =
  ## Coverage of cached accounts for a particular state
  if not state.deadState:
    return 1f - state.unproc.unprocessed.totalRatio # ignores `borrowed` items
  # 0f

func accountsCov256*(state: StateDataRef): UInt256 =
  ## Variant of `accountsCoverage()`
  let unproc = state.unproc.unprocessed.total
  if unproc == 0:
    # Here `chunks==0` => `2^256-0` is mapped to `2^256 - 1` == `high(u256)`
    return (if state.unproc.unprocessed.chunks == 0: high(UInt256) else: 0.u256)
  (high(UInt256) - unproc) + 1

# ------------------------------------------------------------------------------
# Public unprocessed account ranges administration
# ------------------------------------------------------------------------------

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

  # Fetch interval from state, coordinated by the global register. This results
  # in minimal overlap of processed intervals over all active states.
  var
    restore: seq[ItemKeyRange]                      # temp. blocked items
    iRange: ItemKeyRange                            # return value
  while true:
    let giv = db.allUnproc.fetchLeast(unprocAccountsRangeMax).valueOr:
      # No overlapping data, fetch directly from `state`
      iRange = state.unproc.fetchLeast(unprocAccountsRangeMax)
                           .expect "Valid state range"
      db.carryOver += iRange.len.per256             # register as overflow
      break
    # Fetch this interval from local range set
    state.unproc.fetchSubRange(giv).isErrOr:
      iRange = value
      # Unused ranges, subsets of `giv`
      if giv.minPt < value.minPt:
        discard db.allUnproc.merge(giv.minPt, value.minPt-1)
      if value.maxPt < giv.maxPt:
        discard db.allUnproc.merge(value.maxPt+1, giv.maxPt)
      break
    restore.add giv

  # Restore temporarily locked intervals
  for iv in restore:
    discard db.allUnproc.merge iv                   # restore global range

  db.allUnprocRollOverIfEmpty()                     # global register roll over
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
    db.carryOver -= (iv.len - db.allUnproc.merge(iv)).per256

proc commitAccountRange*(
    db: StateDbRef;
    state: StateDataRef;                            # current state record
    iv: ItemKeyRange;                               # from `fetchAccountRange()`
    limit: ItemKey;                                 # greatst account fetched
    touch: Moment;
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
      db.carryOver -= (iv.maxPt - limit -
                       db.allUnproc.merge(limit + 1, iv.maxPt)).per256

    elif iv.maxPt < limit:
      state.unproc.commit(iv)
      state.unproc.overCommit(iv.maxPt + 1, limit)
      db.carryOver += (limit - iv.maxPt -
                       db.allUnproc.reduce(iv.maxPt + 1, limit)).per256

    else: # iv.maxPt == limit
      state.unproc.commit(iv)

    db.updateRankAndTouch(oldInx, state, touch)     # update ranking
    db.allUnprocRollOverIfEmpty()                   # global register roll over
    db.updateMetrics()

proc setAccountRange*(
    db: StateDbRef;
    state: StateDataRef;
    start: ItemKey;
    limit: ItemKey;
    touch: Moment;
      ) =
  ## The function sets an account range and commits it immediately.
  ##
  if not state.deadState:
    let oldInx = state.rankIndex
    state.unproc.overCommit(start, limit)
    db.carryOver += (limit - start + 1 -
                     db.allUnproc.reduce(start, limit)).per256

    db.updateRankAndTouch(oldInx, state, touch)     # update ranking
    db.allUnprocRollOverIfEmpty()                   # global register roll over
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
    ignoreLe = BlockNumber(0);
      ): StateDataRef =
  ## Iterate over all `db` entries with decreasing rank selecting the pivot
  ## state first, which has the hihgest rank. If the block number of the
  ## selected does not exceed the argument `ignoreLe`, it is discarded.
  ##
  ## If the argument `startWith` is set, the corresponding records are yielded
  ## first, followed by the rest of the database entries without the
  ## `startWith` entries.
  ##
  var seenItems: HashSet[BlockNumber]
  for w in startWith.items:
    db.byRoot.withValue(w,value):
      if value.blockNumber notin seenItems and ignoreLe < value.blockNumber:
        seenItems.incl value.blockNumber
        yield value[]

  var rc = db.byRank.ge(low StateRankIndex)
  while rc.isOk:
    let (key, data) = (rc.value.key, rc.value.data)
    if data.blockNumber notin seenItems and ignoreLe < data.blockNumber:
      yield data
    rc = db.byRank.gt(key)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

func bnStr*(rc: Opt[StateDataRef]): string =
  if rc.isErr: "n/a" else: $rc.value.blockNumber

func rootStr*(state: StateDataRef): string =
  state.stateRoot.Hash32.short & "(" & $state.blockNumber & ")"

proc toStr*(state: StateDataRef, db: StateDbRef): string =
  state.toStr(db, stateRootOk = true)

proc toStr*(db: StateDbRef): string =
  if db.byRoot.len == 0:
    return "n/a"
  var walk = WalkByRank.init(db.byRank)
  defer: walk.destroy()

  result = $db.topNum & "->{"
  var rc = walk.first
  while rc.isOk:
    let state = rc.value.data
    rc = walk.next
    result &= state.toStr(db, stateRootOk=false) & ","
  result[^1] = '}'
  result &=
    ":" & db.accountsCoverage.toPC(6) &
    ":" & db.archived.toPC(6)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
