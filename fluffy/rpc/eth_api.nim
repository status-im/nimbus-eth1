# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/rpcproxy

# Subset of Eth JSON-RPC API: https://eth.wiki/json-rpc/API
# Supported subset will eventually be found here:
# https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-network.md#json-rpc-api
#
# In order to already support these calls before every part of the Portal
# Network is up, one plan is to get the data directly from an external client
# through RPC calls. Practically just playing a proxy to that client.
# Can be done by just forwarding the rpc call, or by adding a call here, but
# that would introduce a unnecessary serializing/deserializing step.

proc installEthApiHandlers*(rpcServerWithProxy: var RpcHttpProxy)
    {.raises: [Defect, CatchableError].} =

  # Supported API
  rpcServerWithProxy.registerProxyMethod("eth_blockNumber") 

  rpcServerWithProxy.registerProxyMethod("eth_call") 

  rpcServerWithProxy.registerProxyMethod("eth_chainId") 

  rpcServerWithProxy.registerProxyMethod("eth_estimateGas") 

  rpcServerWithProxy.registerProxyMethod("eth_feeHistory") 

  rpcServerWithProxy.registerProxyMethod("eth_getBalance") 

  rpcServerWithProxy.registerProxyMethod("eth_getBlockByHash") 

  rpcServerWithProxy.registerProxyMethod("eth_getBlockByNumber") 

  rpcServerWithProxy.registerProxyMethod("eth_getBlockTransactionCountByHash") 

  rpcServerWithProxy.registerProxyMethod("eth_getBlockTransactionCountByNumber") 

  rpcServerWithProxy.registerProxyMethod("eth_getCode") 

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByHash") 

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByBlockHashAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByBlockNumberAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getStorageAt") 

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByBlockHashAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByBlockNumberAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByHash") 

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionCount") 

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionReceipt") 

  rpcServerWithProxy.registerProxyMethod("eth_getUncleByBlockHashAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getUncleByBlockNumberAndIndex") 

  rpcServerWithProxy.registerProxyMethod("eth_getUncleCountByBlockHash") 

  rpcServerWithProxy.registerProxyMethod("eth_getUncleCountByBlockNumber") 

  rpcServerWithProxy.registerProxyMethod("eth_getProof") 

  rpcServerWithProxy.registerProxyMethod("eth_sendRawTransaction") 

  # Optional API

  rpcServerWithProxy.registerProxyMethod("eth_gasPrice") 

  rpcServerWithProxy.registerProxyMethod("eth_getFilterChanges") 

  rpcServerWithProxy.registerProxyMethod("eth_getFilterLogs") 

  rpcServerWithProxy.registerProxyMethod("eth_getLogs") 

  rpcServerWithProxy.registerProxyMethod("eth_newBlockFilter") 

  rpcServerWithProxy.registerProxyMethod("eth_newFilter") 

  rpcServerWithProxy.registerProxyMethod("eth_newPendingTransactionFilter") 

  rpcServerWithProxy.registerProxyMethod("eth_pendingTransactions") 

  rpcServerWithProxy.registerProxyMethod("eth_syncing") 

  rpcServerWithProxy.registerProxyMethod("eth_uninstallFilter") 
