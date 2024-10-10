# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import json_rpc/rpcclient, ../rpc_types

export rpc_types

Opt[string].useDefaultSerializationIn JrpcConv

createRpcSigsFromNim(RpcClient):
  ## Portal History Network json-rpc debug & custom calls
  proc portal_debug_historyGossipHeaders(
    era1File: string, epochRecordFile: Opt[string]
  ): bool

  proc portal_debug_historyGossipHeaders(era1File: string): bool
  proc portal_debug_historyGossipBlockContent(era1File: string): bool
