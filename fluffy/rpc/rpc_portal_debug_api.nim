# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  ../network/wire/portal_protocol,
  ../content_db

export rpcserver

# Some RPCs that are (currently) useful for testing & debugging
proc installPortalDebugApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [Defect, CatchableError].} =

  rpcServer.rpc("portal_" & network & "_store") do(
      contentId: string, content: string) -> bool:
    # Using content id as parameter to make it more easy to store. Might evolve
    # in using content key.
    let cId = UInt256.fromBytesBE(hexToSeqByte(contentId))
    discard p.contentDB.put(cId, hexToSeqByte(content), p.localNode.id)

    return true

  rpcServer.rpc("portal_" & network & "_propagate") do(
      dataFile: string) -> bool:
    let res = await p.propagateHistoryDb(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateBlock") do(
      dataFile: string, blockHash: string) -> bool:
    let res = await p.propagateBlockHistoryDb(dataFile, blockHash)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)
