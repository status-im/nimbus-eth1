# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/typetraits,
  pkg/[chronos, eth/common, results],
  ../../../wire_protocol,
  ../[helpers, worker_desc],
  ./blocks_helpers

export
  block_access_lists

const
  emptyRawBal = seq[RawBlockAccessList].default

# ------------------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------------

proc maybeSlowPeerError(
    buddy: BeaconPeerRef;
    elapsed: Duration;
    hash: Hash32;
      ): bool =
  ## Register slow response, definitely not fast enough
  if fetchBalsErrTimeout <= elapsed:
    buddy.balFetchRegisterError(slowPeer=true)

    # Do not repeat the same time-consuming failed request
    buddy.only.failedReq.balHash = hash

    return true

  # false

func errStr(rc: Result[FetchBalData,BeaconError]): string =
  if rc.isErr:
    result = $rc.error.excp
    if 0 < rc.error.name.len:
      result &= "(" & rc.error.name & ")"
    if 0 < rc.error.msg.len:
      result &= "[" & rc.error.msg & "]"
  else:
    result = "n/a"

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc getBals(
    buddy: BeaconPeerRef;
    req: BlockAccessListsRequest;
    startInx: int;
      ): Future[Result[FetchBalData,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`
  let start = Moment.now()

  doAssert startInx < req.blockHashes.len

  if buddy.only.failedReq.balHash == req.blockHashes[startInx]:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  let
    req = BlockAccessListsRequest(blockHashes: req.blockHashes[startInx ..< ^1])
  var
    resp: BlockAccessListsPacket
  try:
    resp = (await eth.getBlockAccessLists(
      buddy.peer, req, fetchBalsRlpxTimeout)).valueOr:
        return err((ENoException,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  # There is no obvious way to set an individual timeout for this call. The
  # eth/xx driver sets a global response timeout to `10s`. By how it is
  # implemented, the `Future` returned by `peer.getBlockBodies(req)` cannot
  # reliably be used in a `withTimeout()` directive. It would rather crash
  # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
  return ok((move resp, Moment.now()-start))
  
# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template fetchBlockAccessListsSome*(
    buddy: BeaconPeerRef;
    request: BlockAccessListsRequest;               # list of block hashes
    startInx: int;                                  # start at this entry
      ): Opt[seq[RawBlockAccessList]] =
  ## Async/template
  ##
  ## Request the raw (RLP-encoded) block access lists (EIP-7928) for the block
  ## hashes in `request` from the sync peer.
  ##
  ## The peer serves the lists in request order but may truncate its response.
  ## So not all requested BALs might be returned.
  ##
  var bodyRc = Opt[seq[RawBlockAccessList]].err()
  block body:
    if not buddy.only.supportsBal:                  # error
      break body

    const
      sendInfo = trEthSendSendingGetBals
      recvInfo = trEthRecvReceivedBals
    let
      peer {.inject,used.} = $buddy.peer            # logging only
      nReq {.inject.} = request.blockHashes.len - startInx
      startHash {.inject.} = request.blockHashes[startInx]

    if nReq <= 0:
      trace sendInfo & " empty request", peer, nReq, state=($buddy.syncState),
        nErrors=buddy.nErrors.fetch.bal
      bodyRc = typeof(bodyRc).ok(emptyRawBal)
      break body

    trace sendInfo, peer, startHash=startHash.short, nReq,
      nErrors=buddy.nErrors.fetch.bal

    let rc = await buddy.getBals(request, startInx)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      block evalError:
        case rc.error.excp:
        of ENoException, ESyncerTermination:
          break evalError
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.bal.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.balFetchRegisterError()
          buddy.balNoSampleSize(elapsed)
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, startHash=startHash.short, nReq,
            ela=rc.error.elapsed.toStr, state=($buddy.syncState),
            error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
          break body                                # return err()

        # Debug message for other errors
        debug recvInfo & " error", peer, startHash=startHash.short, nReq,
          ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.bal
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate result
    if rc.isErr or buddy.ctrl.stopped:
      if not buddy.maybeSlowPeerError(elapsed, startHash):
        buddy.balFetchRegisterError()
      trace recvInfo & " error", peer, startHash=startHash.short, nReq,
        ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
      break body                                    # return err()

    # Verify the correct number of BALs received
    template b: auto = rc.value.packet.accessLists
    if b.len == 0 or nReq < b.len:
      if nReq < b.len:
        # Bogus peer returning additional rubbish
        buddy.balFetchRegisterError(forceZombie=true)
      else:
        # No data available. For a fast enough rejection response, the
        # througput stats are degraded, only.
        buddy.balNoSampleSize(elapsed)

        # Slow response, definitely not fast enough
        discard buddy.maybeSlowPeerError(elapsed, startHash)

      trace recvInfo & " error", peer, startHash=startHash.short, nReq,
        nResp=b.len, ela, state, nErrors=buddy.nErrors.fetch.bal
      break body                                    # return err()

    # Update download statistics
    let bps {.used.} = buddy.balSampleSize(elapsed, b.getEncodedLength)

    # Request did not fail (for now)
    buddy.only.failedReq.balHash = zeroHash32

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchBalsErrTimeout < elapsed:
      buddy.balFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.bal = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one or not error

    trace recvInfo, peer, startHash=startHash.short, nReq, nResp=b.len, ela,
      thPut=(bps.toIECb(1) & "ps"), state, nErrors=buddy.nErrors.fetch.bal

    bodyRc =  typeof(bodyRc).ok(b)

  bodyRc

template fetchBlockAccessListsAll*(
    buddy: BeaconPeerRef;
    request: BlockAccessListsRequest;
      ): Opt[seq[RawBlockAccessList]] =
  ## Async/template
  ##
  ## Request the raw (RLP-encoded) block access lists (EIP-7928) for the block
  ## hashes in `request` from the sync peer.
  ##
  ## The peer serves the lists in request order but truncates its response at a
  ## soft size limit (and a maximum count), so a single response may cover only
  ## a prefix of the requested hashes. Follow-up requests are issued for the
  ## remaining hashes until all are received (or the peer stops making
  ## progress), so the returned sequence is aligned by index with
  ## `request.blockHashes`.
  ##
  var bodyRc = Opt[seq[RawBlockAccessList]].err()
  block body:
    let nReq = request.blockHashes.len

    var q = newSeqOfCap[RawBlockAccessList](nReq)
    while q.len < nReq:
      let rsp = buddy.fetchBlockAccessListsSome(request, q.len).valueOr:
        break body
      if rsp.len == 0:
        break
      q.add rsp

    bodyRc = typeof(bodyRc).ok(q)

  bodyRc


proc decodeBlockAccessList*(
    raw: RawBlockAccessList;
    header: Header;
      ): Opt[BlockAccessListRef] =
  ## Decode a single raw (RLP-encoded) block access list received from a peer
  ## and verify it against the BAL hash committed in the block header.
  ## Returns `none` when the peer reported the list as unavailable, when it is
  ## malformed, or when its hash does not match the header. 
  let bytes = distinctBase(raw)

  if bytes.len == 0 or (bytes.len == 1 and bytes[0] == 0x80'u8):
    return Opt.none(BlockAccessListRef)

  let expectedHash = header.blockAccessListHash.valueOr:
    return Opt.none(BlockAccessListRef)

  if keccak256(bytes) != expectedHash:
    return Opt.none(BlockAccessListRef)

  let bal: BlockAccessListRef = new BlockAccessList
  bal[] = BlockAccessList.decode(bytes).valueOr:
    return Opt.none(BlockAccessListRef)

  Opt.some(bal)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
