# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  chronos,
  eth/[common, p2p],
  "../../.."/[protocol, protocol/trace_config],
  "../.."/[constants, range_desc, worker_desc],
  ./get_error

logScope:
  topics = "snap-get"

type
  # SnapTrieNodes = object
  #   nodes*: seq[Blob]

  GetTrieNodes* = object
    leftOver*: seq[SnapTriePaths] ## Unprocessed data
    nodes*: seq[NodeSpecs]        ## `nodeKey` field unused with `NodeSpecs`

  ProcessReplyStep = object
    leftOver: SnapTriePaths       # Unprocessed data sets
    nodes: seq[NodeSpecs]         # Processed nodes
    topInx: int                   # Index of first unprocessed item

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getTrieNodesReq(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;
    paths: seq[SnapTriePaths];
    pivot: string;
      ): Future[Result[Option[SnapTrieNodes],void]]
      {.async.} =
  let
    peer = buddy.peer
  try:
    let reply = await peer.getTrieNodes(
      stateRoot, paths, fetchRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    let error {.used.} = e.msg
    when trSnapTracePacketsOk:
      trace trSnapRecvError & "waiting for GetByteCodes reply", peer, pivot,
        error
    return err()


proc processReplyStep(
    paths: SnapTriePaths;
    nodeBlobs: seq[Blob];
    startInx: int
      ): ProcessReplyStep =
  ## Process reply item, return unprocessed remainder
  # Account node request
  if paths.slotPaths.len == 0:
    if nodeBlobs[startInx].len == 0:
      result.leftOver.accPath = paths.accPath
    else:
      result.nodes.add NodeSpecs(
        partialPath: paths.accPath,
        data:        nodeBlobs[startInx])
    result.topInx = startInx + 1
    return

  # Storage paths request
  let
    nSlotPaths = paths.slotPaths.len
    maxLen = min(nSlotPaths, nodeBlobs.len - startInx)

  # Fill up nodes
  for n in 0 ..< maxlen:
    let nodeBlob = nodeBlobs[startInx + n]
    if 0 < nodeBlob.len:
      result.nodes.add NodeSpecs(
        partialPath: paths.slotPaths[n],
        data:        nodeBlob)
    else:
      result.leftOver.slotPaths.add paths.slotPaths[n]
    result.topInx = startInx + maxLen

  # Was that all for this step? Otherwise add some left over.
  if maxLen < nSlotPaths:
    result.leftOver.slotPaths &= paths.slotPaths[maxLen ..< nSlotPaths]

  if 0 < result.leftOver.slotPaths.len:
    result.leftOver.accPath = paths.accPath

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getTrieNodes*(
    buddy: SnapBuddyRef;
    stateRoot: Hash256;         # Current DB base (see `pivot` for logging)
    paths: seq[SnapTriePaths];  # Nodes to fetch
    pivot: string;              # For logging, instead of `stateRoot`
      ): Future[Result[GetTrieNodes,GetError]]
      {.async.} =
  ## Fetch data using the `snap#` protocol, returns the trie nodes requested
  ## (if any.)
  let
    peer {.used.} = buddy.peer
    nGroups = paths.len

  if nGroups == 0:
    return err(GetEmptyRequestArguments)

  let nTotal = paths.mapIt(max(1,it.slotPaths.len)).foldl(a+b, 0)

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetTrieNodes", peer, pivot, nGroups, nTotal

  let trieNodes = block:
    let rc = await buddy.getTrieNodesReq(stateRoot, paths, pivot)
    if rc.isErr:
      return err(GetNetworkProblem)
    if rc.value.isNone:
      when trSnapTracePacketsOk:
        trace trSnapRecvTimeoutWaiting & "for TrieNodes", peer, pivot, nGroups
      return err(GetResponseTimeout)
    let blobs = rc.value.get.nodes
    if nTotal < blobs.len:
      # Ooops, makes no sense
      when trSnapTracePacketsOk:
        trace trSnapRecvError & "too many TrieNodes", peer, pivot,
          nGroups, nExpected=nTotal, nReceived=blobs.len
      return err(GetTooManyTrieNodes)
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
    when trSnapTracePacketsOk:
      trace trSnapRecvReceived & "empty TrieNodes", peer, pivot, nGroups, nNodes
    return err(GetNoByteCodesAvailable)

  # Assemble return value
  var
    dd = GetTrieNodes()
    inx = 0
  for p in paths:
    let step = p.processReplyStep(trieNodes, inx)
    if 0 < step.leftOver.accPath.len or
       0 < step.leftOver.slotPaths.len:
      dd.leftOver.add step.leftOver
    if 0 < step.nodes.len:
      dd.nodes &= step.nodes
    inx = step.topInx
    if trieNodes.len <= inx:
      break

  when trSnapTracePacketsOk:
    trace trSnapRecvReceived & "TrieNodes", peer, pivot,
      nGroups, nNodes, nLeftOver=dd.leftOver.len

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
