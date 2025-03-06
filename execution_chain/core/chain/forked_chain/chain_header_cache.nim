# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Header Cache for Collecting Headers for Syncing Apps
## ====================================================
##
## The implemented logic here will eventually be integrated in a header
## management API of the `FC` module, e.g. accessible as `importHeader()`.
##
## The header cache is organised as a reverse stack of headers
## ::
##     <header> <- <header> <- <header> .. <- <header>
##       ^                                     ^
##       |                                     |
##     antecedent                             head
##
## where the top header is called `head` and following headers are chained by
## `parentHash` links (indicated above by `<-`.) The stack bottom entry (or
## oldest ancestor of `head`) is called `antecedent`
##
## Note that there can be only one header cache active at a time. This will
## not be checked when initialising the system.
##
## Operations:
##
## * Headers can be appended to the cache at the stack bottom away from `head`
##   (i.e. on the left end of the above diagram before `antecedent`.) There
##   can be no gaps on the header stack chain.
##
## * Headers can be deleted from the stack bottom upwards towards the `head`.
##   There can be no gaps on the header stack chain.
##
##   This most general case for deleting headers is currently not exposed.
##   For all practical cases, it is enough to provide a delete function on
##   the header chain cache for (the copy of)  the `base` header of the `FC`
##   module and all its ancestors.
##
## * Cached headers can be looked up for by block number or by hash for some
##   pre-registered hashes.
##

{.push raises:[].}

import
  std/[sequtils, strutils, tables],
  pkg/eth/[common, rlp],
  pkg/results,
  "../../.."/[common, db/core_db, db/storage_types],
  ./[chain_branch, chain_desc]

type
  FcHdrState* = object
    ante: Header               # antecedent, bottom of header chain
    head: Header               # top end of header chain, highest block number
    byHash: Table[Hash32,BlockNumber]

  ForkedCacheRef* = ref object
    ## For now, this is a replacement of `ForkedChainRef` for as long as
    ## `FcHdrState` is not integrated into `ForkedChainRef`.
    chain: ForkedChainRef
    state: FcHdrState

const
  RaisePfx = "Header Cache: "

let
  LhcStateKey = 0.beaconHeaderKey

# ------------------------------------------------------------------------------
# Private debugging and print functions
# ------------------------------------------------------------------------------

func bnStr(w: BlockNumber): string =
  "#" & $w

func bnStr(h: Header): string =
  h.number.bnStr

func toStr(fc: ForkedCacheRef): string =
  if fc.state.head.number == 0: "{}"
  else:
    let tab = ",[" & fc.state.byHash.pairs.toSeq.mapIt(
      "(" & it[0].short & "," & it[1].bnStr & ")").join(",") & "]"
    if fc.state.ante == fc.state.head: "{" & fc.state.head.bnStr & tab & "}"
    else: "{" & fc.state.ante.bnStr & ".." & fc.state.head.bnStr & tab & "}"

# ------------------------------------------------------------------------------
# Private cache helpers: RLP related
# ------------------------------------------------------------------------------

proc append(rw: var RlpWriter; state: FcHdrState) =
  ## Support for `rlp.encode(state)`
  ##
  rw.append(state.ante)
  rw.append(state.head)
  rw.startList(state.byHash.len)
  for k,v in state.byHash.pairs:
    rw.append((k,v))

proc read(rlp: var Rlp; T: type FcHdrState): T {.raises: [RlpError].} =
  ## Support for `rlp.decode(bytes)`
  ##
  result.ante = rlp.read(Header)
  result.head = rlp.read(Header)
  for w in rlp.items:
    let (k,v) = w.read((Hash32,BlockNumber))
    result.byHash[k] = v

func encodePayload[T](arg: T): seq[byte] =
  rlp.encode(arg)

func decodePayload(data: seq[byte]; T: type ): T =
  try:
    result = rlp.decode(data, T)
  except RlpError as e:
    raiseAssert RaisePfx & "rlp.decode(" & $T & ") failed: " &
      " name=" & $e.name & " error=" & e.msg

# ------------------------------------------------------------------------------
# Private cache helpers: database related
# ------------------------------------------------------------------------------

proc getState(db: CoreDbTxRef): Opt[FcHdrState] =
  let data = db.get(LhcStateKey.toOpenArray).valueOr:
    return err()
  # Ignore state decode error, might be from an earlier state version release
  var
    state: FcHdrState
  try:
    state = rlp.decode(data, FcHdrState)
  except RlpError:
    return err()
  ok(move state)

proc putState(db: CoreDbTxRef; state: FcHdrState) =
  db.put(LhcStateKey.toOpenArray, encodePayload(state)).isOkOr:
    raiseAssert RaisePfx & "put(state) failed: " & $$error

proc delState(db: CoreDbTxRef) =
  discard db.del(LhcStateKey.toOpenArray)


proc putHeader(db: CoreDbTxRef; bn: BlockNumber; data: seq[byte]) =
  ## Store rlp encoded header
  db.put(beaconHeaderKey(bn).toOpenArray, data).isOkOr:
    raiseAssert RaisePfx & "put() failed: " & $$error


proc getHeader(db: CoreDbTxRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some header from cache
  let data = db.get(beaconHeaderKey(bn).toOpenArray).valueOr:
    return err()
  ok decodePayload(data, Header)

proc getHeaderAlways(db: CoreDbTxRef; bn: BlockNumber): Header =
  ## Retrieve some header from cache, raise exception on failure
  var hdr = db.getHeader(bn).valueOr:
    raiseAssert RaisePfx & "get() failed: " & bn.bnStr
  move(hdr)


proc delHeader(db: CoreDbTxRef; bn: BlockNumber) =
  ## Remove header from cache
  discard db.del(beaconHeaderKey(bn).toOpenArray)

proc delHeaders(db: CoreDbTxRef; first, last: BlockNumber) =
  for bn in first .. last:
    discard db.del(beaconHeaderKey(bn).toOpenArray)

# ----------------------

proc persistPutState(fc: ForkedCacheRef) =
  ## Persist state records and database updates
  let
    c = fc.chain
    db = c.baseTxFrame

  # Save updated state record
  db.putState(fc.state)

  # Persist state to database
  c.com.db.persist(db)

proc persistDelUpTo(fc: ForkedCacheRef; bn: BlockNumber) =
  ## Remove headers from the lower end of the cache starting at the
  ## `antecedent` up to the argument block number.
  if fc.state.ante.number <= bn:
    let
      bn = min(bn, fc.state.head.number-1)
      db = fc.chain.baseTxFrame
      ante = fc.chain.baseTxFrame.getHeader(bn + 1).valueOr:
        raiseAssert RaisePfx & "get() failed: " & (bn + 1).bnStr

    for bn in fc.state.ante.number .. bn:
      db.delHeader bn

    # Save state
    fc.state.ante = ante

    # Save updates. persist to DB
    fc.persistPutState()

# ------------------------------------------------------------------------------
# Public heacher cache API
# ------------------------------------------------------------------------------

proc init*(fc: ForkedCacheRef; hdr = Header(); hashes = seq[Hash32].default) =
  ## Clean up DB left over data and Initialise new chain cache.
  ##
  ## If the argument `hdr` is missing or default, then any previous data
  ## will; be erased from disk (ignoring the `hashes` argument.)
  ##
  ## Otherwise, the arguments `hdr` and `hashes` will setup a new session with
  ##
  ## * `hdr` being the new `head` of the header chain
  ##
  ## * `hashes` will collect header information on the fly while appending
  ##    headers so that these headers can also be access by `Hash32` rather
  ##    than `BlockNumber` only.
  ##
  let db = fc.chain.baseTxFrame
  var persistsOk = false

  # Delete previous session (if any)
  if 0 < fc.state.head.number:
    db.delHeaders(fc.state.ante.number, fc.state.head.number)
    fc.state.reset          # clear session
    persistsOk = true       # make changes persistent

  # Start a new session.
  if 0 < hdr.number:
    db.put(beaconHeaderKey(hdr.number).toOpenArray, encodePayload(hdr)).isOkOr:
      raiseAssert RaisePfx & "put() failed: " & $$error
    fc.state.ante = hdr     # Update state record
    fc.state.head = hdr

    # Add lookup hashes
    for w in hashes:
      fc.state.byHash[w] = BlockNumber(0)

    persistsOk = true       # make changes persistent

  # Save updates. persist to DB
  if persistsOk:
    fc.persistPutState()

proc init*(
    T: type ForkedCacheRef;
    c: ForkedChainRef;
    hdr = Header();
    hashes = seq[Hash32].default;
      ): T =
  ## Constructor, variant of `init()` initialising a new header chain cache
  let
    db = c.baseTxFrame
    state = db.getState.valueOr: FcHdrState()
    fc = T(chain: c, state: state)
  fc.init(hdr, hashes)
  fc

# --------------------

proc fcHeaderGet*(fc: ForkedCacheRef; hash: Hash32): Result[Header,bool] =
  ## Retrieve header by hash. In case of failure the error code will be
  ## set `true` if the `hash` argument was registered but not available
  ## yet on the header chain, otherwise `false` to indicate that the
  ## `hash` argument was not registered.
  ##
  fc.state.byHash.withValue(hash, val):
    if fc.state.ante.number < val[]: # no need to lookup database, otherwise
      var hdr = fc.chain.baseTxFrame.getHeader(val[]).valueOr:
        return err(true)
      return ok(move hdr)
    return err(true)
  err(false)

proc fcHeaderGet*(fc: ForkedCacheRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  fc.chain.baseTxFrame.getHeader bn

proc fcHeaderGetParentHash*(fc: ForkedCacheRef; bn: BlockNumber): Opt[Hash32] =
  ## Convenience function, retrieve parent hash field from header
  let hdr = fc.chain.baseTxFrame.getHeader(bn).valueOr:
    return err()
  ok(hdr.parentHash)



proc fcHeaderPut*(
    fc: ForkedCacheRef;
    rev: openArray[Header];
      ): Result[void,string] =
  ## This function will store argument headers to the persistent header
  ## chain. The `rev[]` arguments contain the headers in reverse order as
  ## ::
  ##   rev[0]: number = lastNumber,   parentHash = rev[1].hash
  ##   rev[1]: number = lastNumber-1, parentHash = rev[2].hash
  ##   rev[2]: number = lastNumber-2, parentHash = rev[3].hash
  ##   ..
  ##
  ## The function will always check for the consistency of all of the `rev[]`
  ## argument headers. If `rev[]` overlaps with the existing headers chain,
  ## only the headers from `rev[]` that do not overlap will be saved to the
  ## database.
  ##
  ## If the `rev[]` argument is fully contained in the existing headers chain,
  ## the headers chain will be left as is (effecting only in checking the
  ## the `rev[]` argument.)
  ##
  if rev.len == 0:
    return ok()

  # Check whether argument list closes up to headers chain
  let lastNumber = rev[0].number
  if lastNumber + 1 < fc.state.ante.number:
    return err("Gap between rev[] and headers chain antecedent " &
               fc.state.ante.bnStr)

  # Must not overwrite or exceed the top end of headers chain
  if fc.state.head.number <= lastNumber:
    return err("Argument rev[] exceeds chain head " & fc.state.head.bnStr)

  let db = fc.chain.baseTxFrame

  # Initalise helper variable for verifying parent links
  var lastParentHash =
    if lastNumber + 1 == fc.state.ante.number: fc.state.ante.parentHash
    else: db.getHeaderAlways(lastNumber + 1).parentHash

  # Save headers, loop runs top down starting at header with highest
  # block number `lastNumber`
  for n,hdr in rev:

    # Check block number
    let bn = lastNumber - n.uint64
    if bn != hdr.number:
      # Undo updated records so far
      db.delHeaders(bn+1, fc.state.ante.number-1)
      return err("Block number mismatch for rev[" & $n & "].number=" &
                 hdr.number.bnStr & " expected=" & bn.bnStr)

    # Check parent link
    let
      data = encodePayload(hdr)
      hash = data.keccak256
    if lastParentHash != hash:
      # Undo updated records so far
      db.delHeaders(bn+1, fc.state.ante.number-1)
      return err("Parent hash mismatch for rev[" & $n & "].number=" & bn.bnStr)

    # Update helper variable, set to current parent hash
    lastParentHash = hdr.parentHash

    # No need to store overlapping `rev[]` entries
    if bn < fc.state.ante.number:
      # Complete pre-registered `hash->block-number` info (if any)
      fc.state.byHash.withValue(hash, val):
        val[] = bn
      # Store data
      db.putHeader(bn, data)

  if rev[rev.len-1].number < fc.state.ante.number:
    # Set new `antecedent`
    fc.state.ante = rev[rev.len-1]

    # Save updates. persist to DB
    fc.persistPutState()

  ok()


proc fcHeaderDelBaseAndOlder*(fc: ForkedCacheRef) =
  ## Remove `FC` module base header and any ancestors alike.
  fc.persistDelUpTo fc.chain.baseBranch.tailNumber

# --------------------

func fcHeaderHead*(fc: ForkedCacheRef): Header =
  ## Getter: head of header chain
  fc.state.head

func fcHeaderAntecedent*(fc: ForkedCacheRef): Header =
  ## Getter: bottom of header chain
  fc.state.ante

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc verify*(fc: ForkedCacheRef): Result[void,string] =
  ## Verify that the descriptor range is on the database as well
  if 0 < fc.state.head.number:
    for bn in fc.state.ante.number .. fc.state.head.number:
      discard fc.fcHeaderGet(bn).valueOr:
        return err("Missing db entry " & bn.bnStr & " for fc=" & fc.toStr)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
