# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/sets,
  pkg/[chronos, minilru],
  ../../../../wire_protocol,
  ../../worker_desc

from ../../../../beacon
  import BeaconPeerRef

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc ethGetBals*(
    buddy: SnapPeerRef;
    req: BlockAccessListsRequest;
      ): Future[Result[FetchBalData,SnapErrorEx]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockAccessLists()`
  let
    start = Moment.now()
  var
    count = 0
    error = err((EMissingEthContext,"","",chronos.seconds(0),Hash 0))
    resp: BlockAccessListsPacket
    seenID: HashSet[Hash]

  while count < nFetchBalEthPeersMax:
    var ethBuddy: BeaconPeerRef

    # Will not `for()` loop and activate the network here as any peer list
    # might change after the next thread switch.
    for w in buddy.getEthPeers().items:             # get a buddy not seen yet.
      if w.only.supportsBal and
         w.peerID notin seenID:
        seenID.incl w.peerID
        ethBuddy = w
        break                                       # accept peer
    if ethBuddy.isNil:
      break                                         # no more peers

    let peerID = ethBuddy.peerID
    buddy.ctx.pool.failedEthBalId.get(peerID).isErrOr:
      if value == zeroHash32 or
         value == req.blockHashes[0]:
        error = err((EAlreadyTriedAndFailed,"","",Moment.now()-start,peerID))
        continue

    count.inc

    try:
      resp = (await eth.getBlockAccessLists(
                ethBuddy.peer, req, fetchBalRlpxTimeout)).valueOr:
        error = err((EGeneric,"","",Moment.now()-start,peerID))
        continue
    except PeerDisconnected as e:
      error = err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start,peerID))
      continue
    except CancelledError as e:
      error = err((ECancelledError,$e.name,$e.msg,Moment.now()-start,peerID))
      continue
    except CatchableError as e:
      error = err((ECatchableError,$e.name,$e.msg,Moment.now()-start,peerID))
      continue
    return ok((move resp, Moment.now()-start, peerID))

  return error

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
