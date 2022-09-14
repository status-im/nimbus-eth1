#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[options, sequtils],
  chronos,
  eth/[common/eth_types, p2p],
  "../../.."/[protocol, protocol/trace_config],
  ../../worker_desc,
  ./get_error

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

type
  # SnapTrieNodes = object
  #   nodes*: seq[Blob]

  GetTrieNodes* = object
    leftOver*: seq[seq[Blob]]
    nodes*: seq[Blob]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getTrieNodesReq(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    paths: seq[seq[Blob]];
      ): Future[Result[Option[SnapTrieNodes],void]]
      {.async.} =
  let
    peer = buddy.peer
  try:
    let reply = await peer.getTrieNodes(stateRoot, paths, snapRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    trace trSnapRecvError & "waiting for GetByteCodes reply", peer,
      error=e.msg
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getTrieNodes*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    paths: seq[seq[Blob]],
      ): Future[Result[GetTrieNodes,ComError]]
      {.async.} =
  ## Fetch data using the `snap#` protocol, returns the trie nodes requested
  ## (if any.)
  let
    peer = buddy.peer
    nPaths = paths.len

  if nPaths == 0:
    return err(ComEmptyRequestArguments)

  let nTotal = paths.mapIt(it.len).foldl(a+b, 0)

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetTrieNodes", peer,
      nPaths, nTotal, bytesLimit=snapRequestBytesLimit

  let trieNodes = block:
    let rc = await buddy.getTrieNodesReq(stateRoot, paths)
    if rc.isErr:
      return err(ComNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetTrieNodes", peer, nPaths
      return err(ComResponseTimeout)
    let blobs = rc.value.get.nodes
    if nTotal < blobs.len:
      # Ooops, makes no sense
      return err(ComTooManyTrieNodes)
    blobs

  let
    nNodes = trieNodes.len

  if nNodes == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#gettrienodes-0x06
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * The returned nodes must be in the request order.
    # * If the node does not have the state for the requested state root or for
    #   any requested account paths, it must return an empty reply. It is the
    #   responsibility of the caller to query an state not older than 128
    #   blocks; and the caller is expected to only ever query existing trie
    #   nodes.
    # * The responding node is allowed to return less data than requested
    #   (serving QoS limits), but the node must return at least one trie node.
    trace trSnapRecvReceived & "empty TrieNodes", peer, nPaths, nNodes
    return err(ComNoByteCodesAvailable)

  # Assemble return value
  var dd = GetTrieNodes(nodes: trieNodes)

  # For each request group/sub-sequence, analyse the results
  var nInx = 0
  block loop:
    for n in 0 ..< nPaths:
      let pathLen = paths[n].len

      # Account node request
      if pathLen < 2:
        if trieNodes[nInx].len == 0:
          dd.leftOver.add paths[n]
        nInx.inc
        if nInx < nNodes:
          continue
        # all the rest needs to be re-processed
        dd.leftOver = dd.leftOver & paths[n+1 ..< nPaths]
        break loop

      # Storage request for account
      if 1 < pathLen:
        var pushBack: seq[Blob]
        for i in 1 ..< pathLen:
          if trieNodes[nInx].len == 0:
            pushBack.add paths[n][i]
            nInx.inc
            if nInx < nNodes:
              continue
            # all the rest needs to be re-processed
            #
            # add:              account & pushBack & rest  ...
            dd.leftOver.add paths[n][0] & pushBack & paths[n][i+1 ..< pathLen]
            dd.leftOver = dd.leftOver & paths[n+1 ..< nPaths]
            break loop
        if 0 < pushBack.len:
          dd.leftOver.add paths[n][0] & pushBack

  trace trSnapRecvReceived & "TrieNodes", peer,
    nPaths, nNodes, nLeftOver=dd.leftOver.len

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
