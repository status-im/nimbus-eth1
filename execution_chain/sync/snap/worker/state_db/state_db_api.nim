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
  std/[hashes, sequtils, sets, tables],
  pkg/[eth/common, metrics],
  pkg/stew/[interval_set, sorted_set],
  ../[helpers, worker_const],
  ./[state_identifiers, state_item_key, state_unproc_item_keys]

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

  StateDataScore* = tuple
    up, down: uint

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
    byAccount: DataByAccount            ## List of storage states
    sdScore: StateDataScore             ## Thumbs up/down

  StateDbRef* = ref object
    ## Download states db
    unproc: ItemKeyRangeSet             ## Globally unprocessed accounts
    overlays: uint                      ## Number of `unproc` resets/re-inits
    topDone: StateDataRef               ## Least unproc data
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
  let topCoverage = 1f - db.topDone.unproc.totalRatio
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
  db.topDone = StateDataRef(nil)
  db.unproc.clear
  db.byNumber.clear
  db.byNumber.clear
  db.byHash.clear
  db.byRoot.clear
  metrics.set(nec_snap_acc_coverage, 0f)
  metrics.set(nec_snap_max_acc_state_coverage, 0f)

# ------------------------------------------------------------------------------
# Public state database function(s)
# ------------------------------------------------------------------------------

proc register*(
    db: StateDbRef;
    root: StateRoot;
    hash: BlockHash;
    number: BlockNumber;
      ): StateDataRef =
  ## Update or register new account state record on database
  ##
  proc del(db: StateDbRef, state: StateDataRef) =
    discard db.byNumber.delete state.blockNumber    # delete index
    db.byHash.del state.blockHash                   # ditto
    db.byRoot.del state.stateRoot                   # ...
    if db.topDone == state:
      db.topDone = StateDataRef(nil)

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

  if db.topDone.isNil:
    db.topDone = newState
  else:
    db.topDone.unproc.total.isErrOr:
      if value == 0:                                # nothing done yet?
        db.topDone = newState                       # use the latest one

  newState                                          # return state record

proc register*(db: StateDbRef; header: Header; hash: BlockHash) =
  discard db.register(StateRoot(header.stateRoot), hash, header.number)

proc register*(db: StateDbRef; header: Header) =
  db.register(header, BlockHash(header.computeBlockHash))



func hasKey*(db: StateDbRef; bn: BlockNumber): bool =
  db.byNumber.eq(bn).isOk()

func hasKey*(db: StateDbRef; hash: BlockHash): bool =
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



proc upScore*(data: StateDataRef) =
  data.sdScore.up.inc

proc upScore*(db: StateDbRef; number: BlockNumber): bool  =
  db.get(number).isErrOr:
    value.sdScore.up.inc
    return true

proc downScore*(data: StateDataRef) =
  data.sdScore.down.inc

proc downScore*(db: StateDbRef; number: BlockNumber): bool =
  db.get(number).isErrOr:
    value.sdScore.down.inc
    return true



func free*(db: StateDbRef): uint =
  max(0, stateDbCapacity - db.byNumber.len).uint

func len*(db: StateDbRef): int =
  db.byNumber.len

func pivot*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with a minimal unprocessed interval range.
  if db.topDone.isNil:
    err()
  else:
    ok db.topDone

func top*(db: StateDbRef): Opt[StateDataRef] =
  ## Retrieve the state data record with the highest block number.
  let val = db.byNumber.le(high BlockNumber).valueOr:
    return err()
  ok val.data

func topNum*(db: StateDbRef): BlockNumber =
  ## Retrieve the highest block number used for a state record.
  let top = db.top.valueOr:
    return BlockNumber(0)
  top.blockNumber

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
  # Re-fill global register if exhausted
  if db.unproc.chunks == 0:
    db.overlays.inc
    discard db.unproc.merge ItemKeyRangeMax
  let giv = db.unproc.fetchLeast(unprocAccountsRangeMax).expect "Account range"

  # Fetch this interval from local range set
  let liv = state.unproc.fetchSubRange(giv).valueOr:
    discard db.unproc.merge(giv)                    # restore global range
    let ljv = state.unproc.fetchLeast(unprocAccountsRangeMax).valueOr:
      return err()                                  # oops, all done here
    discard db.unproc.reduce(ljv)                   # extract from global range
    return ok(ljv)

  # Update range for `liv` subset of `giv`
  if giv.minPt < liv.minPt:
    discard db.unproc.merge(giv.minPt, liv.minPt-1)
  if liv.maxPt < giv.maxPt:
    discard db.unproc.merge(liv.maxPt, giv.maxPt-1)

  ok liv

proc rollbackAccountRange*(
    db: StateDbRef;
    state: StateDataRef;                            # current state record
    iv: ItemKeyRange;                               # from `fetchAccountRange()`
      ) =
  ## Pass back the argument`iv` (as returned from `fetchAccountRange()`) to
  ## the registry managing unprocessed ranges.
  ##
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
  db.topDone.unproc.total.isErrOr:                  # otherwise all done
    if value == 0 or state.unproc.total.value < value:
      db.topDone = state

  db.updateMetrics()

proc setAccountRange*(
    db: StateDbRef;
    state: StateDataRef;
    start: ItemKey;
    limit: ItemKey;
      ) =
  ## The function sets an account range and commits it immediately.
  ##
  state.unproc.overCommit(start, limit)
  discard db.unproc.reduce(start, limit)

  # Updates state record with the most account ranges processed, i.e. the
  # least unpprocessed account ranges left.
  db.topDone.unproc.total.isErrOr:                  # otherwise all done
    if value == 0 or state.unproc.total.value < value:
      db.topDone = state

  db.updateMetrics()

# ------------------------------------------------------------------------------
# Public storage slots database function(s)
# ------------------------------------------------------------------------------

proc register*(
    state: StateDataRef,
    account: ItemKey,
    stoRoot: StoreRoot,
    iv = ItemKeyRangeMax) =
  ## Add storage slots to an account (if any.)
  ##
  if stoRoot != StoreRoot(EMPTY_ROOT_HASH):
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
  if codeHash != CodeHash(EMPTY_CODE_HASH):
    var data: AccDataRef
    let rc = state.byAccount.eq(account)
    if rc.isOk:
      data = rc.value.data
    else:
      data = AccDataRef(stoRoot: StoreRoot(EMPTY_ROOT_HASH))
      state.byAccount.insert(account).value.data = data
    data.code = codeHash


func get*(state: StateDataRef, account: ItemKey): Opt[AccDataRef] =
  state.byAccount.eq(account).isErrOr:
    return ok(value.data)
  err()

func hasKey*(state: StateDataRef, account: ItemKey): bool =
  state.byAccount.eq(account).isOk()


proc delStorage*(state: StateDataRef, account: ItemKey) =
  let kv = state.byAccount.eq(account).valueOr:
    return
  if kv.data.code == CodeHash(EMPTY_CODE_HASH):
    discard state.byAccount.delete account
  else:
    kv.data.stoRoot = StoreRoot(EMPTY_ROOT_HASH)

proc delCode*(state: StateDataRef, account: ItemKey) =
  let kv = state.byAccount.eq(account).valueOr:
    return
  if kv.data.stoRoot == StoreRoot(EMPTY_ROOT_HASH):
    discard state.byAccount.delete account
  else:
    kv.data.code = CodeHash(EMPTY_CODE_HASH)

func len*(state: StateDataRef): int =
  state.byAccount.len

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

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

func rootStr*(state: StateDataRef): string =
  state.stateRoot.Hash32.short & "(" & $state.blockNumber & ")"

func toStr*(db: StateDbRef): string =
  let nKeys = db.byNumber.len
  if nKeys == 0:
    return "n/a"
  let
    topNum = db.topNum
    base3 = (topNum div 1000) * 1000
    base4 = (topNum div 10000) * 10000

  result = $topNum & "->{"
  for state in db.items(ascending=false):
    if 0 < base3 and base3 < state.blockNumber:
      result &= $(state.blockNumber - base3)
    elif 0 < base4 and base4 < state.blockNumber:
      result &= $(state.blockNumber - base4)
    else:
      result &= $state.blockNumber
    if db.topDone == state:
      result &= "*"
    result &= ":" & state.unproc.totalRatio.toStr(4)
    result &= "(" & $state.byAccount.len & ")"
    if 0 < state.sdScore.up or
       0 < state.sdScore.down:
      result &= $state.sdScore.up & "/" & $state.sdScore.down
    result &= ","
  result[^1] = '}'
  result &= ":" & db.unproc.totalRatio.toStr(7) & "!" & $db.overlays

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
