# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  ../network/wire/portal_protocol,
  ../network/network_seed,
  ../eth_data/history_data_seeding,
  ../database/[content_db, seed_db]

export rpcserver

# Non-spec-RPCs that are (currently) useful for testing & debugging
proc installPortalDebugApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string) =

  rpcServer.rpc("portal_" & network & "_storeContent") do(
      dataFile: string) -> bool:
    let res = p.historyStore(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagate") do(
      dataFile: string) -> bool:
    let res = await p.historyPropagate(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateHeaders") do(
      dataDir: string) -> bool:
    let res = await p.historyPropagateHeadersWithProof(dataDir)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateHeaders") do(
      epochHeadersFile: string, epochAccumulatorFile: string) -> bool:
    let res = await p.historyPropagateHeadersWithProof(
      epochHeadersFile, epochAccumulatorFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateBlock") do(
      dataFile: string, blockHash: string) -> bool:
    let res = await p.historyPropagateBlock(dataFile, blockHash)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateEpochAccumulator") do(
      dataFile: string) -> bool:
    let res = await p.propagateEpochAccumulator(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateEpochAccumulators") do(
      path: string) -> bool:
    let res = await p.propagateEpochAccumulators(path)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_storeContentInNodeRange") do(
      dbPath: string,
      max: uint32,
      starting: uint32) -> bool:
    let storeResult = p.storeContentInNodeRange(dbPath, max, starting)

    if storeResult.isOk():
      return true
    else:
      raise newException(ValueError, $storeResult.error)

  rpcServer.rpc("portal_" & network & "_offerContentInNodeRange") do(
      dbPath: string,
      nodeId: NodeId,
      max: uint32,
      starting: uint32) -> int:
    # waiting for offer result, by the end of this call remote node should
    # have received offered content
    let offerResult = await p.offerContentInNodeRange(dbPath, nodeId, max, starting)

    if offerResult.isOk():
      return offerResult.get()
    else:
      raise newException(ValueError, $offerResult.error)

  rpcServer.rpc("portal_" & network & "_depthContentPropagate") do(
      dbPath: string,
      max: uint32) -> bool:
    # TODO Consider making this call asynchronously without waiting for result
    # as for big seed db size it could take a loot of time.
    let propagateResult = await p.depthContentPropagate(dbPath, max)

    if propagateResult.isOk():
      return true
    else:
      raise newException(ValueError, $propagateResult.error)

  rpcServer.rpc("portal_" & network & "_breadthContentPropagate") do(
      dbPath: string) -> bool:
    # TODO Consider making this call asynchronously without waiting for result
    # as for big seed db size it could take a loot of time.
    let propagateResult = await p.breadthContentPropagate(dbPath)

    if propagateResult.isOk():
      return true
    else:
      raise newException(ValueError, $propagateResult.error)
