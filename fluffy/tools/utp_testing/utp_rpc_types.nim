# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}


import
  std/[hashes, json],
  json_rpc/jsonmarshal,
  stew/[byteutils, endians2],
  eth/p2p/discoveryv5/node,
  eth/utp/[utp_discv5_protocol, utp_router]

export jsonmarshal, json

type SKey* = object
  id*: uint16
  nodeId*: NodeId

proc writeValue*(w: var JsonWriter[JrpcConv], v: SKey)
      {.gcsafe, raises: [IOError].} =
  let hex = v.nodeId.toBytesBE().toHex()
  let numId = v.id.toBytesBE().toHex()
  let finalStr = hex & numId
  w.writeValue(finalStr)

proc readValue*(r: var JsonReader[JrpcConv], val: var SKey)
       {.gcsafe, raises: [IOError, JsonReaderError].} =
  let str = r.parseString()
  if str.len < 64:
    r.raiseUnexpectedValue("SKey: too short string")

  try:
    let nodeIdStr = str.substr(0, 63)
    let connIdStr = str.substr(64)
    let nodeId = NodeId.fromHex(nodeIdStr)
    let connId = uint16.fromBytesBE(connIdStr.hexToSeqByte())
    val = SKey(nodeId: nodeId, id: connId)
  except ValueError as exc:
    r.raiseUnexpectedValue("Skey parser error: " & exc.msg)

proc hash*(x: SKey): Hash =
  var h = 0
  h = h !& x.id.hash
  h = h !& x.nodeId.hash
  !$h

func toSKey*(k: UtpSocketKey[NodeAddress]): SKey =
  SKey(id: k.rcvId, nodeId: k.remoteAddress.nodeId)
