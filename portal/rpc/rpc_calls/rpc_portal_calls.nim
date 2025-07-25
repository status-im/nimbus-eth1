# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/json, json_rpc/rpcclient, ../rpc_types

export rpc_types

createRpcSigsFromNim(RpcClient):
  ## Portal History Network json-rpc calls
  proc portal_historyNodeInfo(): NodeInfo
  proc portal_historyRoutingTableInfo(): RoutingTableInfo
  proc portal_historyAddEnr(enr: Record): bool
  proc portal_historyAddEnrs(enrs: seq[Record]): bool
  proc portal_historyGetEnr(nodeId: NodeId): Record
  proc portal_historyDeleteEnr(nodeId: NodeId): bool
  proc portal_historyLookupEnr(nodeId: NodeId): Record
  proc portal_historyPing(enr: Record): PingResult
  proc portal_historyFindNodes(enr: Record): seq[Record]
  proc portal_historyFindContent(enr: Record, contentKey: string): JsonNode
  proc portal_historyOffer(
    enr: Record, contentKey: string, contentValue: string
  ): string

  proc portal_historyRecursiveFindNodes(nodeId: NodeId): seq[Record]
  proc portal_historyGetContent(contentKey: string): ContentInfo
  proc portal_historyStore(contentKey: string, contentValue: string): bool
  proc portal_historyLocalContent(contentKey: string): string
  proc portal_historyPutContent(
    contentKey: string, contentValue: string
  ): PutContentResult

  ## Portal Beacon Light Client Network json-rpc calls
  proc portal_beaconNodeInfo(): NodeInfo
  proc portal_beaconRoutingTableInfo(): RoutingTableInfo
  proc portal_beaconAddEnr(enr: Record): bool
  proc portal_beaconAddEnrs(enrs: seq[Record]): bool
  proc portal_beaconGetEnr(nodeId: NodeId): Record
  proc portal_beaconDeleteEnr(nodeId: NodeId): bool
  proc portal_beaconLookupEnr(nodeId: NodeId): Record
  proc portal_beaconPing(enr: Record): PingResult
  proc portal_beaconFindNodes(enr: Record): seq[Record]
  proc portal_beaconFindContent(enr: Record, contentKey: string): JsonNode
  proc portal_beaconOffer(enr: Record, contentKey: string, contentValue: string): string
  proc portal_beaconRecursiveFindNodes(nodeId: NodeId): seq[Record]
  proc portal_beaconGetContent(contentKey: string): ContentInfo
  proc portal_beaconStore(contentKey: string, contentValue: string): bool
  proc portal_beaconLocalContent(contentKey: string): string
  proc portal_beaconPutContent(
    contentKey: string, contentValue: string
  ): PutContentResult

  proc portal_beaconRandomGossip(contentKey: string, contentValue: string): int
