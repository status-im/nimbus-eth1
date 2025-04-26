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
## oldest ancestor of `head`) is called `antecedent` (i.e. most senior header.)
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
  pkg/eth/[common, rlp],
  pkg/results,
  pkg/chronicles,
  "../.."/[common, db/core_db, db/storage_types],
  ../../db/[kvt, kvt_cf],
  ../../db/kvt/[kvt_utils, kvt_tx_frame],
  ./forked_chain/[chain_branch, chain_desc]

logScope:
  topics = "hc-cache"

type
  HccDbInfo = object
    ## For database table storage and clean up
    least, last: BlockNumber

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
    collecting                  # may append session headers
    ready                       # `ante` has a parent on the `FC` module
    orphan                      # no way to link into `FC` module
    locked                      # done with session headers, read-only state

  HeaderChainNotifyCB* = proc() {.gcsafe, raises: [].}
    ## Call back function telling a client app that a new session was
    ## initialised and has started.

  HeaderChainRef* = ref object
    ## Module descriptor
    chain: ForkedChainRef       # descriptor will resolve into that in future
    session: HccSession         # additional session variables
    notify: HeaderChainNotifyCB # client app notification
    kvt: KvtTxRef               # metadata and temporary headers storage with
                                # it's own column family
                                # isolated from ordinary headers storage.
const
  MaxDeleteBatch = 100 * 1024
    ## Insert `persist()` statements in bulk action every `MaxDeleteBatch`
    ## `del()` directives.

  RaisePfx = "Header Cache: "
    ## Message prefix used when bailing out raising an exception

const
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

proc delHeader(db: KvtTxRef; bn: BlockNumber) =
  ## Remove header from cache
  discard db.del(beaconHeaderKey(bn).toOpenArray)

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
  for bn in w.least .. w.last:
    hc.kvt.delHeader(bn)
    # Occasionally flush the current data
    if (bn - w.least) mod MaxDeleteBatch == 0:
      hc.kvt.persist()
  hc.kvt.delInfo()
  hc.kvt.persist()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func baseNum(hc: HeaderChainRef): BlockNumber =
  ## Aka `hc.chain.baseNumber()` (avoiding `forked_chain` import)
  hc.chain.baseBranch.tailNumber

func expectingMode(
    hc: HeaderChainRef;
    mode: HeaderChainMode;
      ): Result[void,string] =
  if hc.session.mode == mode:
    return ok()
  err("HeaderChain session in wrong state: got=" &
    $hc.session.mode & " expected=" & $mode)

# ------------

proc tryFcParent(hc: HeaderChainRef; hdr: Header): HeaderChainMode =
  ## The function checks whether the `hdr` argument has a parent on the `FC`
  ## module, or if the `hdr` is on a branch that never can end up with such
  ## a parent.
  ##
  ## The return code is the state that describes the finding which might
  ## also be inconclusive:
  ## * `ready`      -- parent found on `FC` module
  ## * `orphan`     -- on the wrong branch, or beyond reach
  ## * `collecting` -- inconclusive
  ##
  # Check whether the `hdr` has a parent on the `FC` module right away
  if hc.chain.hashToBlock.hasKey(hdr.parentHash):
    return ready                               # parent found on `FC` module

  # Ignore `hdr` unless its block number equals the one of the base (note
  # that this function is called with decreasing block numbers.)
  let baseNum = hc.baseNum()
  if baseNum + 1 < hdr.number:
    return collecting                          # inconclusive

  # The block number of `hdr` must not go below the `base`. It cannot be
  # handled even if it has a parent on the block chain (but not on the
  # `FC` module.)
  #
  # Rationale:
  #   This situataion might arise by means of `CL` requests via RPC updating
  #   the `base` concurrently to a syncer client. This can only happen if the
  #   base is near the canonical head. Which in turn means that the header
  #   chain is short.
  #
  #   Reversing the antecedent (above `base`) is avoided. This goes with the
  #   argument that completely re-syncing a short header chain is worth it
  #   comparing additional administrative costs (for a syncer client of that
  #   module) of handling backward moves of the antecedent.
  #
  if hdr.number <= baseNum:
    return orphan                              # beyond reach

  # Now: baseNum + 1 == hdr.number
  #
  # This is the last stop (with least possible block number) where the
  # `hdr` could have a parent on the `FC` module which obviously failed
  # (i.e. `base` is not parent of `hdr`.)
  if hc.session.finHeader.number <= baseNum:
    # So, if resolved at all then `finalised` is ancestor of, or equal to
    # `base`. In any case, `hdr` has no parent on the canonical branch up
    # to `base`. So it is on another branch.
    return orphan                              # maybe on the wrong branch

  # Now `base` and `finalised` (and all ancestors of either) are on the
  # the canonical branch of the DAG generated by the `CL` logic.
  #
  # So is `hdr` as its block number is `baseNum+1` at most the one of
  # `finalised`. And both are on the header chain.
  #
  # So `base` and `hdr` are also on the canonical chain with block number
  # distance 1. But `hdr` has no parent on the `FC` module -- oops.
  #
  # Impossible situation!
  raiseAssert RaisePfx & "Base " & baseNum.bnStr & " was expected " &
    "to be parent header chain item " & hdr.number.bnStr

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
        mode:     collecting,
        ante:     h,
        head:     h,
        headHash: h.computeBlockHash(),
        finHash:  f)

      hc.kvt.putHeader(h.number, encodePayload h)

      # Inform client app about that a new session has started.
      hc.notify()

      # The way syncer works that is per session.
      # This is how we tell the FC about pending FCU
      # 'from' CL, albeit a bit indirect.
      # If we call `notifyFinalizedHash` inside engine_fCU,
      # while the session is running, `notifyBlockHashAndNumber`
      # will miss the finalized block for that session because
      # engine_fCU might be using new finHash that is newer than the
      # session^head.
      # And if the distance between session^head to FC^base is very
      # large, it will lead to excessive memory consumption.
      # https://github.com/status-im/nimbus-eth1/issues/3207
      hc.chain.notifyFinalizedHash(f)

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
  ##    collecting     -- put()
  ##    ready          -- complete()
  ##    orphan         -- n/a
  ##    locked         -- importBlock() from FC module
  ##
  hc.session.mode


proc clear*(hc: HeaderChainRef) =
  ## Clear and flush current header chain cache session. This applies to an
  ## accepted session (via `accept()`) or a mere notified session (via `notify`
  ## call back argument from `start()`.)
  ##
  hc.session.reset                   # clear session state object
  hc.persistClear()                  # clear database


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
  if hc.session.head.number <= bn+1:
    if bn == hc.session.head.number:
      return ok(hc.session.headHash)
    elif bn+1 == hc.session.head.number:
      return ok(hc.session.head.parentHash)
    else:
      return err()
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
  ## There are three outcomes regarding the antecedent (most senior header).
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
    return ok()                                    # nothing to do

  # Check whether argument list closes up to headers chain
  let lastNumber = rev[0].number
  if lastNumber + 1 < hc.session.ante.number:
    return err("Gap between rev[] and headers chain antecedent " &
      hc.session.ante.bnStr)

  # Must not overwrite or exceed the top end of headers chain
  if hc.session.head.number <= lastNumber:
    return err("Argument rev[] exceeds chain head " &
      hc.session.head.bnStr)

  # Check whether the `FC` module has changed and the current antecedent
  # already is the end of it.
  block:
    let newMode = hc.tryFcParent(hc.session.ante)
    if newMode in {ready,orphan}:
      hc.session.mode = newMode
      return ok()

 # Start at the entry that is parent to `ante` (if any)
  let offset = ((lastNumber + 1) - hc.session.ante.number).int
  if offset < rev.len:
    #
    # Verify headers. The loop runs top down starting at header with highest
    # block number `lastNumber`. Serialised blocks from `rev[]` are registered
    # between indices `offset` and `revTopInx` stored if they turn out
    # consistent.
    #
    var revTopInx = rev.len - 1
    for n in offset .. revTopInx:
      let
        hdr = rev[n]
        bn = lastNumber - n.uint64

      # Check block number
      if bn != hdr.number:
        # There is no need to clean up as nothing was store on the DB
        return err("Block number mismatch for rev[" & $n & "].number=" &
                   hdr.bnStr & " expected=" & bn.bnStr)

      # Verify that `hdr` is parent of `rev[n-1]` or `ante`
      let
        hash = hdr.computeBlockHash()
        expHash = if offset < n: rev[n-1].parentHash
                  else: hc.session.ante.parentHash
      if expHash != hash:
        # There is no need to clean up as nothing was store on the DB
        return err("Parent hash mismatch for rev[" & $n & "].number=" &
          bn.bnStr)

      # Resolve finaliser if possible.
      if hc.session.finHash == hash:
        hc.session.finHeader = hdr

        # Ackn: moved here from `accept()`
        #   Syncer and also ForkedCache should not start session
        #   using finalizedHash, as evident from hive test
        #   the FCU head can have block number bigger than finalized block
        #   and the finalized hash from CL is zero.
        #   Syncer and ForkedCache should only deal with FCU headHash.
        if hc.chain.notifyBlockHashAndNumber(hash, bn):
          info "PendingFCU resolved to finalized block number",
            finalizedHash=hash.short,
            finalizedNumber=bn.bnStr

      # Check whether `hdr` has a parent on the `FC` module.
      let newMode = hc.tryFcParent(hdr)
      if newMode in {ready,orphan}:
        hc.session.mode = newMode
        revTopInx = n                              # chaining headers stops here
        break

    # Store on database
    for n in offset .. revTopInx:
      hc.kvt.putHeader(rev[n].number, encodePayload rev[n])

    # Set new antecedent `ante` and save to disk (if any)
    hc.session.ante = rev[revTopInx]

    # Save updates. persist to DB
    hc.persistInfo()

  ok()


proc commit*(hc: HeaderChainRef): Result[void,string] =
  ## This function finishes appending headers (aka `put()`) by declaring it
  ## read-only (if successful.)
  ##
  ## Required system state for running this function is `ready`.
  ##
  ## It will be double checked whether the `FC` module is still in a state
  ## where it can provide a parent to the header chain. If necessary, the
  ## antecenent will be adjusted.
  ##
  ?hc.expectingMode(ready)

  # The benign case: verify that `ante` has still parent on the `FC` module
  if hc.chain.hashToBlock.hasKey(hc.session.ante.parentHash):
    hc.session.mode = locked                          # update internal state
    return ok()

  let baseNum = hc.baseNum
  if baseNum < hc.session.finHeader.number:
    #
    # So the `finalised` hash was resolved (otherwise it would have a zero
    # block number.)
    #
    # There are two segments of the canonical chain, `base..finalised` and
    # `ante..finalised` (the latter possibly degraded) which both share at
    # least `finalised` on the header chain cache.
    #
    # On the intersection of `ante..finalised` and `base..finalised` there is
    # a header with a parent on the `FC` module. Note that the intersecion is
    # fully part of the header chain cache where the most senior element can
    # be discarded. Neither `base` nor `ante` have a parent on the `FC` module.
    #
    let startHere = max(baseNum, hc.session.ante.number) + 1

    # Find out where the parent to some `FC` module header is.
    for bn in startHere .. hc.session.finHeader.number:
      let newAnte = hc.kvt.getHeader(bn).valueOr:
        raiseAssert RaisePfx & "getHeader(" & bn.bnStr & ") failed"
      if hc.chain.hashToBlock.hasKey(newAnte.parentHash):
        hc.session.ante = newAnte                     # update header chain
        hc.session.mode = locked                      # update internal state
        return ok()

    # Impossible situation!
    raiseAssert RaisePfx & "No parent on FC module for anu of " &
      startHere.bnStr & ".." & hc.session.finHeader.number.bnStr

  hc.session.mode = orphan
  err("Parent on FC module has been lost: obsolete branch segment")

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
  ## This getter is for metrics purposes. The returned number is typically
  ## larger than `head()` and will increased over time while `head()`
  ## remains constant (for the current session.)
  ##
  hc.session.consHeadNum

func latestNum*(hc: HeaderChainRef): BlockNumber =
  ## Aka `hc.chain.latestNumber()` (avoiding `forked_chain` import)
  hc.chain.activeBranch.headNumber

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc headTargetUpdate*(hc: HeaderChainRef; h: Header; f: Hash32) =
  ## Emulate request from `CL` (mainly for debugging purposes)
  if not hc.notify.isNil:
    hc.headUpdateFromCL(h, f)

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
