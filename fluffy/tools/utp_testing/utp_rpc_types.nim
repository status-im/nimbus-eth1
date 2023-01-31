# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}


import
  std/hashes,
  json_rpc/jsonmarshal,
  stew/byteutils,
  eth/p2p/discoveryv5/node,
  eth/utp/[utp_discv5_protocol, utp_router]

export jsonmarshal

type SKey* = object
  id*: uint16
  nodeId*: NodeId

proc `%`*(value: SKey): JsonNode =
  let hex = value.nodeId.toBytesBE().toHex()
  let numId = value.id.toBytesBE().toHex()
  let finalStr = hex & numId
  newJString(finalStr)

proc fromJson*(n: JsonNode, argName: string, result: var SKey)
    {.raises: [ValueError].} =
  n.kind.expect(JString, argName)
  let str = n.getStr()
  let strLen = len(str)
  if (strLen >= 64):
    let nodeIdStr = str.substr(0, 63)
    let connIdStr = str.substr(64)
    let nodeId = NodeId.fromHex(nodeIdStr)
    let connId = uint16.fromBytesBE(connIdStr.hexToSeqByte())
    result = SKey(nodeId: nodeId, id: connId)
  else:
    raise newException(ValueError, "Too short string")

proc hash*(x: SKey): Hash =
  var h = 0
  h = h !& x.id.hash
  h = h !& x.nodeId.hash
  !$h

func toSKey*(k: UtpSocketKey[NodeAddress]): SKey =
  SKey(id: k.rcvId, nodeId: k.remoteAddress.nodeId)
