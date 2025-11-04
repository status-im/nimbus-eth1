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

{.push raises:[].}

import
  pkg/[chronicles, metrics, stew/endians2],
  pkg/eth/[common, rlp],
  "../.."/[common, db/core_db, db/storage_types],
  ../../db/[kvt, kvt_cf],
  ../../db/kvt/[kvt_utils, kvt_tx_frame],
  ./forked_chain,
  ./forked_chain/[chain_branch, chain_desc, block_quarantine]

logScope:
  topics = "hc-cache"

declareGauge nec_sync_dangling, "" &
  "Least block number for header chain already fetched"

declareGauge nec_sync_consensus_head, "" &
  "Block number of latest consensus head"

declareGauge nec_sync_distance_to_sync, "" &
  "Distance from execution head to consensus head"

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

  MsgPfx = "Header Cache: "
    ## Message prefix used when logging or raising an exception

const
  HccDbInfoKey = 0.beaconHeaderKey

# ------------------------------------------------------------------------------
# Private debugging and print functions
# ------------------------------------------------------------------------------

func bnStr(w: BlockNumber): string =
  $w

func bnStr(h: Header): string =
  h.number.bnStr

func toStr(hc: HeaderChainRef): string =
  result = "("
  result &= $hc.session.mode
  result &= ", " & hc.session.ante.bnStr
  if hc.session.ante != hc.session.head:
    result &= ".." & hc.session.head.bnStr
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
    raiseAssert MsgPfx & "rlp.decode(" & $T & ") failed:" &
      " name=" & $e.name & " error=" & e.msg

# ------------------------------------------------------------------------------
# Private cache helpers: database related
# ------------------------------------------------------------------------------

proc putInfo(db: KvtTxRef; state: HccDbInfo) =
  db.put(HccDbInfoKey.toOpenArray, encodePayload(state)).isOkOr:
    raiseAssert MsgPfx & "put(info) failed: " & $error

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


proc putHeader(db: KvtTxRef; h: Header) =
  ## Store the argument `header` indexed by block number, and the hash lookup
  ## of the parent header.
  let data = encodePayload(h)
  db.put(beaconHeaderKey(h.number).toOpenArray, data).isOkOr:
    raiseAssert MsgPfx & "put(header) failed: " & $error

  let parNumData = (h.number-1).toBytesBE
  db.put(genericHashKey(h.parentHash).toOpenArray, parNumData).isOkOr:
    raiseAssert MsgPfx & "put(number-1) failed: " & $error


proc getNumber(db: KvtTxRef, hash: Hash32): Opt[BlockNumber] =
  let number = db.get(genericHashKey(hash).toOpenArray).valueOr:
    return err()
  ok(uint64.fromBytesBE(number))

proc getHeader(db: KvtTxRef; bn: BlockNumber): Opt[Header] =
  ## Retrieve some header from cache
  let data = db.get(beaconHeaderKey(bn).toOpenArray).valueOr:
    return err()
  ok decodePayload(data, Header)

proc getHeader(db: KvtTxRef; hash: Hash32): Opt[Header] =
  ## Variant of `getHeader()`
  db.getHeader ?db.getNumber(hash)


proc delHeader(db: KvtTxRef; bn: BlockNumber) =
  ## Remove header from cache, ignore non-existing entries
  let
    bnKey = beaconHeaderKey(bn)
    rc = db.get(bnKey.toOpenArray)
  discard db.del(bnKey.toOpenArray)
  if rc.isOk:
    let h =  decodePayload(rc.value, Header)
    discard db.del(genericHashKey(h.parentHash).toOpenArray)

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
  let baseNum = hc.chain.baseNumber()
  if baseNum + 1 < hdr.number:
    return collecting                          # inconclusive

  return orphan                                # maybe on the wrong branch

# ------------------------------------------------------------------------------
# Private fork choice call back function
# ------------------------------------------------------------------------------

proc resolveFinHash(hc: HeaderChainRef, f: Hash32) =
  proc toNumber(v: auto): BlockNumber =
    v.number

  let number = (
    hc.chain.quarantine.getHeader(f).map(toNumber) or hc.kvt.getNumber(f) or
    hc.chain.headerByHash(f).map(toNumber)
  ).valueOr:
    return

  if hc.chain.tryUpdatePendingFCU(f, number):
    debug MsgPfx & "pendingFCU resolved to block number",
      hash = f.short,
      number = number.bnStr

proc headUpdateFromCL(hc: HeaderChainRef; h: Header; f: Hash32) =
  ## Call back function to register new/prevously-unknown FC updates.
  ##
  ## This function prepares a new session and notifies some registered
  ## client app.
  ##
  if f != zeroHash32:                               # finalised hash is set

    if hc.chain.baseNumber() + 1 < h.number and     # otherwise useless
       hc.session.mode == closed:
      # Set new session environment
      hc.session = HccSession(                      # start new session
        mode:     collecting,
        ante:     h,
        head:     h,
        headHash: h.computeBlockHash())

      hc.kvt.putHeader(h)
      metrics.set(nec_sync_dangling, h.number.int64)

      # Update `FC` module
      hc.chain.pendingFCU = f
      if f == hc.session.headHash:
        discard hc.chain.tryUpdatePendingFCU(f, h.number)

      # Inform client app about that a new session has started.
      hc.notify()

    # For logging and metrics
    hc.session.consHeadNum = h.number
    metrics.set(nec_sync_consensus_head, h.number.int64)
    if hc.chain.latestNumber <= h.number:
      metrics.set(nec_sync_distance_to_sync,
        (h.number - hc.chain.latestNumber).int64)

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
  hc.session.reset                        # clear session state object
  hc.persistClear()                       # clear database
  metrics.set(nec_sync_dangling, 0)       # ditto

proc stop*(hc: HeaderChainRef) =
  ## Stop updating the client cache. Will automatically be called by the
  ## destructor `destroy()`.
  ##
  hc.chain.com.headerChainUpdate = HeaderChainUpdateCB(nil)
  hc.chain.com.resolveFinHash = ResolveFinHashCB(nil)
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

  hc.chain.com.resolveFinHash = proc(f: Hash32) =
    hc.resolveFinHash(f)

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

proc get*(hc: HeaderChainRef; hash: Hash32): Opt[Header] =
  ## Retrieve some stashed header.
  var hdr = hc.kvt.getHeader(hash).valueOr:
    if hash == hc.session.headHash:
      return ok(hc.session.head)
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

  debug MsgPfx & "updated",
    minNum=rev[^1].bnStr,
    maxNum=rev[0].bnStr,
    numHeaders=rev.len

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

      if hash == hc.chain.pendingFCU:
        if hc.chain.tryUpdatePendingFCU(hash, hdr.number):
          debug "PendingFCU resolved to block number",
            hash=hash.short,
            number=hdr.bnStr

      # Check whether `hdr` has a parent on the `FC` module.
      let newMode = hc.tryFcParent(hdr)
      if newMode in {ready,orphan}:
        hc.session.mode = newMode
        revTopInx = n                              # chaining headers stops here
        break

    # Store on database
    for n in offset .. revTopInx:
      hc.kvt.putHeader(rev[n])

    # Set new antecedent `ante` and save to disk (if any)
    hc.session.ante = rev[revTopInx]
    metrics.set(nec_sync_dangling, hc.session.ante.number.int64)

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

  block assignFinalisedChild:
    # Use `finalised` only if it is on the header chain as well
    let fin = hc.kvt.getHeader(hc.chain.pendingFCU).valueOr:
      break assignFinalisedChild

    if hc.chain.baseNumber() < fin.number:
      # Now, there are two segments of the canonical chain, `base..finalised`
      # on# the `FC` module and `ante..finalised` (maybe degraded) on the
      # header chain cache.
      #
      # So `finalised` is on the header chain cache and has a parent on the
      # `FC` module.
      if hc.chain.hashToBlock.hasKey(hc.chain.pendingFCU):
        hc.session.ante = fin
        hc.session.mode = locked                      # update internal state
        metrics.set(nec_sync_dangling, fin.number.int64)
        return ok()

      # Impossible situation!
      raiseAssert MsgPfx &
        "Missing finalised " & fin.bnStr & " parent on FC module" &
           ", base=" & hc.chain.baseNumber.bnStr &
           ", head=" & hc.session.head.bnStr &
           ", finalized=" & hc.chain.latestFinalizedBlockNumber.bnStr

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

func headHash*(hc: HeaderChainRef): Hash32 =
  ## Getter: hash of `head()`
  ##
  if collecting <= hc.state:
    return hc.session.headHash

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

proc updateMetrics*(hc: HeaderChainRef) =
  ## Update/adjust some metrics, i.p. `nec_sync_distance_to_sync`
  if hc.chain.latestNumber <= hc.session.consHeadNum:
    metrics.set(nec_sync_distance_to_sync,
      (hc.session.consHeadNum - hc.chain.latestNumber).int64)

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
