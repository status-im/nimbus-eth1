# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Header Chain Cache for Collecting Headers for Syncing Apps
## ==========================================================
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
##   can be no gaps on the cached header chain.
##
## * Cached headers can be looked up for by block number.
##
## * While appending headers, the current `antecedent` is tested whether it has
##   a parent on the `FC` module. If this is tha case, then any attempt to add
##   more headers will be silently ignored.
##
## * After headers have been collected and the `antecedent` has a parent on
##   the `FC` module, the header append process must be finished by a dedicated
##   commit statement `commit()`.
##
## Temporary extra:
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
  "../.."/[common, db/core_db, db/storage_types],
  ../../db/[kvt, kvt_cf],
  ../../db/kvt/[kvt_utils, kvt_tx_frame],
  ./forked_chain/[chain_branch, chain_desc]

type
  HccDbInfo = object
    ## For database table storage and clean up
    least, last: BlockNumber

  HccVetted = tuple
    ## Helper structure used in `put()`
    parent: Hash32
    number: BlockNumber
    data: seq[byte]

  HccSession = object
    ## Header cache state record
    mode: HeaderChainMode       # header chain state
    ante: Header                # antecedent, bottom of header chain
    head: Header                # top end of header chain, highest block number
    headHash: Hash32
    finHeader: Header           # final block header
    finHash: Hash32
    consHeadNum: BlockNumber    # for logging, metrics etc.

  # -----------------

  HeaderChainMode* = enum
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
    closed = 0                  # no session
    notified                    # client app was offered a new session
    collecting                  # may append session headers
    ready                       # `ante` has a parent on the `FC` module
    orphan                      # no way to link into `FC` module
    locked                      # done with session headers, read-only state

  HeaderChainNotifyCB* = proc(finHash: Hash32) {.gcsafe, raises: [].}
    ## Call back function telling a client app that a new chain was initialised.
    ## The hash passed as argument is from the finaliser and must be resolved
    ## as header argument in `startSession()`.

  HeaderChainRef* = ref object
    ## Module descriptor
    chain: ForkedChainRef       # descriptor will resolve into that in future
    session: HccSession         # additional session variables
    notify: HeaderChainNotifyCB # client app notification
    kvt: KvtTxRef               # metadata and temporary headers storage with
                                # it's own column family
                                # isolated from ordinary headers storage.
const
  MaxDeleteBatch = 10 * 1024
    ## Insert `persist()` statements in bulk action every `MaxDeleteBatch`
    ## `del()` directives.

  FinaliserChoiceDelta = 192
    ## Temporary for `fcHeaderImportBlock()` which will go away.
    ##
    ## Suggested minimum block numbers equivalent between consecutive
    ## invocations of `forkChoice()` (should be > `BaseDistance`.)

  RaisePfx = "Header Cache: "
    ## Message prefix used when bailing out raising an exception

let
  HccDbInfoKey = 0.beaconHeaderKey

# ------------------------------------------------------------------------------
# Private debugging and print functions
# ------------------------------------------------------------------------------

func bnStr(w: BlockNumber): string =
  "#" & $w

func bnStr(h: Header): string =
  h.number.bnStr

func toStr(hc: HeaderChainRef): string =
  result = "("
  result &= $hc.session.mode
  result &= ", " & hc.session.ante.bnStr
  if hc.session.ante != hc.session.head:
    result &= ".." & hc.session.head.bnStr
  result &= "," & hc.session.finHeader.bnStr
  result &= "," & hc.session.consHeadNum.bnStr
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

proc putInfo(db: KvtTxRef; state: HccDbInfo) =
  db.put(HccDbInfoKey.toOpenArray, encodePayload(state)).isOkOr:
    raiseAssert RaisePfx & "put(info) failed: " & $error

proc getInfo(db: KvtTxRef): Opt[HccDbInfo] =
  let data = db.get(HccDbInfoKey.toOpenArray).valueOr:
    return err()
  # Ignore state decode error, might be from an earlier state version release
  try:
    return ok rlp.decode(data, HccDbInfo) # catch/accept rlp error
  except RlpError:
    discard
  err()

proc delInfo(db: KvtTxRef) =
  ## Remove info record from cache
  discard db.del(HccDbInfoKey.toOpenArray)


proc putHeader(db: KvtTxRef; bn: BlockNumber; data: seq[byte]) =
  ## Store rlp encoded header
  db.put(beaconHeaderKey(bn).toOpenArray, data).isOkOr:
    raiseAssert RaisePfx & "put(header) failed: " & $error

proc getHeader(db: KvtTxRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some header from cache
  let data = db.get(beaconHeaderKey(bn).toOpenArray).valueOr:
    return err()
  ok decodePayload(data, Header)

proc delHeaders(db: KvtTxRef; fromBn, toBn: BlockNumber) =
  ## Remove headers from cache
  for bn in fromBn .. toBn:
    discard db.del(beaconHeaderKey(bn).toOpenArray)
    # Occasionally flush the current data
    if (bn - fromBn) mod MaxDeleteBatch == 0:
      db.persist()

# ----------------------

proc persistInfo(hc: HeaderChainRef) =
  ## Persist info record (and whatever was in the kvt cache)
  hc.kvt.putInfo HccDbInfo(
    least: hc.session.ante.number,
    last:  hc.session.head.number)
  hc.kvt.persist()

proc persistClear(hc: HeaderChainRef) =
  ## Clear persistent database
  let w = hc.kvt.getInfo.valueOr: return
  hc.kvt.delHeaders(w.least, w.last)
  hc.kvt.delInfo()
  hc.kvt.persist()

proc persistDelUpTo(hc: HeaderChainRef; bn: BlockNumber) =
  ## Remove headers from the lower end of the cache starting at the
  ## `antecedent` up to the argument block number.
  if hc.session.ante.number <= bn and hc.session.head.number <= bn:
    hc.kvt.delHeaders(hc.session.ante.number, bn)
    hc.session.ante = hc.kvt.getHeader(bn + 1).valueOr:
      raiseAssert RaisePfx & "get(header) failed: " & (bn + 1).bnStr
    hc.persistInfo()

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func baseNum(hc: HeaderChainRef): BlockNumber =
  ## Aka `hc.chain.baseNumber()` (avoiding `forked_chain` import)
  hc.chain.baseBranch.tailNumber

func latestNum(hc: HeaderChainRef): BlockNumber =
  ## Aka `hc.chain.latestNumber()` (avoiding `forked_chain` import)
  hc.chain.activeBranch.headNumber

func expectingMode(
    hc: HeaderChainRef;
    mode: HeaderChainMode;
      ): Result[void,string] =
  if hc.session.mode == mode:
    return ok()
  err("HeaderChain session in wrong state: got=" &
    $hc.session.mode & " expected=" & $mode)

# ------------------------------------------------------------------------------
# Private fork choice call back function
# ------------------------------------------------------------------------------

proc headUpdateFromCL(hc: HeaderChainRef; h: Header; f: Hash32) =
  ## Call back function to register new/prevously-unknown FC updates.
  ##
  ## This function prepares a new session and notifies some registered
  ## client app.
  ##
  if f != zeroHash32 and                            # finalised hash is set
     hc.baseNum + 1 < h.number:                     # otherwise useless

    if hc.session.mode == closed:
      # Set new session environment
      hc.session = HccSession(                      # start new session
        mode:     notified,
        ante:     h,
        head:     h,
        headHash: h.computeBlockHash(),
        finHash:  f)

      # Inform client app about that a new session is available.
      hc.notify(f)

    # For logging and metrics
    hc.session.consHeadNum = h.number

# ------------------------------------------------------------------------------
# Public constructor/destructor et al.
# ------------------------------------------------------------------------------

func state*(hc: HeaderChainRef): HeaderChainMode =
  ## Getter: Current run state
  ##
  ## Requested system state for running function:
  ## ::
  ##    closed         -- *internal*
  ##    notified       -- accept()
  ##    collecting     -- put()
  ##    ready          -- complete()
  ##    orphan         -- n/a
  ##    locked         -- fcHeaderImportBlock()
  ##
  hc.session.mode

proc accept*(hc: HeaderChainRef; fin: Header): bool =
  ## Accept and activate session.
  ##
  ## Required system state is to run this function is `notified`.
  ##
  if hc.state == notified and
     hc.baseNum < fin.number and
     fin.number <= hc.session.head.number:

    let finHash = fin.computeBlockHash()
    if hc.session.finHash != finHash:
      return false

    hc.session.finHeader = fin
    hc.kvt.putHeader(hc.session.head.number, encodePayload hc.session.head)

    # TODO: syncer and also ForkedCache should not start session
    # using finalizedHash, as evident from hive test
    # the FCU head can have block number bigger than finalized block.
    # Syncer and ForkedCache should only deal with FCU headHash.
    # TODO: move notifyBlockHashAndNumber call to fcPutHeader
    # where one of the headers should also the finalized header.
    hc.chain.notifyBlockHashAndNumber(finHash, fin.number)

    hc.session.mode = collecting
    return true

proc clear*(hc: HeaderChainRef) =
  ## Clear and flush current header chain cache session. This applies to an
  ## accepted session (via `accept()`) or a mere notified session (via `notify`
  ## call back argument from `start()`.)
  ##
  if 0 < hc.session.head.number:
    hc.session.reset                 # clear session state object
    hc.persistClear()                # clear database


proc stop*(hc: HeaderChainRef) =
  ## Stop updating the client cache. Will automatically be called by the
  ## destructor `destroy()`.
  ##
  hc.chain.com.headerChainUpdate = HeaderChainUpdateCB(nil)
  hc.notify = HeaderChainNotifyCB(nil)

proc start*(hc: HeaderChainRef; notify: HeaderChainNotifyCB) =
  ## Initalise the chain so can be filled once a chain head is available.
  ##
  ## If so, the peer app that invokes `start()` is informed via the call back
  ## argument function `notify()` that the header cache was initialised.
  ##
  ## The block number of the new chain `head` is always larger than the
  ## current base value of the `FC` module, in particular the statement
  ## `base.number + 1 < head.number` holds.
  ##
  doAssert not notify.isNil
  hc.notify = notify
  hc.chain.com.headerChainUpdate = proc(h: Header; f: Hash32) =
    hc.headUpdateFromCL(h, f)

# ------------------

proc init*(T: type HeaderChainRef; c: ForkedChainRef): T =
  ## Constructor, for initialising a new header chain cache. In order to start
  ## using the cache, `start()` needs to be called so that the client app gets
  ## informed when and how the API is fully functional.
  ##
  let hc = T(chain: c, kvt: c.com.db.kvtBackend().synchronizerKvt())
  hc.persistClear()                  # clear database
  hc

proc destroy*(hc: HeaderChainRef) =
  ## Destructor
  hc.stop()
  hc.clear()

# ------------------------------------------------------------------------------
# Public heacher cache production API
# ------------------------------------------------------------------------------

proc getHash*(hc: HeaderChainRef; bn: BlockNumber): Opt[Hash32] =
  ## Convenience function, retrieve hash of block header
  if bn == hc.session.head.number:
    return ok(hc.session.headHash)
  # Use parent hash of child entry
  let hdr = hc.kvt.getHeader(bn+1).valueOr:
    return err()
  ok(hdr.parentHash)

proc get*(hc: HeaderChainRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some stashed header.
  var hdr = hc.kvt.getHeader(bn).valueOr:
    return err()
  ok(move hdr)


proc put*(
    hc: HeaderChainRef;
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
  ## * If it has a parent on the `FC` module. In that case the function
  ##   stops appending headers and sets the system to state `ready`
  ##
  ## * If it transpires that linking into the `FC` module becomes impossible,
  ##   then the function stops appending headers and the system state will be
  ##   changed to `orphan`.
  ##
  ## * Otherwise, the function continues appending headers.
  ##
  ## In either of the three cases, OK is returned.
  ##
  if hc.state in {ready,orphan}:
    return ok() # nothing to do

  ?hc.expectingMode(collecting)

  if rev.len == 0:
    return ok() # nothing to do

  # Check whether argument list closes up to headers chain
  let lastNumber = rev[0].number
  if lastNumber + 1 < hc.session.ante.number:
    return err("Gap between rev[] and headers chain antecedent " &
               hc.session.ante.bnStr)

  # Must not overwrite or exceed the top end of headers chain
  if hc.session.head.number <= lastNumber:
    return err("Argument rev[] exceeds chain head " & hc.session.head.bnStr)

  # The tail must not go below the `base`. It cannot be handled even if it
  # has a parent on the database.
  let baseNum = hc.baseNum()

 # Start at the entry that is parent to `ante` (if any)
  let offset = ((lastNumber + 1) - hc.session.ante.number).int
  if offset < rev.len:
    # Verify headers. The loop runs top down starting at header with highest
    # block number `lastNumber`. Serialised blocks from rev`[]` are collected
    # in the `vetted[]` list and stored if they turn out consistent.
    var
      vetted: seq[HccVetted] = @[(hc.session.ante.parentHash, 0, @[])]
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
        hc.session.mode = orphan
        return ok()

      # Check parent link
      let hash = hdr.computeBlockHash
      if vetted[^1].parent != hash:
        # There is no need to clean up as nothing was store on the DB
        return err("Parent hash mismatch for rev[" & $n & "].number=" &
          bn.bnStr)

      # Check whether the current header matches the `finalised` one. If so,
      # headers must match.
      if hc.session.finHeader.number == bn:
        if hc.session.finHash != hash:
          # Delayed error so any batch using this function has a soft landing
          hc.session.mode = orphan
          return ok()

      # Update list of verified entries
      vetted.add (hdr.parentHash, bn, encodePayload hdr)

      # Check whether the `hdr` has a parent on the `FC` module
      if hc.chain.hashToBlock.hasKey(hdr.parentHash):
        let finNumber = hc.session.finHeader.number

        # Verify that the `finalised` header is on the current chain. If the
        # `finalised` block number is at least `bn`, this has been verified
        # already.
        if finNumber < bn:

          # Cheap check whether `finalised` header cannot be on the
          # `finalised` header database.
          if finNumber < hc.baseNum:
            hc.session.mode = orphan
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
            hc.chain.hashToBlock.withValue(finChild.parentHash,val):
              finChild = val[].blk.header
          if hc.session.finHash != finChild.parentHash:
            # Fail: The `finalised` header is on the wrong branch.
            hc.session.mode = orphan
            return ok()

        # Chaining headers stops here
        hc.session.mode = ready
        revTopInx = n
        break

    # Commit to database
    for n in 1 ..< vetted.len:
      # Store on database
      hc.kvt.putHeader(vetted[n].number, vetted[n].data)

    # Set new antecedent `ante` and save to disk (if any)
    hc.session.ante = rev[revTopInx]

    # Save updates. persist to DB
    hc.persistInfo()

  ok()


proc commit*(hc: HeaderChainRef): Result[void,string] =
  ## Finish appending headers to header chain cache which will become
  ## read-only (if this function succeeds.)
  ##
  ## Required system state for running this function is `ready`.
  ##
  ## This function will provide its collected data to the `FC` module
  ## for optimisation purposes.
  ##
  ?hc.expectingMode(ready)

  if not hc.chain.hashToBlock.hasKey(hc.session.ante.parentHash):
    # Beware of a re-org right after the last `put()`
    return err("Link into FC module has been lost")

  # Update internal state
  hc.session.mode = locked

  ok()

# --------------------

func head*(hc: HeaderChainRef): Header =
  ## Getter: head of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if collecting <= hc.state:
    return hc.session.head

func antecedent*(hc: HeaderChainRef): Header =
  ## Getter: bottom of header chain. In case there is no header chain
  ## initialised, the return value is `Header()` (i.e. the block number
  ## of the result is zero.).
  ##
  if collecting <= hc.state:
    return hc.session.ante

# --------------------

func latestConsHeadNumber*(hc: HeaderChainRef): BlockNumber =
  ## Getter: block number of last `CL` head update (aka forkchoice update).
  ##
  ## This getter is for metrics or debugging purposes. The returned number
  ## is typically larger than `head()` and will increased over time while
  ## `head()` remains constant (for the current session.)
  ##
  hc.session.consHeadNum

proc headTargetUpdate*(hc: HeaderChainRef; h: Header; f: Hash32) =
  ## Emulate request from `CL` (mainly for debugging purposes)
  if not hc.notify.isNil:
    hc.headUpdateFromCL(h, f)

# ------------------------------------------------------------------------------
# Public convenience wrapper
# ------------------------------------------------------------------------------

import ./forked_chain

proc fcHeaderImportBlock*(hc: HeaderChainRef; blk: Block): Result[void,string] =
  ## Wrapper around `importBlock()` followed by occasional update of the
  ## base value of the `FC` module accomplised by invocation of `forkChoice()`.
  ##
  ## To be integrated into `FC` module proper
  ##
  ?hc.chain.importBlock(blk)

  if hc.baseNum + FinaliserChoiceDelta < hc.latestNum:

    # Remove some older stashed headers
    hc.persistDelUpTo hc.baseNum

  ok()

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc verify*(hc: HeaderChainRef): Result[void,string] =
  ## Verify that the descriptor range is on the database as well
  if 0 < hc.session.head.number:
    for bn in hc.session.ante.number .. hc.session.head.number:
      discard hc.get(bn).valueOr:
        return err("Missing db entry " & bn.bnStr & " for hc=" & hc.toStr)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
