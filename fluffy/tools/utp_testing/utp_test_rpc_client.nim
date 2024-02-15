# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  json_rpc/rpcclient,
  ./utp_rpc_types,
  ../../rpc/[rpc_types, rpc_discovery_api]

export utp_rpc_types, rpc_types

createRpcSigs(RpcClient, currentSourcePath.parentDir / "utp_test_rpc_calls.nim")
createRpcSigs(RpcClient, currentSourcePath.parentDir /../ "" /../ "rpc" / "rpc_calls" / "rpc_discovery_calls.nim")
