# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  json_rpc/rpcclient,
  json_rpc/errors, # TODO: should be exported in json_rpc/clients/httpclient
  web3/conversions, # sigh
  ../../nimbus/rpc/[rpc_types, hexstrings]

export rpcclient, rpc_types, hexstrings, errors

createRpcSigs(RpcClient, currentSourcePath.parentDir / "rpc_calls" / "rpc_eth_calls.nim")
createRpcSigs(RpcClient, currentSourcePath.parentDir / "rpc_calls" / "rpc_web3_calls.nim")
