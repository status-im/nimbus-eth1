# fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/[rpcproxy, rpcserver],
  ../version

export rpcserver

proc installWeb3ApiHandlers*(rpcServer: RpcServer|RpcProxy) =

  rpcServer.rpc("web3_clientVersion") do() -> string:
    return clientVersion
