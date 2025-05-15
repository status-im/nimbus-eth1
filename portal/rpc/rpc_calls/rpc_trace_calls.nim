# fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/json, json_rpc/[client, jsonmarshal], web3/conversions, web3/eth_api_types

export eth_api_types, json

createRpcSigsFromNim(RpcClient):
  proc trace_replayBlockTransactions(
    blockId: BlockIdentifier, traceOpts: seq[string]
  ): JsonNode
