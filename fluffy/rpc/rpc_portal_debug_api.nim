# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/rpcserver,
  stew/byteutils,
  ../network/wire/portal_protocol,
  ../eth_data/history_data_seeding,
  ../database/content_db

export rpcserver

# Non-spec-RPCs that are used for testing, debugging and seeding data without a
# bridge.
proc installPortalDebugApiHandlers*(
    rpcServer: RpcServer, p: PortalProtocol, network: static string
) =
  ## Portal debug API calls related to storage and seeding from Era1 files.
  rpcServer.rpc("portal_" & network & "GossipHeaders") do(
    era1File: string, epochRecordFile: Opt[string]
  ) -> bool:
    let res = await p.historyGossipHeadersWithProof(era1File, epochRecordFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "GossipBlockContent") do(era1File: string) -> bool:
    let res = await p.historyGossipBlockContent(era1File)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  ## Portal debug API calls related to storage and seeding
  ## TODO: To be removed/replaced with the Era1 versions where applicable.
  rpcServer.rpc("portal_" & network & "_storeContent") do(dataFile: string) -> bool:
    let res = p.historyStore(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagate") do(dataFile: string) -> bool:
    let res = await p.historyPropagate(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateHeaders") do(dataDir: string) -> bool:
    let res = await p.historyPropagateHeadersWithProof(dataDir)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateHeaders") do(
    epochHeadersFile: string, epochRecordFile: string
  ) -> bool:
    let res =
      await p.historyPropagateHeadersWithProof(epochHeadersFile, epochRecordFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateBlock") do(
    dataFile: string, blockHash: string
  ) -> bool:
    let res = await p.historyPropagateBlock(dataFile, blockHash)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)
