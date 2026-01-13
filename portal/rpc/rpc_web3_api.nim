# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import json_rpc/rpcserver, ./rpc_types, ../version

proc installWeb3ApiHandlers*(rpcServer: RpcServer) =
  rpcServer.rpc("web3_clientVersion", EthJson) do() -> string:
    return clientVersion
