# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Negotiate a pivot header base on the *best header* values. Buddies that
## cannot provide a minimal block number will be disconnected.
##
## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `startSyncWithPeer()`

import
  std/[hashes, options, sets],
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/byteutils,
  ".."/[protocol, sync_desc, types]

{.push raises:[].}

logScope:
  topics = "best-pivot"

const
  extraTraceMessages = false or true
    ## Additional trace commands

  minPeersToStartSync = 2
    ## Wait for consensus of at least this number of peers before syncing.

  failCountMax = 3
    ## Stop after a peer fails too often while negotiating. This happens if
    ## a peer responses repeatedly with useless data.

type
  BestPivotCtxRef* = ref object of RootRef
    ## Data shared by all peers.
    rng: ref HmacDrbgContext    ## Random generator
    untrusted: HashSet[Peer]    ## Clean up list
    trusted: HashSet[Peer]      ## Peers ready for delivery
    relaxed: HashSet[Peer]      ## Peers accepted in relaxed mode
    relaxedMode: bool           ## Not using strictly `trusted` set
    minPeers: int               ## Minimum peers needed in non-relaxed mode
    comFailMax: int             ## Stop peer after too many communication errors

  BestPivotWorkerRef* = ref object of RootRef
    ## Data for this peer only
    global: BestPivotCtxRef     ## Common data
    header: Option[BlockHeader] ## Pivot header (if any)
    ctrl: BuddyCtrlRef          ## Control and state settings
    peer: Peer                  ## network peer
    comFailCount: int           ## Beware of repeated network errors

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

#proc hash(peer: Peer): Hash =
#  ## Mixin `HashSet[Peer]` handler
#  hash(cast[pointer](peer))

template safeTransport(
    bp: BestPivotWorkerRef;
    info: static[string];
    code: untyped) =
  try:
    code
  except TransportError as e:
    error info & ", stop", peer=bp.peer, error=($e.name), msg=e.msg
    bp.ctrl.stopped = true


proc rand(r: ref HmacDrbgContext; maxVal: uint64): uint64 =
  # github.com/nim-lang/Nim/tree/version-1-6/lib/pure/random.nim#L216
  const
    randMax = high(uint64)
  if 0 < maxVal:
    if maxVal == randMax:
      var x: uint64
      r[].generate(x)
      return x
    while true:
      var x: uint64
      r[].generate(x)
      # avoid `mod` bias, so `x <= n*maxVal <= randMax` for some integer `n`
      if x <= randMax - (randMax mod maxVal):
        # uint -> int
        return x mod (maxVal + 1)

proc rand(r: ref HmacDrbgContext; maxVal: int): int =
  if 0 < maxVal: # somehow making sense of `maxVal = -1`
    return cast[int](r.rand(maxVal.uint64))

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getRandomTrustedPeer(bp: BestPivotWorkerRef): Result[Peer,void] =
  ## Return random entry from `trusted` peer different from this peer set if
  ## there are enough
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `randomTrustedPeer()`
  let
    nPeers = bp.global.trusted.len
    offInx = if bp.peer in bp.global.trusted: 2 else: 1
  if 0 < nPeers:
    var (walkInx, stopInx) = (0, bp.global.rng.rand(nPeers - offInx))
    for p in bp.global.trusted:
      if p == bp.peer:
        continue
      if walkInx == stopInx:
        return ok(p)
      walkInx.inc
  err()

proc getBestHeader(
    bp: BestPivotWorkerRef;
      ): Future[Result[BlockHeader,void]]
      {.async.} =
  ## Get best block number from best block hash.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `getBestBlockNumber()`
  let
    peer = bp.peer
    startHash = peer.state(eth).bestBlockHash
    reqLen = 1u
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     startHash),
      maxResults: reqLen,
      skip:       0,
      reverse:    true)

  trace trEthSendSendingGetBlockHeaders, peer,
    startBlock=startHash.data.toHex, reqLen

  var hdrResp: Option[blockHeadersObj]
  bp.safeTransport("Error fetching block header"):
    hdrResp = await peer.getBlockHeaders(hdrReq)
  if bp.ctrl.stopped:
    return err()

  if hdrResp.isNone:
    bp.comFailCount.inc
    trace trEthRecvReceivedBlockHeaders, peer, reqLen,
      hdrRespLen="n/a", comFailCount=bp.comFailCount
    if bp.global.comFailMax < bp.comFailCount:
      bp.ctrl.zombie = true
    return err()

  let hdrRespLen = hdrResp.get.headers.len
  if hdrRespLen == 1:
    let
      header = hdrResp.get.headers[0]
      blockNumber {.used.} = header.blockNumber
    trace trEthRecvReceivedBlockHeaders, peer, hdrRespLen, blockNumber
    bp.comFailCount = 0 # reset fail count
    return ok(header)

  bp.comFailCount.inc
  trace trEthRecvReceivedBlockHeaders, peer, reqLen,
    hdrRespLen, comFailCount=bp.comFailCount
  if bp.global.comFailMax < bp.comFailCount:
    bp.ctrl.zombie = true
  return err()

proc agreesOnChain(
    bp: BestPivotWorkerRef;
    other: Peer;
      ): Future[Result[void,bool]]
      {.async.} =
  ## Returns `true` if one of the peers `bp.peer` or `other` acknowledges
  ## existence of the best block of the other peer. The values returned mean
  ## * ok()       -- `peer` is trusted
  ## * err(true)  -- `peer` is untrusted
  ## * err(false) -- `other` is dead
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `peersAgreeOnChain()`
  let
    peer = bp.peer
  var
    start = peer
    fetch = other
    swapped = false
  # Make sure that `fetch` has not the smaller difficulty.
  if fetch.state(eth).bestDifficulty < start.state(eth).bestDifficulty:
    swap(fetch, start)
    swapped = true

  let
    startHash = start.state(eth).bestBlockHash
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     startHash),
      maxResults: 1,
      skip:       0,
      reverse:    true)

  trace trEthSendSendingGetBlockHeaders, peer, start, fetch,
    startBlock=startHash.data.toHex, hdrReqLen=1, swapped

  var hdrResp: Option[blockHeadersObj]
  bp.safeTransport("Error fetching block header"):
    hdrResp = await fetch.getBlockHeaders(hdrReq)
  if bp.ctrl.stopped:
    if swapped:
      return err(true)
    # No need to terminate `peer` if it was the `other`, failing nevertheless
    bp.ctrl.stopped = false
    return err(false)

  if hdrResp.isSome:
    let hdrRespLen = hdrResp.get.headers.len
    if 0 < hdrRespLen:
      let blockNumber {.used.} = hdrResp.get.headers[0].blockNumber
      trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
        hdrRespLen, blockNumber
    return ok()

  trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
    blockNumber="n/a", swapped
  return err(true)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type BestPivotCtxRef;            ## Global data descriptor type
    rng: ref HmacDrbgContext;           ## Random generator
    minPeers = minPeersToStartSync;     ## Consensus of at least this #of peers
    failMax = failCountMax;             ## Stop peer after too many com. errors
      ): T =
  ## Global constructor, shared data. If `minPeers` is smaller that `2`,
  ## relaxed mode will be enabled (see also `pivotRelaxedMode()`.)
  result = T(rng:        rng,
             minPeers:   minPeers,
             comFailMax: failCountMax)
  if minPeers < 2:
    result.minPeers = minPeersToStartSync
    result.relaxedMode = true


proc init*(
    T: type BestPivotWorkerRef;         ## Global data descriptor type
    ctx: BestPivotCtxRef;               ## Global data descriptor
    ctrl: BuddyCtrlRef;                 ## Control and state settings
    peer: Peer;                         ## For fetching data from network
      ): T =
  ## Buddy/local constructor
  T(global: ctx,
    header: none(BlockHeader),
    ctrl:   ctrl,
    peer:   peer)

proc clear*(bp: BestPivotWorkerRef) =
  ## Reset descriptor
  bp.global.untrusted.incl bp.peer
  bp.header = none(BlockHeader)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc nPivotApproved*(ctx: BestPivotCtxRef): int =
  ## Number of trusted or relax mode approved pivots
  (ctx.trusted + ctx.relaxed - ctx.untrusted).len

proc pivotRelaxedMode*(ctx: BestPivotCtxRef; enable = false) =
  ## Controls relaxed mode. In relaxed mode, the *best header* is fetched
  ## from the network and used as pivot if its block number is large enough.
  ## Otherwise, the default is to find at least `pivotMinPeersToStartSync`
  ## peers (this one included) that agree on a minimum pivot.
  ctx.relaxedMode = enable

proc pivotHeader*(bp: BestPivotWorkerRef): Result[BlockHeader,void] =
  ## Returns cached block header if available and the buddy `peer` is trusted.
  ## In relaxed mode (see `pivotRelaxedMode()`), also lesser trusted pivots
  ## are returned.
  if bp.header.isSome and
     bp.peer notin bp.global.untrusted:

    if bp.global.minPeers <= bp.global.trusted.len and
       bp.peer in bp.global.trusted:
      return ok(bp.header.unsafeGet)

    if bp.global.relaxedMode:
      when extraTraceMessages:
        trace "Returning not fully trusted pivot", peer=bp.peer,
           trusted=bp.global.trusted.len, untrusted=bp.global.untrusted.len
      return ok(bp.header.unsafeGet)

  err()

proc pivotHeader*(
    bp: BestPivotWorkerRef;              ## Worker peer
    relaxedMode: bool;                   ## One time relaxed mode flag
      ): Result[BlockHeader,void] =
  ## Variant of `pivotHeader()` with `relaxedMode` flag as function argument.
  if bp.header.isSome and
     bp.peer notin bp.global.untrusted:

    if bp.global.minPeers <= bp.global.trusted.len and
       bp.peer in bp.global.trusted:
      return ok(bp.header.unsafeGet)

    if relaxedMode:
      when extraTraceMessages:
        trace "Returning not fully trusted pivot", peer=bp.peer,
           trusted=bp.global.trusted.len, untrusted=bp.global.untrusted.len
      return ok(bp.header.unsafeGet)

  err()

proc pivotNegotiate*(
    bp: BestPivotWorkerRef;              ## Worker peer
    minBlockNumber: Option[BlockNumber]; ## Minimum block number to expect
      ): Future[bool]
      {.async.} =
  ## Negotiate best header pivot. This function must be run in *single mode* at
  ## the beginning of a running worker peer. If the function returns `true`,
  ## the current `buddy` can be used for syncing and the function
  ## `bestPivotHeader()` will succeed returning a `BlockHeader`.
  ##
  ## In relaxed mode (see `pivotRelaxedMode()`), negotiation stopps when there
  ## is a *best header*. It caches the best header and returns `true` it the
  ## block number is large enough.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `startSyncWithPeer()`
  ##
  let peer = bp.peer

  # Delayed clean up batch list
  if 0 < bp.global.untrusted.len:
    when extraTraceMessages:
      trace "Removing untrusted peers", peer, trusted=bp.global.trusted.len,
        untrusted=bp.global.untrusted.len, runState=bp.ctrl.state
    bp.global.trusted = bp.global.trusted - bp.global.untrusted
    bp.global.relaxed = bp.global.relaxed - bp.global.untrusted
    bp.global.untrusted.clear()

  if bp.header.isNone:
    when extraTraceMessages:
      # Only log for the first time (if any)
      trace "Pivot initialisation", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state

    let rc = await bp.getBestHeader()
    # Beware of peer terminating the session right after communicating
    if rc.isErr or bp.ctrl.stopped:
      return false
    let
      bestNumber = rc.value.blockNumber
      minNumber = minBlockNumber.get(otherwise = 0.toBlockNumber)
    if bestNumber < minNumber:
      bp.ctrl.zombie = true
      trace "Useless peer, best number too low", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state,
        minNumber, bestNumber
      return false
    bp.header = some(rc.value)

  # No further negotiation if in relaxed mode
  if bp.global.relaxedMode:
    bp.global.relaxed.incl bp.peer
    return true

  if bp.global.minPeers <= bp.global.trusted.len:
    # We have enough trusted peers. Validate new peer against trusted
    let rc = bp.getRandomTrustedPeer()
    if rc.isOK:
      let rx = await bp.agreesOnChain(rc.value)
      if rx.isOk:
        bp.global.trusted.incl peer
        when extraTraceMessages:
          let bestHeader {.used.} = if bp.header.isNone: "n/a"
                                    else: bp.header.unsafeGet.blockNumber.toStr
          trace "Accepting peer", peer, trusted=bp.global.trusted.len,
            untrusted=bp.global.untrusted.len, runState=bp.ctrl.state,
            bestHeader
        return true
      if not rx.error:
        # Other peer is dead
        bp.global.trusted.excl rc.value
    return false

  # If there are no trusted peers yet, assume this very peer is trusted,
  # but do not finish initialisation until there are more peers.
  if bp.global.trusted.len == 0:
    bp.global.trusted.incl peer
    when extraTraceMessages:
      let bestHeader {.used.} = if bp.header.isNone: "n/a"
                                else: bp.header.unsafeGet.blockNumber.toStr
      trace "Assume initial trusted peer", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state, bestHeader
    return false

  if bp.global.trusted.len == 1 and bp.peer in bp.global.trusted:
    # Ignore degenerate case, note that `trusted.len < minPeersToStartSync`
    return false

  # At this point we have some "trusted" candidates, but they are not
  # "trusted" enough. We evaluate `peer` against all other candidates. If
  # one of the candidates disagrees, we swap it for `peer`. If all candidates
  # agree, we add `peer` to trusted set. The peers in the set will become
  # "fully trusted" (and sync will start) when the set is big enough
  var
    agreeScore = 0
    otherPeer: Peer
    deadPeers: HashSet[Peer]
  when extraTraceMessages:
    trace "Trust scoring peer", peer,
      trusted=bp.global.trusted.len, runState=bp.ctrl.state
  for p in bp.global.trusted:
    if peer == p:
      inc agreeScore
    else:
      let rc = await bp.agreesOnChain(p)
      if rc.isOk:
        inc agreeScore
      elif bp.ctrl.stopped:
        # Beware of terminated session
        return false
      elif rc.error:
        otherPeer = p
      else:
        # `Other` peer is dead
        deadPeers.incl p

  # Normalise
  if 0 < deadPeers.len:
    bp.global.trusted = bp.global.trusted - deadPeers
    if bp.global.trusted.len == 0 or
       bp.global.trusted.len == 1 and bp.peer in bp.global.trusted:
      return false

  # Check for the number of peers that disagree
  case bp.global.trusted.len - agreeScore:
  of 0:
    bp.global.trusted.incl peer # best possible outcome
    when extraTraceMessages:
      trace "Agreeable trust score for peer", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state
  of 1:
    bp.global.trusted.excl otherPeer
    bp.global.trusted.incl peer
    when extraTraceMessages:
      trace "Other peer no longer trusted", peer,
        otherPeer, trusted=bp.global.trusted.len, runState=bp.ctrl.state
  else:
    when extraTraceMessages:
      trace "Peer not trusted", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state
    discard

  # Evaluate status, finally
  if bp.global.minPeers <= bp.global.trusted.len:
    when extraTraceMessages:
      let bestHeader {.used.} = if bp.header.isNone: "n/a"
                                else: bp.header.unsafeGet.blockNumber.toStr
      trace "Peer trusted now", peer,
        trusted=bp.global.trusted.len, runState=bp.ctrl.state, bestHeader
    return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
