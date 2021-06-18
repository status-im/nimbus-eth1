# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/rpcserver

# Subset of Eth JSON-RPC API: https://eth.wiki/json-rpc/API
# Supported subset will eventually be found here:
# https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-network.md#json-rpc-api
#
# In order to already support these calls before every part of the Portal
# Network is up, one plan is to get the data directly from an external client
# through RPC calls. Practically just playing a proxy to that client.
# Can be done by just forwarding the rpc call, or by adding a call here, but
# that would introduce a unnecessary serializing/deserializing step.

proc installEthApiHandlers*(rpcServer: RpcServer)
    {.raises: [Defect, CatchableError].} =

  # Supported API
  rpcServer.rpc("eth_blockNumber") do (): discard

  rpcServer.rpc("eth_call") do (): discard

  rpcServer.rpc("eth_chainId") do (): discard

  rpcServer.rpc("eth_estimateGas") do (): discard

  rpcServer.rpc("eth_feeHistory") do (): discard

  rpcServer.rpc("eth_getBalance") do (): discard

  rpcServer.rpc("eth_getBlockByHash") do (): discard

  rpcServer.rpc("eth_getBlockByNumber") do (): discard

  rpcServer.rpc("eth_getBlockTransactionCountByHash") do (): discard

  rpcServer.rpc("eth_getBlockTransactionCountByNumber") do (): discard

  rpcServer.rpc("eth_getCode") do (): discard

  rpcServer.rpc("eth_getRawTransactionByHash") do (): discard

  rpcServer.rpc("eth_getRawTransactionByBlockHashAndIndex") do (): discard

  rpcServer.rpc("eth_getRawTransactionByBlockNumberAndIndex") do (): discard

  rpcServer.rpc("eth_getStorageAt") do (): discard

  rpcServer.rpc("eth_getTransactionByBlockHashAndIndex") do (): discard

  rpcServer.rpc("eth_getTransactionByBlockNumberAndIndex") do (): discard

  rpcServer.rpc("eth_getTransactionByHash") do (): discard

  rpcServer.rpc("eth_getTransactionCount") do (): discard

  rpcServer.rpc("eth_getTransactionReceipt") do (): discard

  rpcServer.rpc("eth_getUncleByBlockHashAndIndex") do (): discard

  rpcServer.rpc("eth_getUncleByBlockNumberAndIndex") do (): discard

  rpcServer.rpc("eth_getUncleCountByBlockHash") do (): discard

  rpcServer.rpc("eth_getUncleCountByBlockNumber") do (): discard

  rpcServer.rpc("eth_getProof") do (): discard

  rpcServer.rpc("eth_sendRawTransaction") do (): discard

  # Optional API

  rpcServer.rpc("eth_gasPrice") do (): discard

  rpcServer.rpc("eth_getFilterChanges") do (): discard

  rpcServer.rpc("eth_getFilterLogs") do (): discard

  rpcServer.rpc("eth_getLogs") do (): discard

  rpcServer.rpc("eth_newBlockFilter") do (): discard

  rpcServer.rpc("eth_newFilter") do (): discard

  rpcServer.rpc("eth_newPendingTransactionFilter") do (): discard

  rpcServer.rpc("eth_pendingTransactions") do (): discard

  rpcServer.rpc("eth_syncing") do (): discard

  rpcServer.rpc("eth_uninstallFilter") do (): discard
