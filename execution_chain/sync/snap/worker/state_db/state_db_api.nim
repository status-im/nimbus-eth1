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
  ./[state_identifiers, state_item_key, state_unproc_item_keys]

logScope:
  topics = "snap sync"

declareGauge nec_snap_acc_coverage, "" &
  "Factor of accumulated accounts covered over all state roots"

declareGauge nec_snap_max_acc_state_coverage, "" &
  "Max factor of accounts covered related to a single state root"

type
  StateByNumber = SortedSet[BlockNumber,StateDataRef]
    ## List of incomplete states downloaded from the `snap` network

  WalkByNumber = SortedSetWalkRef[BlockNumber,StateDataRef]
    ## Quick traversal descriptor (internal descriptor)

  StateByRoot = Table[StateRoot,StateDataRef]
    ## Same list as above, LRU, indexed by state root

  StateByHash = Table[BlockHash,StateDataRef]
    ## Same list as above, no LRU features used, indexed by block hashes

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
    overlays: uint                      ## Number of `unproc` resets/re-inits
    pivot: StateDataRef                 ## Least unproc data
    byNumber: StateByNumber             ## States indexed by block number
    byHash: StateByHash                 ## States indexed by block hash
    byRoot: StateByRoot                 ## States indexed by state root

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc maxUnproc(db: StateDbRef): StateDataRef =
  ## Find the DB record with the maximal unprocessed interval range. If there
  ## are more than one items with the same  range, the one with the smaller
  ## block number is returned.
  ##
  var
    walk = WalkByNumber.init(db.byNumber)
    rc = walk.first
  defer: walk.destroy
  if rc.isErr:
    return StateDataRef(nil)

  # Preset `result` to cover the case when all entries have the same
  # total unprocessed size of what is to be done.
  result = rc.value.data
  var todo = low(UInt256)

  while rc.isOk:
    # Here: err() means zero => nothing more to do
    rc.value.data.unproc.total.isErrOr:
      if value == 0:
        # Here: `0 => 2^256`, nothing done yet (you cannot beat that.) As
        # the loop runs with increasing block height, the least block number
        # is preferred in case there are more than one `2^256` todo entries.
        return rc.value.data
      if todo < value:
        result = rc.value.data
      todo = value
    rc = walk.next

proc updateMetrics(db: StateDbRef) =
  let topCoverage = 1f - db.pivot.unproc.totalRatio
  metrics.set(nec_snap_acc_coverage,
    # There is no `borrowed` sub-register for the total coverage register. So
    # it might be temporarily below `topCoverage`. As this would make metrics
    # confusing, it is maxed out, here.
    max(topCoverage, (1f - db.unproc.totalRatio) * (1 + db.overlays).float))
  metrics.set(nec_snap_max_acc_state_coverage, topCoverage)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type StateDbRef): T =
  let db = T(
    unproc:   ItemKeyRangeSet.init ItemKeyRangeMax,
    byNumber: StateByNumber.init())
  metrics.set(nec_snap_acc_coverage, 0f)
  metrics.set(nec_snap_max_acc_state_coverage, 0f)
  db

proc clear*(db: StateDbRef) =
  db.overlays = 0
  db.pivot = StateDataRef(nil)
  db.unproc.clear
  db.byNumber.clear
  db.byNumber.clear
  db.byHash.clear
  db.byRoot.clear
  metrics.set(nec_snap_acc_coverage, 0f)
  metrics.set(nec_snap_max_acc_state_coverage, 0f)

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
  proc del(db: StateDbRef, state: StateDataRef) =
    discard db.byNumber.delete state.blockNumber    # delete index
    db.byHash.del state.blockHash                   # ditto
    db.byRoot.del state.stateRoot                   # ...
    if db.pivot == state:
      db.pivot = StateDataRef(nil)
    debug info & ": evicted state record", root=state.rootStr, hash=hash.toStr
    # Roll back global unproc register
    for iv in state.unproc.unprocessed.complement.increasing:
      discard db.unproc.merge(iv)                   # hand back interval
    state.deadState = true                          # mark it evicted

  db.byNumber.eq(number).isErrOr:
    if value.data.blockHash == hash:
      return value.data                             # already registered
    # Otherwise, the entry will be replaced, below
    db.del value.data                               # remove index columns

  # New state record
  var newState = StateDataRef(
    stateRoot:   root,
    blockHash:   hash,
    blockNumber: number,
    byAccount:   DataByAccount.init())
  newState.unproc.init ItemKeyRangeMax

  # Move block height window when necessary.
  if stateDbCapacity <= db.byNumber.len:
    # Clear item with the largest unprocessed data range
    db.del db.maxUnproc()                           # remove index columns

  # Add `newState` to database
  db.byNumber.findOrInsert(number).value.data = newState
  db.byHash[hash] = newState
  db.byRoot[root] = newState

  if db.pivot.isNil:
    db.pivot = newState
  else:
    db.pivot.unproc.total.isErrOr:
      if value == 0:                                # nothing done yet?
        db.pivot = newState                         # use the latest one

  newState                                          # return state record

proc register*(
    db: StateDbRef;
    header: Header;
    hash: BlockHash;
    info: static[string];
      ) =
  discard db.register(StateRoot(header.stateRoot), hash, header.number, info)


func hasKey*(db: StateDbRef; bn: BlockNumber): bool =
  db.byNumber.eq(bn).isOk()

func hasKey*(db: StateDbRef ; hash: BlockHash): bool =
  db.byHash.hasKey(hash)

func hasKey*(db: StateDbRef; root: StateRoot): bool =
  db.byRoot.hasKey(root)

func get*(db: StateDbRef; bn: BlockNumber): Opt[StateDataRef] =
  db.byNumber.eq(bn).isErrOr:
    return ok(value.data)
  err()

func get*(db: StateDbRef; hash: BlockHash): Opt[StateDataRef] =
  db.byHash.withValue(hash, value):
    return ok value[]
  err()

func get*(db: StateDbRef; root: StateRoot): Opt[StateDataRef] =
  db.byRoot.withValue(root, value):
    return ok value[]
  err()


func len*(db: StateDbRef): int =
  db.byNumber.len

func pivot*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with a minimal unprocessed interval range.
  if db.pivot.isNil:
    err()
  else:
    ok db.pivot

func top*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with the highest block number.
  let val = db.byNumber.le(high BlockNumber).valueOr:
    return err()
  ok val.data


proc setHealingReady*(state: StateDataRef) =
  state.healingReady = true

proc getHealingReady*(state: StateDataRef): bool =
  state.healingReady

proc isOperable*(state: StateDataRef): bool =
  ## Check whether the state has not been evicted
  not state.deadState

# ------------------------------------------------------------------------------
# Public unprocessed account ranges administration
# -----------------------------------------------------------------------------

proc totalAccountRange*(
    state: StateDataRef;                            # current state record
      ): Opt[UInt256] =
  ## Get the accumulated lengths of the account ranges left for downloading.
  ##
  ## Due to residue class arithmetic and limitations of the number range
  ## `UInt256`, the maximum value `2^256` is returned as `ok(0)`, while the
  ## least value `0` (i.e. nothing left) is returned as `err()`.
  ##
  ## If the state was evicted from the database, `err()` (for `0`) is
  ## returned.
  ##
  if state.deadState: err()
  else: state.unproc.total()

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
  if db.unproc.chunks == 0:
    # Re-fill global register if exhausted
    db.overlays.inc
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
        restore.add ItemKeyRange.new(giv.minPt, value.minPt-1)
      if value.maxPt < giv.maxPt:
        restore.add ItemKeyRange.new(value.maxPt+1,giv.maxPt)
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
  if not state.deadState:
    if limit < iv.maxPt:
      state.unproc.commit(iv, limit + 1, iv.maxPt)
      discard db.unproc.merge(limit + 1, iv.maxPt)

    elif iv.maxPt < limit:
      state.unproc.commit(iv)
      state.unproc.overCommit(iv.maxPt + 1, limit)
      discard db.unproc.reduce(iv.maxPt + 1, limit)

    else: # iv.maxPt == limit
      state.unproc.commit(iv)

    # Updates state record with the most account ranges processed, i.e. the
    # least unpprocessed account ranges left.
    db.pivot.unproc.total.isErrOr:                # otherwise all done
      if value == 0 or state.unproc.total.value < value:
        db.pivot = state

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
    state.unproc.overCommit(start, limit)
    discard db.unproc.reduce(start, limit)

    # Updates state record with the most account ranges processed, i.e. the
    # least unpprocessed account ranges left.
    db.pivot.unproc.total.isErrOr:                  # otherwise all done
      if value == 0 or state.unproc.total.value < value:
        db.pivot = state

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

func len*(state: StateDataRef): int =
  if not state.deadState:
    return state.byAccount.len
  # 0

# ------------------------------------------------------------------------------
# Public iterator(s)
# ------------------------------------------------------------------------------

iterator stoItems*(state: StateDataRef): tuple[key: ItemKey, data: AccDataRef] =
  ## Iterate over all account entries with increasing `ItemKey` keys and
  ## return non-empty storage tree information.
  var rc = state.byAccount.ge(low(ItemKey))
  while rc.isOk:
    let (key, data) = (rc.value.key, rc.value.data)
    if data.stoRoot != StoreRoot(EMPTY_ROOT_HASH):
      yield (key, data)
    rc = state.byAccount.gt(key)

iterator items*(
    db: StateDbRef;
    startWith = seq[StateRoot].default;
    truncate: static[bool] = false;
    ascending: static[bool] = true;
      ): StateDataRef =
  ## Iterate over all `db` entries with increasing block numbers.
  ##
  ## If the argument `startWith` is set, the corresponding records are yielded
  ## first, followed by the rest of the database entries without the
  ## `startWith` entries.
  ##
  ## By default, the argument `ascending` is set `true` and the rest of the
  ## database entries (after `startWith`) are yielded with increasing block
  ## numbers. If  `ascending` is set `false`, the rest of the database entries
  ## are yelded with decreasing block numbers.
  ##
  ## If the argument `truncate` is set `true`, the iterator yields the rest
  ## of the database up to, exluding the `startWith` entries. Otherwise, when
  ## `truncate` is set `false` (which is the default), the rest of the
  ## database is listed without the `startWith` entry.
  ##
  var seenItems: HashSet[BlockNumber]
  for w in startWith.items:
    db.byRoot.withValue(w,value):
      seenItems.incl value.blockNumber
      yield value[]

  when ascending:
    var rc = db.byNumber.ge(0)
    when truncate:

      # Iterate ascending, stop after seenItems
      while rc.isOk:
        let (key, data) = (rc.value.key, rc.value.data)
        if data.blockNumber notin seenItems:
          yield data
        elif 1 < seenItems.len:                     # check whether to continue
          seenItems.excl data.blockNumber           # remove seen item
        else:
          break                                     # stop after last seen item
        rc = db.byNumber.gt(key)
    else:

      # Iterate ascending over full list
      while rc.isOk:
        let (key, data) = (rc.value.key, rc.value.data)
        if data.blockNumber notin seenItems:
          yield data
        rc = db.byNumber.gt(key)
  else:
    var rc = db.byNumber.le(high(BlockNumber))
    when truncate:

      # Iterate descending, stop after seenItems
      while rc.isOk:
        let (key, data) = (rc.value.key, rc.value.data)
        if data.blockNumber notin seenItems:
          yield data
        elif 1 < seenItems.len:                     # check whether to continue
          seenItems.excl data.blockNumber           # remove seen item
        else:
          break                                     # stop after last seen item
        rc = db.byNumber.lt(key)
    else:

      # Iterate descending over full list
      while rc.isOk:
        let (key, data) = (rc.value.key, rc.value.data)
        if data.blockNumber notin seenItems:
          yield data
        rc = db.byNumber.lt(key)

func states*(db: StateDbRef): seq[StateDataRef] =
  ## Variant of the `items` iterator returning a sequence where the states have
  ## descending block height.
  for state in db.items(truncate = false, ascending = false):
    result.add state

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
  let
    top = db.top.valueOr:
      return "n/a"
    base2 = (top.blockNumber div 100) * 100
    base3 = (top.blockNumber div 1000) * 1000
    base4 = (top.blockNumber div 10000) * 10000

  result = $top.blockNumber & "->{"
  for state in db.items(ascending=false):
    if 0 < base2 and base2 <= state.blockNumber:
      result &= &"{(state.blockNumber - base2):02}"
    elif 0 < base3 and base3 <= state.blockNumber:
      result &= &"{(state.blockNumber - base3):03}"
    elif 0 < base4 and base4 <= state.blockNumber:
      result &= &"{(state.blockNumber - base4):04}"
    else:
      result &= $state.blockNumber
    if db.pivot == state:
      result &= "*"
    result &= ":" & state.unproc.totalRatio.toStr(4)
    result &= "(" & $state.byAccount.len & ")"
    result &= ","
  result[^1] = '}'
  result &= ":" & db.unproc.totalRatio.toStr(7) & "!" & $db.overlays

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
