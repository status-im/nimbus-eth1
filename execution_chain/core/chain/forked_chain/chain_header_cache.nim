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
## management API of the `FC` module proper.
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
## Setup operation:
##
## * After initialisation, the `start()` function is called which will cause
##   this module to listen to fork-choice update request from the `CL`.
##
## * If the fork-choice update request from the `CL` was useful, a new session
##   is initialised. The client app invoking `start()` might pass a notifier
##   call back function for an event driven approach to get informed about a
##   a new session. Alternatively, one can use the function `fcHeaderHead()`
##   for polling.
##
## Client API available:
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
##   module proper and all its ancestors.
##
## * Cached headers can be looked up for by block number or by hash for some
##   pre-registered hashes.
##
## * There is a function provided combining `importBlocks()` and `forkChoice()`
##   as a wrapper around `importBlock()` followed by occasional update of the
##   base value of the `FC` module proper using `forkChoice()`.
##

{.push raises:[].}

import
  std/sets,
  pkg/eth/[common, rlp],
  pkg/results,
  "../../.."/[common, db/core_db, db/storage_types],
  ../../../db/[kvt, kvt_cf],
  ../../../db/kvt/[kvt_utils, kvt_tx_frame],
  ../forked_chain,
  ./[chain_branch, chain_desc]

type
  FcNotifyCB* = proc(finHash: Hash32) {.gcsafe, raises: [].}
    ## Call back function telling a client app that a new chain was initialised.
    ## The hash passed as argument is from the finaliser and must be resolved
    ## as header argument in `startSession()`.

  FcHdrState = object
    ## Header cache state record
    ante: Header               # antecedent, bottom of header chain
    head: Header               # top end of header chain, highest block number
    headHash: Hash32
    finHeader: Header          # final block header
    finHash: Hash32

  FcHdrSession = object
    consHeadNum: BlockNumber   # for logging, metrics etc.
    nextChoice: BlockNumber    # for covenience wrapper `fcHeaderImportBlock()`

  ForkedCacheRef* = ref object
    ## For now, this is a replacement of `ForkedChainRef` for as long as
    ## `FcHdrState` is not integrated into `ForkedChainRef`.
    chain: ForkedChainRef      # descriptor will resolve into that in future
    state: FcHdrState          # state of header chain cache
    session: FcHdrSession      # additional session variables
    notify: FcNotifyCB         # client app notification
    kvt: KvtTxRef              # metadata and temporary headers storage with
                               # it's own column family
                               # isolated from ordinary headers storage.

const
  FinaliserChoiceDelta = 32
    ## Suggested minimum block numbers equivalent between consecutive
    ## invocations of `forkChoice()`

  RaisePfx = "Header Cache: "
    ## Message prefix used when bailing out raising an exception

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
  result = "("
  if fc.state.head.number != 0:
    result &= "(" & fc.state.ante.bnStr
    if fc.state.ante != fc.state.head:
      result &= ".." & fc.state.head.bnStr
    result &= "," & fc.state.finHeader.bnStr & ")"
    result &= "," & fc.session.consHeadNum.bnStr
  result &= ")"

# ------------------------------------------------------------------------------
# Private cache helpers: RLP related
# ------------------------------------------------------------------------------

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

proc getState(db: KvtTxRef): Opt[FcHdrState] =
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

proc putState(db: KvtTxRef; state: FcHdrState) =
  db.put(LhcStateKey.toOpenArray, encodePayload(state)).isOkOr:
    raiseAssert RaisePfx & "put(state) failed: " & $error

proc putHeader(db: KvtTxRef; bn: BlockNumber; data: seq[byte]) =
  ## Store rlp encoded header
  db.put(beaconHeaderKey(bn).toOpenArray, data).isOkOr:
    raiseAssert RaisePfx & "put() failed: " & $error


proc getHeader(db: KvtTxRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some header from cache
  let data = db.get(beaconHeaderKey(bn).toOpenArray).valueOr:
    return err()
  ok decodePayload(data, Header)

proc getHeaderAlways(db: KvtTxRef; bn: BlockNumber): Header =
  ## Retrieve some header from cache, raise exception on failure
  var hdr = db.getHeader(bn).valueOr:
    raiseAssert RaisePfx & "get() failed: " & bn.bnStr
  move(hdr)


proc delHeader(db: KvtTxRef; bn: BlockNumber) =
  ## Remove header from cache
  discard db.del(beaconHeaderKey(bn).toOpenArray)

proc delHeaders(db: KvtTxRef; first, last: BlockNumber) =
  for bn in first .. last:
    discard db.del(beaconHeaderKey(bn).toOpenArray)

# ----------------------

proc persistPutState(fc: ForkedCacheRef) =
  ## Persist state records and database updates
  let
    db = fc.kvt

  # Save updated state record
  db.putState(fc.state)

  # Persist state to database
  db.persist()

proc persistDelUpTo(fc: ForkedCacheRef; bn: BlockNumber) =
  ## Remove headers from the lower end of the cache starting at the
  ## `antecedent` up to the argument block number.
  if fc.state.ante.number <= bn:
    let
      bn = min(bn, fc.state.head.number-1)
      db = fc.kvt
      ante = fc.kvt.getHeader(bn + 1).valueOr:
        raiseAssert RaisePfx & "get() failed: " & (bn + 1).bnStr

    for bn in fc.state.ante.number .. bn:
      db.delHeader bn

    # Save state
    fc.state.ante = ante

    # Save updates. persist to DB
    fc.persistPutState()

# ------------------------------------------------------------------------------
# Private fork choice call back function
# ------------------------------------------------------------------------------

proc fcUpdateFromCL(fc: ForkedCacheRef; h: Header; f: Hash32) =
  ## Call back function to register new/prevously-unknown FC updates.
  ##
  ## This function initialises a new session and notifies some registered
  ## client app.
  if f != zeroHash32 and                            # finalised hash is set
     fc.chain.baseNumber + 1 < h.number:            # otherwise useless

    if fc.state.head.number == 0:
      # Set up the session environment but do not persist yet so the
      # session can be cheaply cancelled from within the notifier function.
      fc.session.reset                              # start new session
      fc.state = FcHdrState(                        # update state record
        ante:     h,
        head:     h,
        headHash: h.blockHash(),
        finHash:  f)

      # Inform client app about that a new session is available.
      fc.notify(f)

    # For logging and metrics
    fc.session.consHeadNum = h.number

# ------------------------------------------------------------------------------
# Public constructor/destructor et al.
# ------------------------------------------------------------------------------

proc accept*(fc: ForkedCacheRef; fin: Header): bool =
  ## Accept and activate session
  ##
  let head = fc.state.head
  if 0 < head.number and
     fc.chain.baseNumber < fin.number and
     fc.state.finHash == fin.blockHash():
    fc.state.finHeader = fin

    fc.kvt.putHeader(fc.state.head.number, encodePayload fc.state.head)
    return true

proc clear*(fc: ForkedCacheRef) =
  ## Clear and flush current header chain cache session. This applies to an
  ## accepted session (via `accept()`) or a mere notified session (via `notify`
  ## call back argument from `start()`.)
  ##
  if 0 < fc.state.head.number:
    let db = fc.kvt
    db.delHeaders(fc.state.ante.number, fc.state.head.number)
    fc.state.reset                 # clear session state object
    fc.session.reset
    fc.persistPutState()


proc stop*(fc: ForkedCacheRef) =
  ## Stop updating the client cache. Will automatically be called by the
  ## destructor `destroy()`.
  ##
  fc.chain.com.fcHeaderClUpdate = FcHeaderClUpdateCB(nil)
  fc.notify = FcNotifyCB(nil)

proc start*(fc: ForkedCacheRef; notify: FcNotifyCB) =
  ## Initalise the chain so can be filled once a chain head is available.
  ##
  ## If so, the peer app that invokes `start()` is informed via the call back
  ## argument function `notify()` that the header cache was initialised. This
  ## call back function also passed on the chain head used for initialisation.
  ## Alternatively, `fcHeaderHead()` can be used for polling if auto
  ## notification is unwanted.)
  ##
  ## The block number of the new chain `head` is always larger than the current
  ## base value of the `FC` module proper, in particular the statement
  ## `base.number + 1 < head.number` holds.
  ##
  doAssert not notify.isNil
  fc.notify = notify
  fc.chain.com.fcHeaderClUpdate = proc(h: Header; f: Hash32) =
    fc.fcUpdateFromCL(h, f)

# ------------------

proc init*(T: type ForkedCacheRef; c: ForkedChainRef): T =
  ## Constructor, for initialising a new header chain cache. In order to start
  ## using the cache, `start()` needs to be called so that the client app gets
  ## informed when and how the API is fully functional.
  ##
  let
    be = c.db.kvtBackend()
    kvt = be.synchronizerKvt()
    state = kvt.getState.valueOr: FcHdrState()
    fc = T(chain: c, state: state, kvt: kvt)
  fc.clear()
  fc

proc destroy*(fc: ForkedCacheRef) =
  ## Destructor
  fc.stop()
  fc.clear()

# ------------------------------------------------------------------------------
# Public heacher cache production API
# ------------------------------------------------------------------------------

proc fcHeaderGetHash*(fc: ForkedCacheRef; bn: BlockNumber): Opt[Hash32] =
  ## Convenience function, retrieve hash of block header
  if bn == fc.state.head.number:
    return ok(fc.state.headHash)
  # Use parent hash of child entry
  let hdr = fc.kvt.getHeader(bn+1).valueOr:
    return err()
  ok(hdr.parentHash)

proc fcHeaderGet*(fc: ForkedCacheRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  var hdr = fc.kvt.getHeader(bn).valueOr:
    return err()
  ok(move hdr)



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
  if fc.state.finHeader.number == 0:
    return err("fcHeader session not accepted and confirmed yet")

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

  let db = fc.kvt

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
    if lastParentHash != hdr.blockHash:
      # Undo updated records so far
      db.delHeaders(bn+1, fc.state.ante.number-1)
      return err("Parent hash mismatch for rev[" & $n & "].number=" & bn.bnStr)

    # Update helper variable, set to current parent hash
    lastParentHash = hdr.parentHash

    # No need to store overlapping `rev[]` entries
    if bn < fc.state.ante.number:
      # Store on database
      db.putHeader(bn, encodePayload hdr)

  if rev[rev.len-1].number < fc.state.ante.number:
    # Set new `antecedent`
    fc.state.ante = rev[rev.len-1]

    # Save updates. persist to DB
    fc.persistPutState()

  ok()


proc fcHeaderDelBaseAndOlder*(fc: ForkedCacheRef) =
  ## Remove `FC` module base header and any ancestors alike.
  fc.persistDelUpTo fc.chain.baseNumber

# --------------------

func fcHeaderHead*(fc: ForkedCacheRef): Header =
  ## Getter: head of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if 0 < fc.state.finHeader.number:
    return fc.state.head

func fcHeaderAntecedent*(fc: ForkedCacheRef): Header =
  ## Getter: bottom of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if 0 < fc.state.finHeader.number:
    return fc.state.ante

# --------------------

func fcHeaderLastConsHeadNumber*(fc: ForkedCacheRef): BlockNumber =
  ## Getter: block number of last `CL` head update (aka forkchoice update).
  ##
  ## This getter is for metrics or debugging purposes. The returned number
  ## is typically larger than `fcHeaderHead()` and will increaso over time
  ## while `fcHeaderHead()` remains constant (for the current session.)
  ##
  fc.session.consHeadNum

proc fcHeaderTargetUpdate*(fc: ForkedCacheRef; h: Header; f: Hash32) =
  ## Emulate request from `CL` (mainly for debugging purposes)
  if not fc.notify.isNil:
    fc.fcUpdateFromCL(h, f)

# ------------------------------------------------------------------------------
# Public convenience wrapper
# ------------------------------------------------------------------------------

proc fcHeaderImportBlock*(fc: ForkedCacheRef; blk: Block): Result[void,string] =
  ## Wrapper around `importBlock()` followed by occasional update of the
  ## base value of the `FC` module proper accomplised by invocation of
  ## `forkChoice()`.
  ##
  ## This module uses the latest finalised value that was collected over time
  ## for updating the base value mentioned above.
  ##
  let finNum = fc.state.finHeader.number
  if finNum == 0:
    return err("fcHeader session not accepted and confirmed yet")

  fc.chain.importBlock(blk).isOkOr:
    return err(error)

  let blkNum = blk.header.number
  if blkNum < fc.session.nextChoice:
    return ok()

  # Wait `FinaliserChoiceDelta` steps before `forkChoice()`
  if fc.session.nextChoice == 0:
    fc.session.nextChoice = blkNum + FinaliserChoiceDelta - 1
    if fc.state.head.number < fc.session.nextChoice:
      fc.session.nextChoice = fc.state.head.number
    return ok()

  # Update base value of `FC` module proper via `forkChoice()`
  let
    blkHash = fc.fcHeaderGetHash(blkNum).expect "hash"
    finHash = if blkNum < finNum: blkHash else: fc.state.finHash

  fc.chain.forkChoice(blkHash, finHash).isOkOr:
    return err(error)

  # Remove some older stashed headers
  fc.persistDelUpTo fc.chain.baseNumber

  # Reset for next cycle
  fc.session.nextChoice = 0

  ok()

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
