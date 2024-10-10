# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/rpcserver,
  ../network/wire/portal_protocol,
  ../eth_data/history_data_seeding,
  ../database/content_db

export rpcserver

# Non-spec-RPCs that are used for seeding history content into the network without
# usage of the standalone portal_bridge. As source Era1 files are used.
proc installPortalDebugHistoryApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
  ## Portal debug API calls related to storage and seeding from Era1 files.
  rpcServer.rpc("portal_debug_historyGossipHeaders") do(
    era1File: string, epochRecordFile: Opt[string]
  ) -> bool:
    let res = await p.historyGossipHeadersWithProof(era1File, epochRecordFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_debug_historyGossipBlockContent") do(era1File: string) -> bool:
    let res = await p.historyGossipBlockContent(era1File)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)
