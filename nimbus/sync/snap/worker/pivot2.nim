# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Borrowed from `full/worker.nim`

import
  std/[hashes, options, sets],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/byteutils,
  "../.."/[protocol, sync_desc],
  ../worker_desc

{.push raises:[Defect].}

logScope:
  topics = "snap-pivot"

const
  noisySyncVotingOk = false
    ## Additional trace commands

  minPeersToStartSync = 2
    ## Wait for consensus of at least this number of peers before syncing.

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(peer: Peer): Hash =
  ## Mixin `HashSet[Peer]` handler
  hash(cast[pointer](peer))

proc pivotNumber(buddy: SnapBuddyRef): BlockNumber =
  #  data.pivot2Header
  if buddy.ctx.data.pivotEnv.isNil:
    0.u256
  else:
    buddy.ctx.data.pivotEnv.stateHeader.blockNumber

template safeTransport(
    buddy: SnapBuddyRef;
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

proc getRandomTrustedPeer(buddy: SnapBuddyRef): Result[Peer,void] =
  ## Return random entry from `trusted` peer different from this peer set if
  ## there are enough
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `randomTrustedPeer()`
  let
    ctx = buddy.ctx
    nPeers = ctx.data.trusted.len
    offInx = if buddy.peer in ctx.data.trusted: 2 else: 1
  if 0 < nPeers:
    var (walkInx, stopInx) = (0, ctx.data.rng.rand(nPeers - offInx))
    for p in ctx.data.trusted:
      if p == buddy.peer:
        continue
      if walkInx == stopInx:
        return ok(p)
      walkInx.inc
  err()

proc getBestHeader(
    buddy: SnapBuddyRef
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

proc agreesOnChain(buddy: SnapBuddyRef; other: Peer): Future[bool] {.async.} =
  ## Returns `true` if one of the peers `buddy.peer` or `other` acknowledges
  ## existence of the best block of the other peer.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `peersAgreeOnChain()`
  let
    peer = buddy.peer
  var
    start = peer
    fetch = other
    swapped = false # logging only
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
    return false

  if hdrResp.isSome:
    let hdrRespLen = hdrResp.get.headers.len
    if 0 < hdrRespLen:
      let blockNumber = hdrResp.get.headers[0].blockNumber
      trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
        hdrRespLen, blockNumber
    return true

  trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
    blockNumber="n/a", swapped


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pivot2Start*(buddy: SnapBuddyRef) =
  discard

proc pivot2Stop*(buddy: SnapBuddyRef) =
  discard

proc pivot2Restart*(buddy: SnapBuddyRef) =
  buddy.data.pivot2Header = none(BlockHeader)


proc pivot2Exec*(buddy: SnapBuddyRef): Future[bool] {.async.} =
  ## Initalise worker. This function must be run in single mode at the
  ## beginning of running worker peer.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `startSyncWithPeer()`
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Delayed clean up batch list
  if 0 < ctx.data.untrusted.len:
    when noisySyncVotingOk:
      trace "Removing untrused peers", peer,
        count=ctx.data.untrusted.len, runState=buddy.ctrl.state
    for p in ctx.data.untrusted:
      ctx.data.trusted.excl p
    ctx.data.untrusted.setLen(0)

  if buddy.data.pivot2Header.isNone:
    # Only log for the first time, or so
    trace "Pivot initialisation", peer,
      trusted=ctx.data.trusted.len, runState=buddy.ctrl.state

    let rc = await buddy.getBestHeader()
    # Beware of peer terminating the session right after communicating
    if rc.isErr or buddy.ctrl.stopped:
      return false
    let
      bestNumber = rc.value.blockNumber
      minNumber = buddy.pivotNumber
    if bestNumber < minNumber:
      buddy.ctrl.zombie = true
      trace "Useless peer, best number too low", peer,
        trusted=ctx.data.trusted.len, runState=buddy.ctrl.state,
        minNumber, bestNumber
    buddy.data.pivot2Header = some(rc.value)

  if minPeersToStartSync <= ctx.data.trusted.len:
    # We have enough trusted peers. Validate new peer against trusted
    let rc = buddy.getRandomTrustedPeer()
    if rc.isOK:
      if await buddy.agreesOnChain(rc.value):
        ctx.data.trusted.incl peer
        return true

  # If there are no trusted peers yet, assume this very peer is trusted,
  # but do not finish initialisation until there are more peers.
  elif ctx.data.trusted.len == 0:
    ctx.data.trusted.incl peer
    when noisySyncVotingOk:
      trace "Assume initial trusted peer", peer,
        trusted=ctx.data.trusted.len, runState=buddy.ctrl.state

  elif ctx.data.trusted.len == 1 and buddy.peer in ctx.data.trusted:
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
    for p in ctx.data.trusted:
      if peer == p:
        inc agreeScore
      elif await buddy.agreesOnChain(p):
        inc agreeScore
      elif buddy.ctrl.stopped:
        # Beware of terminated session
        return false
      else:
        otherPeer = p

    # Check for the number of peers that disagree
    case ctx.data.trusted.len - agreeScore
    of 0:
      ctx.data.trusted.incl peer # best possible outcome
      when noisySyncVotingOk:
        trace "Agreeable trust score for peer", peer,
          trusted=ctx.data.trusted.len, runState=buddy.ctrl.state
    of 1:
      ctx.data.trusted.excl otherPeer
      ctx.data.trusted.incl peer
      when noisySyncVotingOk:
        trace "Other peer no longer trusted", peer,
          otherPeer, trusted=ctx.data.trusted.len, runState=buddy.ctrl.state
    else:
      when noisySyncVotingOk:
        trace "Peer not trusted", peer,
          trusted=ctx.data.trusted.len, runState=buddy.ctrl.state
      discard

    if minPeersToStartSync <= ctx.data.trusted.len:
      when noisySyncVotingOk:
        trace "Peer trusted now", peer,
          trusted=ctx.data.trusted.len, runState=buddy.ctrl.state
      return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
