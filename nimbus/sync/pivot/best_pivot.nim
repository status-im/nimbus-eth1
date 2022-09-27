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
## Borrowed from `full/worker.nim`

import
  std/[hashes, options, sets],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/byteutils,
  ".."/[protocol, sync_desc]

{.push raises:[Defect].}

const
  extraTraceMessages = false # or true
    ## Additional trace commands

  minPeersToStartSync = 2
    ## Wait for consensus of at least this number of peers before syncing.

type
  PivotDataRef = ref object of BuddyPivotBase
    ## Data for this peer only
    header: Option[BlockHeader] ## Pivot header (if any)

  PivotCtxRef = ref object of CtxPivotBase
    ## Data shared by all peers.
    untrusted: seq[Peer]        ## Clean up list
    trusted: HashSet[Peer]      ## Peers ready for delivery

proc hash*(peer: Peer): Hash

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc local[S,W](buddy: BuddyRef[S,W]): PivotDataRef =
  PivotDataRef(buddy.pivot)

proc global[S,W](buddy: BuddyRef[S,W]): PivotCtxRef =
  PivotCtxRef(buddy.ctx.pivot)


template safeTransport[S,W](
    buddy: BuddyRef[S,W];
    info: static[string];
    code: untyped) =
  try:
    code
  except TransportError as e:
    error info & ", stop", peer=buddy.peer, error=($e.name), msg=e.msg
    buddy.ctrl.stopped = true


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

proc getRandomTrustedPeer[S,W](buddy: BuddyRef[S,W]): Result[Peer,void] =
  ## Return random entry from `trusted` peer different from this peer set if
  ## there are enough
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `randomTrustedPeer()`
  let
    ctx = buddy.ctx
    nPeers = buddy.global.trusted.len
    offInx = if buddy.peer in buddy.global.trusted: 2 else: 1
  if 0 < nPeers:
    var (walkInx, stopInx) = (0, ctx.data.rng.rand(nPeers - offInx))
    for p in buddy.global.trusted:
      if p == buddy.peer:
        continue
      if walkInx == stopInx:
        return ok(p)
      walkInx.inc
  err()

proc getBestHeader[S,W](
    buddy: BuddyRef[S,W];
     ): Future[Result[BlockHeader,void]] {.async.} =
  ## Get best block number from best block hash.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `getBestBlockNumber()`
  let
    peer = buddy.peer
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
  buddy.safeTransport("Error fetching block header"):
    hdrResp = await peer.getBlockHeaders(hdrReq)
  if buddy.ctrl.stopped:
    return err()

  if hdrResp.isNone:
    trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
    return err()

  let hdrRespLen = hdrResp.get.headers.len
  if hdrRespLen == 1:
    let
      header = hdrResp.get.headers[0]
      blockNumber = header.blockNumber
    trace trEthRecvReceivedBlockHeaders, peer, hdrRespLen, blockNumber
    return ok(header)

  trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen
  return err()

proc agreesOnChain[S,W](
    buddy: BuddyRef[S,W];
    other: Peer
     ): Future[Result[void,bool]] {.async.} =
  ## Returns `true` if one of the peers `buddy.peer` or `other` acknowledges
  ## existence of the best block of the other peer. The values returned mean
  ## * ok()       -- `peer` is trusted
  ## * err(true)  -- `peer` is untrusted
  ## * err(false) -- `other` is dead
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `peersAgreeOnChain()`
  let
    peer = buddy.peer
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
  buddy.safeTransport("Error fetching block header"):
    hdrResp = await fetch.getBlockHeaders(hdrReq)
  if buddy.ctrl.stopped:
    if swapped:
      return err(true)
    # No need to terminate `peer` if it was the `other`, failing nevertheless
    buddy.ctrl.stopped = false
    return err(false)

  if hdrResp.isSome:
    let hdrRespLen = hdrResp.get.headers.len
    if 0 < hdrRespLen:
      let blockNumber = hdrResp.get.headers[0].blockNumber
      trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
        hdrRespLen, blockNumber
    return ok()

  trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
    blockNumber="n/a", swapped
  return err(true)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc hash*(peer: Peer): Hash =
  ## Mixin `HashSet[Peer]` handler
  hash(cast[pointer](peer))

# ------------

proc bestPivotSetup*[S](ctx: CtxRef[S]) =
  ## Global initialisation
  ctx.pivot = PivotCtxRef()

proc bestPivotRelease*[S](ctx: CtxRef[S]) =
  ## Global destruction
  ctx.pivot = nil

# ------------

proc  bestPivotStart*[S,W](buddy: BuddyRef[S,W]) =
  ## Initialise this wotrker
  buddy.pivot = PivotDataRef(header: none(BlockHeader))

proc  bestPivotStop*[S,W](buddy: BuddyRef[S,W]) =
  ## Clean up this peer
  buddy.global.untrusted.add buddy.peer

proc  bestPivotRestart*[S,W](buddy: BuddyRef[S,W]) =
  ## Restart finding pivot header for this peer
  buddy.pivotStop()
  buddy.pivotStart()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc bestPivotHeader*[S,W](buddy: BuddyRef[S,W]): Result[BlockHeader,void] =
  ## Returns cached block header if available and the buddy `peer` is trusted.
  let
    peer = buddy.peer
    local = buddy.local
    global = buddy.global
  if local.header.isSome and
     peer notin global.untrusted and
     minPeersToStartSync <= global.trusted.len and peer in global.trusted:
    return ok(buddy.local.header.unsafeGet)
  err()

proc bestPivotNegotiate*[S,W](
    buddy: BuddyRef[S,W];          ## Worker peer
    minBlockNumber: BlockNumber;   ## Minimum block number to expect
      ): Future[bool] {.async.} =
  ## Negotiate best header pivot. This function must be run in single mode at
  ## the beginning of a running worker peer.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `startSyncWithPeer()`
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
    local = buddy.local
    global = buddy.global

  # Delayed clean up batch list
  if 0 < global.untrusted.len:
    when extraTraceMessages:
      trace "Removing untrusted peers", peer, trusted=global.trusted.len,
        untrusted=global.untrusted.len, runState=buddy.ctrl.state
    global.trusted = global.trusted - global.untrusted.toHashSet
    global.untrusted.setLen(0)

  if local.header.isNone:
    when extraTraceMessages:
      # Only log for the first time (if any)
      trace "Pivot initialisation", peer,
        trusted=global.trusted.len, runState=buddy.ctrl.state

    let rc = await buddy.getBestHeader()
    # Beware of peer terminating the session right after communicating
    if rc.isErr or buddy.ctrl.stopped:
      return false
    let bestBlockNumber = rc.value.blockNumber
    if bestBlockNumber < minBlockNumber:
      buddy.ctrl.zombie = true
      trace "Useless peer, best number too low", peer,
        trusted=global.trusted.len, runState=buddy.ctrl.state,
        minBlockNumber, bestBlockNumber
    local.header = some(rc.value)

  if minPeersToStartSync <= global.trusted.len:
    # We have enough trusted peers. Validate new peer against trusted
    let rc = buddy.getRandomTrustedPeer()
    if rc.isOK:
      let rx = await buddy.agreesOnChain(rc.value)
      if rx.isOk:
        global.trusted.incl peer
        when extraTraceMessages:
          let bestHeader =
            if local.header.isSome: "#" & $local.header.get.blockNumber
            else: "nil"
          trace "Accepting peer", peer, trusted=global.trusted.len,
            untrusted=global.untrusted.len, runState=buddy.ctrl.state,
            bestHeader
        return true
      if not rx.error:
        # Other peer is dead
        global.trusted.excl rc.value

  # If there are no trusted peers yet, assume this very peer is trusted,
  # but do not finish initialisation until there are more peers.
  elif global.trusted.len == 0:
    global.trusted.incl peer
    when extraTraceMessages:
      let bestHeader =
        if local.header.isSome: "#" & $local.header.get.blockNumber
        else: "nil"
      trace "Assume initial trusted peer", peer,
        trusted=global.trusted.len, runState=buddy.ctrl.state, bestHeader

  elif global.trusted.len == 1 and buddy.peer in global.trusted:
    # Ignore degenerate case, note that `trusted.len < minPeersToStartSync`
    discard

  else:
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
        trusted=global.trusted.len, runState=buddy.ctrl.state
    for p in global.trusted:
      if peer == p:
        inc agreeScore
      else:
        let rc = await buddy.agreesOnChain(p)
        if rc.isOk:
          inc agreeScore
        elif buddy.ctrl.stopped:
          # Beware of terminated session
          return false
        elif rc.error:
          otherPeer = p
        else:
          # `Other` peer is dead
          deadPeers.incl p

    # Normalise
    if 0 < deadPeers.len:
      global.trusted = global.trusted - deadPeers
      if global.trusted.len == 0 or
         global.trusted.len == 1 and buddy.peer in global.trusted:
        return false

    # Check for the number of peers that disagree
    case global.trusted.len - agreeScore:
    of 0:
      global.trusted.incl peer # best possible outcome
      when extraTraceMessages:
        trace "Agreeable trust score for peer", peer,
          trusted=global.trusted.len, runState=buddy.ctrl.state
    of 1:
      global.trusted.excl otherPeer
      global.trusted.incl peer
      when extraTraceMessages:
        trace "Other peer no longer trusted", peer,
          otherPeer, trusted=global.trusted.len, runState=buddy.ctrl.state
    else:
      when extraTraceMessages:
        trace "Peer not trusted", peer,
          trusted=global.trusted.len, runState=buddy.ctrl.state
      discard

    # Evaluate status, finally
    if minPeersToStartSync <= global.trusted.len:
      when extraTraceMessages:
        let bestHeader =
          if local.header.isSome: "#" & $local.header.get.blockNumber
          else: "nil"
        trace "Peer trusted now", peer,
          trusted=global.trusted.len, runState=buddy.ctrl.state, bestHeader
      return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
