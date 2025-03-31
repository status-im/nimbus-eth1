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
##   is proposed with the parameters sent from the `CL`. The client app that
##   was invoking `start()` must have pass a notifier call back function for
##   an event driven approach to get informed about a new session proposal.
##
## * After notification, the client app must `accept()` the new session so it
##   can go ahead. Along with this notification/accept handshake, the client
##   up must resolve the finaliser hash passed with the notification and use
##   the resolved header as argument into `accept()`.
##
## Client API available:
##
## * Headers can be appended to the cache at the stack bottom away from `head`
##   (i.e. on the left end of the above diagram before `antecedent`.) There
##   can be no gaps on the header stack chain.
##
## * Cached headers can be looked up for by block number.
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

  FcHdrVetted = tuple
    ## Helper structure used in `fcHeaderPut()`
    parent: Hash32
    number: BlockNumber
    data: seq[byte]

  FcHdrMode* = enum
    ## Current state of the header chain.
    ## ::
    ##   FSA:
    ##
    ##   <start> ..                                       <terminal>
    ##
    ##   closed -> notified -> collecting -+--+--> ready -> locked
    ##                             ^       |  |
    ##                             |       |  +-----------> orphan
    ##                             +-------+
    ##
    closed = 0                 # no session
    notified                   # client app was offered a new session
    collecting                 # may append session headers
    ready                      # `ante` has a parent on the `FC` module proper
    orphan                     # no way to link into `FC` module proper
    locked                     # done with session headers, read-only state

  FcHdrSession = object
    ## Header cache state record
    mode: FcHdrMode            # header chain state
    ante: Header               # antecedent, bottom of header chain
    head: Header               # top end of header chain, highest block number
    headHash: Hash32
    finHeader: Header          # final block header
    finHash: Hash32
    consHeadNum: BlockNumber   # for logging, metrics etc.

  ForkedCacheRef* = ref object
    ## For now, this is a replacement of `ForkedChainRef` for as long as
    ## `FcHdrState` is not integrated into `ForkedChainRef`.
    chain: ForkedChainRef      # descriptor will resolve into that in future
    session: FcHdrSession      # additional session variables
    notify: FcNotifyCB         # client app notification
    kvt: KvtTxRef              # metadata and temporary headers storage with
                               # it's own column family
                               # isolated from ordinary headers storage.

const
  FinaliserChoiceDelta = 192
    ## Temporary for `fcHeaderImportBlock()` which will go away.
    ##
    ## Suggested minimum block numbers equivalent between consecutive
    ## invocations of `forkChoice()` (should be > `BaseDistance`.)

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
  result &= $fc.session.mode
  result &= ", " & fc.session.ante.bnStr
  if fc.session.ante != fc.session.head:
    result &= ".." & fc.session.head.bnStr
  result &= "," & fc.session.finHeader.bnStr
  result &= "," & fc.session.consHeadNum.bnStr
  result &= ")"

# ------------------------------------------------------------------------------
# Private cache helpers: RLP related
# ------------------------------------------------------------------------------

func encodePayload[T](arg: T): seq[byte] =
  rlp.encode(arg)

func decodePayload(data: seq[byte]; T: type): T =
  try:
    result = rlp.decode(data, T)
  except RlpError as e:
    raiseAssert RaisePfx & "rlp.decode(" & $T & ") failed:" &
      " name=" & $e.name & " error=" & e.msg

# ------------------------------------------------------------------------------
# Private cache helpers: database related
# ------------------------------------------------------------------------------

proc getState(db: KvtTxRef): Opt[FcHdrSession] =
  let data = db.get(LhcStateKey.toOpenArray).valueOr:
    return err()
  # Ignore state decode error, might be from an earlier state version release
  var
    state: FcHdrSession
  try:
    state = rlp.decode(data, FcHdrSession) # catch/accept rlp error
  except RlpError:
    return err()
  ok(move state)

proc putState(db: KvtTxRef; state: FcHdrSession) =
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
  db.putState(fc.session)

  # Persist state to database
  db.persist()

proc persistDelUpTo(fc: ForkedCacheRef; bn: BlockNumber) =
  ## Remove headers from the lower end of the cache starting at the
  ## `antecedent` up to the argument block number.
  if fc.session.ante.number <= bn:
    let
      bn = min(bn, fc.session.head.number-1)
      db = fc.kvt
      ante = db.getHeader(bn + 1).valueOr:
        raiseAssert RaisePfx & "get() failed: " & (bn + 1).bnStr

    for bn in fc.session.ante.number .. bn:
      db.delHeader bn

    # Save state
    fc.session.ante = ante

    # Save updates. persist to DB
    fc.persistPutState()

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func expectingMode(fc: ForkedCacheRef; mode: FcHdrMode): Result[void,string] =
  if fc.session.mode == mode:
    return ok()
  err("fcHeader session in wrong state: got=" &
    $fc.session.mode & " expected=" & $mode)

# ------------------------------------------------------------------------------
# Private fork choice call back function
# ------------------------------------------------------------------------------

proc fcUpdateFromCL(fc: ForkedCacheRef; h: Header; f: Hash32) =
  ## Call back function to register new/prevously-unknown FC updates.
  ##
  ## This function prepares a new session and notifies some registered
  ## client app.
  ##
  if f != zeroHash32 and                            # finalised hash is set
     fc.chain.baseNumber + 1 < h.number:            # otherwise useless

    if fc.session.mode == closed:
      # Set new session environment
      fc.session = FcHdrSession(                    # start new session
        mode:     notified,
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

func state*(fc: ForkedCacheRef): FcHdrMode =
  ## Getter: Current run state
  ##
  ## Requested system state for running function:
  ## ::
  ##    closed         -- *internal*
  ##    notified       -- accept()
  ##    collecting     -- fcHeaderPut()
  ##    ready          -- fcHeaderComplete()
  ##    orphan         -- n/a
  ##    locked         -- fcHeaderImportBlock()
  ##
  fc.session.mode

proc accept*(fc: ForkedCacheRef; fin: Header): bool =
  ## Accept and activate session.
  ##
  ## Required system state is to run this function is `notified`.
  ##
  if fc.state == notified and
     fc.chain.baseNumber < fin.number and
     fin.number <= fc.session.head.number and
     fc.session.finHash == fin.blockHash():
    fc.session.finHeader = fin

    fc.kvt.putHeader(fc.session.head.number, encodePayload fc.session.head)
    fc.session.mode = collecting
    return true

proc clear*(fc: ForkedCacheRef) =
  ## Clear and flush current header chain cache session. This applies to an
  ## accepted session (via `accept()`) or a mere notified session (via `notify`
  ## call back argument from `start()`.)
  ##
  if 0 < fc.session.head.number:
    let db = fc.kvt
    db.delHeaders(fc.session.ante.number, fc.session.head.number)
    fc.session.reset                 # clear session state object
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
    state = kvt.getState.valueOr: FcHdrSession()
    fc = T(chain: c, session: state, kvt: kvt)
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
  if bn == fc.session.head.number:
    return ok(fc.session.headHash)
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
  ## This function will store argument headers to the persistent header chain.
  ##
  ## Required system state for running this function is `collecting`, `ready`,
  ## or `orphan` where only `collecting` implies some action (described below.)
  ## When in the other two states, the function returns with OK immediately.
  ##
  ## The `rev[]` arguments contain the headers in reverse order as
  ## ::
  ##   rev[0]: number = lastNumber,   parentHash = rev[1].hash
  ##   rev[1]: number = lastNumber-1, parentHash = rev[2].hash
  ##   rev[2]: number = lastNumber-2, parentHash = rev[3].hash
  ##   ..
  ##
  ## If `rev[]` overlaps with the existing headers chain, only the headers
  ## from `rev[]` that do not overlap will be checked and appended to the
  ## header chain. The function returns an error if the check fails.
  ##
  ## There are three outcomes regarding the antecedent (lowest header).
  ##
  ## * If it has a parent on the `FC` module proper. In that case the function
  ##   stops appending headers and sets the system to state `ready`
  ##
  ## * If it transpires that linking into the `FC` module becomes impossible.
  ##   So the function stops appending headers and the system state will be
  ##   changed to `orphan`.
  ##
  ## * Otherwise, the function continues appending headers.
  ##
  ## In either of the three cases, OK is returned.
  ##
  if fc.state in {ready,orphan}:
    return ok() # nothing to do

  ?fc.expectingMode(collecting)

  if rev.len == 0:
    return ok() # nothing to do

  # Check whether argument list closes up to headers chain
  let lastNumber = rev[0].number
  if lastNumber + 1 < fc.session.ante.number:
    return err("Gap between rev[] and headers chain antecedent " &
               fc.session.ante.bnStr)

  # Must not overwrite or exceed the top end of headers chain
  if fc.session.head.number <= lastNumber:
    return err("Argument rev[] exceeds chain head " & fc.session.head.bnStr)

  # The tail must not go below the `base`. It cannot be handled even if it
  # has a parent on the database.
  let baseNum = fc.chain.baseNumber()

 # Start at the entry that is parent to `ante` (if any)
  let offset = ((lastNumber + 1) - fc.session.ante.number).int
  if offset < rev.len:
    # Verify headers. The loop runs top down starting at header with highest
    # block number `lastNumber`. Serialised blocks from rev`[]` are collected
    # in the `vetted[]` list and stored if they turn out consistent.
    var
      vetted: seq[FcHdrVetted] = @[(fc.session.ante.parentHash, 0, @[])]
      revTopInx = rev.len - 1
    for n in offset .. revTopInx:
      let
        hdr = rev[n]
        bn = lastNumber - n.uint64

      # Check block number
      if bn != hdr.number:
        # There is no need to clean up as nothing was store on the DB
        return err("Block number mismatch for rev[" & $n & "].number=" &
                   hdr.bnStr & " expected=" & bn.bnStr)

      if bn < baseNum:
        # Delayed error so any batch using this function has a soft landing
        fc.session.mode = orphan
        return ok()

      # Check parent link
      let hash = hdr.blockHash
      if vetted[^1].parent != hash:
        # There is no need to clean up as nothing was store on the DB
        return err("Parent hash mismatch for rev[" & $n & "].number=" &
          bn.bnStr)

      # Check whether the current header matches the `finalised` one. If so,
      # headers must match.
      if fc.session.finHeader.number == bn:
        if fc.session.finHash != hash:
          # Delayed error so any batch using this function has a soft landing
          fc.session.mode = orphan
          return ok()

      # Update list of verified entries
      vetted.add (hdr.parentHash, bn, encodePayload hdr)

      # Check whether the `hdr` has a parent on the `FC` module
      if fc.chain.hashToBlock.hasKey(hdr.parentHash):
        let finNumber = fc.session.finHeader.number

        # Verify that the `finalised` header is on the current chain. If the
        # `finalised` block number is at least `bn`, this has been verified
        # already.
        if finNumber < bn:

          # Cheap check whether `finalised` header cannot be on the
          # `finalised` header database.
          if finNumber < fc.chain.baseNumber:
            fc.session.mode = orphan
            return ok()

          # Now, the `finalised` block number is between the one of `base`
          # and `hdr.number` (aka `bn`.) If acceptable, the `finalised`
          # header must be on the ancestor chain `base`..`hdr`.
          #
          # Simply checking the `finalised` header against `hashToBlock[]`
          # is not too useful. Knowing that the `finalised` header is on
          # the `hashToBlock[]` table does not tell whether is on the right
          # branch `base`..`hdr`.
          var finChild = hdr
          while finNumber+1 < finChild.number:
            fc.chain.hashToBlock.withValue(finChild.parentHash,val):
              finChild = val[].blk.header
          if fc.session.finHash != finChild.parentHash:
            # Fail: The `finalised` header is on the wrong branch.
            fc.session.mode = orphan
            return ok()

        # Chaining headers stops here
        fc.session.mode = ready
        revTopInx = n
        break

    # Commit to database
    let db = fc.kvt
    for n in 1 ..< vetted.len:
      # Store on database
      db.putHeader(vetted[n].number, vetted[n].data)

    # Set new antecedent `ante` and save to disk (if any)
    fc.session.ante = rev[revTopInx]

    # Save updates. persist to DB
    fc.persistPutState()

  ok()


proc fcHeaderCommit*(fc: ForkedCacheRef): Result[void,string] =
  ## Finish appending headers to header chain cache which will become
  ## read-only (if this function succeeds.)
  ##
  ## Required system state for running this function is `ready`.
  ##
  ## This function will provide its collected data to the `FC` module proper
  ## for optimisation purposes.
  ##
  ?fc.expectingMode(ready)

  if not fc.chain.hashToBlock.hasKey(fc.session.ante.parentHash):
    # Beware of a re-org right after the last `fcHeaderPut()`
    return err("Link into FC module is lost")

  # Update internal state
  fc.session.mode = locked

  # Inform `FC` module proper about finalised header
  if fc.chain.hdrChainFinHeader.number < fc.session.finHeader.number:
    fc.chain.hdrChainFinHeader = fc.session.finHeader
    fc.chain.hdrChainFinHash = fc.session.finHash
  ok()

# --------------------

func fcHeaderHead*(fc: ForkedCacheRef): Header =
  ## Getter: head of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if collecting <= fc.state:
    return fc.session.head

func fcHeaderAntecedent*(fc: ForkedCacheRef): Header =
  ## Getter: bottom of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if collecting <= fc.state:
    return fc.session.ante

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
  ?fc.chain.importBlock(blk)

  if fc.chain.baseNumber + FinaliserChoiceDelta < fc.chain.latestNumber and
     fc.chain.baseNumber < fc.chain.hdrChainFinHeader.number:

    # Update base value of `FC` module proper via `forkChoice()`
    let
      blkNum = blk.header.number
      blkHash = fc.fcHeaderGetHash(blkNum).expect "hash"
      finNum = fc.chain.hdrChainFinHeader.number
      finHash = if blkNum < finNum: blkHash else: fc.chain.hdrChainFinHash

    ?fc.chain.forkChoice(blkHash, finHash)

    # Remove some older stashed headers
    fc.persistDelUpTo fc.chain.baseNumber

  ok()

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc verify*(fc: ForkedCacheRef): Result[void,string] =
  ## Verify that the descriptor range is on the database as well
  if 0 < fc.session.head.number:
    for bn in fc.session.ante.number .. fc.session.head.number:
      discard fc.fcHeaderGet(bn).valueOr:
        return err("Missing db entry " & bn.bnStr & " for fc=" & fc.toStr)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
