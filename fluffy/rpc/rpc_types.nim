# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  eth/p2p/discoveryv5/[routing_table, enr, node]

type
  NodeInfo* = object
    nodeId: string
    nodeENR: string

  RoutingTableInfo* = object
    localKey: string
    buckets: seq[seq[string]]

proc getNodeInfo*(r: RoutingTable): NodeInfo =
  let id = "0x" & r.localNode.id.toHex()
  let enr = r.localNode.record.toURI()
  return NodeInfo(nodeId: id, nodeENR: enr)

proc getRoutingTableInfo*(r: RoutingTable): RoutingTableInfo =
  var info: RoutingTableInfo
  for b in r.buckets:
    var bucket: seq[string]
    for n in b.nodes:
      bucket.add("0x" & n.id.toHex())

    info.buckets.add(bucket)

  info.localKey = "0x" & r.localNode.id.toHex()

  info
