# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Note: this module is currently unused

{.push raises: [Defect].}

import
  std/[hashes, options, sequtils],
  chronos,
  eth/[common, p2p],
  "../../.."/[protocol, protocol/trace_config],
  "../.."/[constants, range_desc, worker_desc],
  ./com_error

logScope:
  topics = "snap-fetch"

type
  # SnapByteCodes* = object
  #   codes*: seq[Blob]

  GetByteCodes* = object
    leftOver*: seq[NodeKey]
    extra*: seq[(NodeKey,Blob)]
    kvPairs*: seq[(NodeKey,Blob)]

const
  emptyBlob = seq[byte].default

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getByteCodesReq(
    buddy: SnapBuddyRef;
    keys: seq[Hash256];
      ): Future[Result[Option[SnapByteCodes],void]]
      {.async.} =
  let
    peer = buddy.peer
  try:
    let reply = await peer.getByteCodes(keys, fetchRequestBytesLimit)
    return ok(reply)

  except CatchableError as e:
    trace trSnapRecvError & "waiting for GetByteCodes reply", peer,
      error=e.msg
    return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getByteCodes*(
    buddy: SnapBuddyRef;
    keys: seq[NodeKey],
      ): Future[Result[GetByteCodes,ComError]]
      {.async.} =
  ## Fetch data using the `snap#` protocol, returns the byte codes requested
  ## (if any.)
  let
    peer = buddy.peer
    nKeys = keys.len

  if nKeys == 0:
    return err(ComEmptyRequestArguments)

  if trSnapTracePacketsOk:
    trace trSnapSendSending & "GetByteCodes", peer, nkeys

  let byteCodes = block:
    let rc = await buddy.getByteCodesReq keys.mapIt(it.to(Hash256))
    if rc.isErr:
      return err(ComNetworkProblem)
    if rc.value.isNone:
      trace trSnapRecvTimeoutWaiting & "for reply to GetByteCodes", peer, nKeys
      return err(ComResponseTimeout)
    let blobs = rc.value.get.codes
    if nKeys < blobs.len:
      # Ooops, makes no sense
      return err(ComTooManyByteCodes)
    blobs

  let
    nCodes = byteCodes.len

  if nCodes == 0:
    # github.com/ethereum/devp2p/blob/master/caps/snap.md#getbytecodes-0x04
    #
    # Notes:
    # * Nodes must always respond to the query.
    # * The returned codes must be in the request order.
    # * The responding node is allowed to return less data than requested
    #   (serving QoS limits), but the node must return at least one bytecode,
    #   unless none requested are available, in which case it must answer with
    #   an empty response.
    # * If a bytecode is unavailable, the node must skip that slot and proceed
    #   to the next one. The node must not return nil or other placeholders.
    trace trSnapRecvReceived & "empty ByteCodes", peer, nKeys, nCodes
    return err(ComNoByteCodesAvailable)

  # Assemble return value
  var
    dd: GetByteCodes
    req = keys.toHashSet

  for n in 0 ..< nCodes:
    let key = byteCodes[n].keccakHash.to(NodeKey)
    if key in req:
      dd.kvPairs.add (key, byteCodes[n])
      req.excl key
    else:
      dd.extra.add (key, byteCodes[n])

  dd.leftOver = req.toSeq

  trace trSnapRecvReceived & "ByteCodes", peer,
    nKeys, nCodes, nLeftOver=dd.leftOver.len, nExtra=dd.extra.len

  return ok(dd)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
