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
  pkg/chronos,
  ../../../../wire_protocol,
  ../../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc snapGetBals*(
    buddy: SnapPeerRef;
    req: BlockAccessListsRequest;
      ): Future[Result[FetchBalData,SnapErrorEx]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockAccessLists()`
  let start = Moment.now()

  if buddy.only.failedReq.balHash == req.blockHashes[0]:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start,Hash 0))
  var
    resp: BlockAccessListsPacket
  try:
    resp = (await snap.getBlockAccessLists(
      buddy.peer, req, fetchBalRlpxTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start,Hash 0))
  except PeerDisconnected as e:
    return err((EPeerDisconnected, $e.name, $e.msg,Moment.now()-start,Hash 0))
  except CancelledError as e:
    return err((ECancelledError, $e.name,$e.msg, Moment.now()-start,Hash 0))
  except CatchableError as e:
    return err((ECatchableError, $e.name,$e.msg, Moment.now()-start,Hash 0))

  return ok((move resp, Moment.now()-start, Hash 0))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
