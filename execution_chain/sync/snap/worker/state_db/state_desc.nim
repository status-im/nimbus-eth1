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
  std/[hashes, sequtils, tables, typetraits],
  pkg/[eth/common, minilru, stew/sorted_set],
  ../[helpers, worker_const],
  ./[item_key, unproc_item_keys]

type
  StateRoot* = distinct Hash32
  BlockHash* = distinct Hash32

  StateByNumber* = SortedSet[BlockNumber,StateDataRef]
    ## List of incomplete states downloaded from the `snap` network

  StateByRoot* = LruCache[StateRoot,StateDataRef]
    ## Same list as above, LRU, indexed by state root

  StateByHash* = LruCache[BlockHash,StateDataRef]
    ## Same list as above, no LRU features used, indexed by block hashes

  EvictedStates* = seq[(BlockNumber,BlockHash)]
    ## Eviction history

  StateDataScore* = tuple
    up, down: uint

  StateDataRef* = ref object
    ## Single incomplete state
    header*: Header                     ## Block header containing state root
    blockHash*: BlockHash               ## Dedicated sub-type for `Hash32`
    unproc*: UnprocItemKeys             ## Unprocessed accounts
    sdScore: StateDataScore             ## Thumbs up/down

  StateDbRef* = ref object
    ## Incomplete states db
    pvState: StateDataRef               ## Currently active state
    byNumber: StateByNumber             ## States indexed by block number
    byHash: StateByHash                 ## States indexed by block hash
    byRoot: StateByRoot                 ## States indexed by state root

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func hash*(a: BlockHash|StateRoot): Hash =
  ## Mixin for table drivers
  hashes.hash(a.distinctBase)

func `==`*(a, b: StateRoot|BlockHash): bool = a.distinctBase == b.distinctBase
func `!=`*(a, b: StateRoot|BlockHash): bool = a.distinctBase != b.distinctBase

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template del(bn: StateByNumber, key: BlockNumber) =
  discard bn.delete key

template del(
    db: StateDbRef;
    data: StateDataRef;
    ignStateRoot: static[bool] = false;
      ) =
  db.byNumber.del data.header.number             # delete index
  db.byHash.del data.blockHash                   # ditto
  when not ignStateRoot:
    db.byRoot.del StateRoot(data.header.stateRoot)

template put(bn: StateByNumber, key: BlockNumber, sdf: StateDataRef) =
  db.byNumber.findOrInsert(key).value.data = sdf

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type StateDbRef): T =
  T(byNumber: StateByNumber.init(),
    byHash:   StateByHash.init stateDbCapacity,
    byRoot:   StateByRoot.init stateDbCapacity)

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc register*(db: StateDbRef; header: Header; blockHash: BlockHash) =
  ## Update or register new account state record on database
  ##
  db.byNumber.eq(header.number).isErrOr:
    if value.data.blockHash == blockHash:
      return                                      # already registered
    # Otherwise, the entry will be replaced, below
    db.del value.data                             # remove all data indices

  # New state record
  var newState = StateDataRef(header: header, blockHash: blockHash)
  newState.unproc.init ItemKeyRangeMax

  # Update pivot and move block height window when necessary. The pivot is
  # always at the top of the block height window.
  if db.pvState.isNil:
    db.pvState = newState
  elif db.pvState.header.number < header.number:
    db.pvState = newState
    if stateDbBlockHeightWindow < header.number:
      var rc = db.byNumber.le(header.number - stateDbBlockHeightWindow)
      while rc.isOk:
        db.del rc.value.data                      # remove all data indices
        rc = db.byNumber.lt(rc.value.key)

  # Clear least block number entry if capacity has been reached
  if db.byRoot.capacity <= db.byRoot.len:
    db.byNumber.ge(0).isErrOr:
      db.del value.data

  # Add `newState` to database
  db.byNumber.put(header.number, newState)
  db.byHash.put(blockHash, newState)
  db.byRoot.put(StateRoot(header.stateRoot), newState)

  doAssert db.byNumber.len == db.byHash.len
  doAssert db.byNumber.len == db.byRoot.len
  discard                                         # visual alignment

proc register*(db: StateDbRef; header: Header; hash: Hash32) =
  db.register(header, BlockHash(hash))

proc register*(db: StateDbRef; header: Header) =
  db.register(header, BlockHash(header.computeBlockHash))


proc get*(db: StateDbRef; height: BlockNumber): Opt[StateDataRef] =
  if not db.pvState.isNil and db.pvState.header.number == height:
    return ok(db.pvState)
  db.byNumber.eq(height).isErrOr:
    return ok(value.data)
  err()

proc get*(db: StateDbRef; hash: BlockHash): Opt[StateDataRef] =
  db.byHash.peek hash

proc get*(db: StateDbRef; root: StateRoot): Opt[StateDataRef] =
  db.byRoot.peek root


proc hasKey*(db: StateDbRef; height: BlockNumber): bool =
  if not db.pvState.isNil and db.pvState.header.number == height:
    return true
  db.byNumber.eq(height).isOk()

proc hasKey*(db: StateDbRef; hash: BlockHash): bool =
  db.byHash.peek(hash).isOk()

proc hasKey*(db: StateDbRef; root: StateRoot): bool =
  db.byRoot.peek(root).isOk()


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

# ------------------------------------------------------------------------------
# Public getter(s) and other helpers
# ------------------------------------------------------------------------------

func len*(db: StateDbRef): int =
  db.byNumber.len

func pivot*(w: StateDbRef): StateDataRef =
  w.pvState

func pvNum*(w: StateDbRef): BlockNumber =
  if w.pvState.isNil: 0 else: w.pvState.header.number


func score*(w: StateDataRef): StateDataScore =
   w.sdScore

func height*(w: StateDataRef): BlockNumber =
  w.header.number

func hash*(w: StateDataRef): BlockHash =
  w.blockHash

func root*(w: StateDataRef): StateRoot =
  StateRoot(w.header.stateRoot)

# ------------------------------------------------------------------------------
# Public iterator(s)
# ------------------------------------------------------------------------------

iterator items*(
    db: StateDbRef;
    startWith = Opt.none(StateRoot);
    truncate: static[bool] = false;
    ascending: static[bool] = true;
      ): StateDataRef =
  ## Iterate over all `db` entries with increasing block numbers.
  ##
  ## If the argument `startWith` is set, the corresponding record is yielded
  ## first, followed by the rest of the database entries without the
  ## `startWith` entry.
  ##
  ## By default, the argument `ascending` is set `true` and the rest of the
  ## database entries (after `startWith`) are yielded with increasing block
  ## numbers. If  `ascending` is set `false`, the rest of the database entries
  ## are yelded with decreasing block numbers.
  ##
  ## If the argument `truncate` is set `true`, the iterator yields the rest
  ## of the database up to, exluding the `startWith` entry. Otherwise, when
  ## `truncate` is set `false` (which is the default), the rest of the
  ## database is listed without the `startWith` entry.
  ##
  var startNum = BlockNumber(0)
  if startWith.isSome():
    db.byRoot.get(startWith.value).isErrOr:
      startNum = value.header.number
      yield value

  when ascending:
    var rc = db.byNumber.ge(0)
    when truncate:

      # Iterate ascending, stop at startNum
      while rc.isOk:
        let
          key = rc.value.key
          data = rc.value.data
        if data.header.number != startNum:
          yield data
        elif truncate:
          break
        rc = db.byNumber.gt(key)
    else:

      # Iterate ascending over full list
      while rc.isOk:
        let
          key = rc.value.key
          data = rc.value.data
        if data.header.number != startNum:
          yield data
        rc = db.byNumber.gt(key)
  else:
    var rc = db.byNumber.le(high(BlockNumber))
    when truncate:

      # Iterate descending, stop at startNum
      while rc.isOk:
        let
          key = rc.value.key
          data = rc.value.data
        if data.header.number != startNum:
          yield data
        else:
          break
        rc = db.byNumber.lt(key)
    else:

      # Iterate descending over full list
      while rc.isOk:
        let
          key = rc.value.key
          data = rc.value.data
        if data.header.number != startNum:
          yield data
        rc = db.byNumber.lt(key)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc rootStr*(data: StateDataRef): string =
  data.header.stateRoot.short & "(" & $data.header.number & ")"


func toStr*(stateRoot: StateRoot): string =
  stateRoot.Hash32.short

func toStr*(blockHash: BlockHash): string =
  blockHash.Hash32.short


proc toStr*(db: StateDbRef): string =
  let nKeys = db.byNumber.len
  if db.pvState.isNil and nKeys == 0:
    return "n/a"

  result = $db.pvNum & "->{"
  if nKeys == 0:
    result &= "}"
  else:
    let
      base3 = (db.pvNum div 1000) * 1000
      base4 = (db.pvNum div 10000) * 10000
    for data in db.items(ascending=false):
      if 0 < base3 and base3 < data.height:
        result &= $(data.height - base3)
      elif 0 < base4 and base4 < data.height:
        result &= $(data.height - base4)
      else:
        result &= $data.height
      if 0 < data.score.up or
         0 < data.score.down:
        result &= ":" & $data.sdScore.up & "/" & $data.sdScore.down
      result &= ","
    result[^1] = '}'

  result &= "[" &  $nKeys & "/" & $db.byRoot.capacity & "]"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
